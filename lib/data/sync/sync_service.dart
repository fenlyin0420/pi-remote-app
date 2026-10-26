// Plan/31 — SyncService: the SINGLE writer of the local SSOT.
//
// Consumes the channel (ConnectionManager status + the room-tagged inbound
// stream) and writes row-granular records to Hive (v2 boxes). The UI never
// touches this stream — it reads the DB via the read repositories.
//
// Streaming is the ONE exception to SSOT (#7): AgentChunk deltas are coalesced
// into an in-memory Stream<StreamingMessage?> and NEVER written to the DB; only
// the finalized message lands in the box on `agent_done`.
//
// Turn state (streaming buffers, whole-turn working flag, queued list) is
// PER-ROOM, not global: rooms of one peer share a single WS, so every inbound
// envelope arrives tagged with the room that produced it
// (`ConnectionManager.roomMessages`). The frame's OWN room picks the writer:
// this chat's frames become DB rows, every other room's frames only feed that
// room's in-memory turn state (no DB writes — a background room's finalized
// rows are recovered by the history re-sync when the user returns to it). That
// is what keeps a turn in flight when the user switches rooms and comes back:
// the buffer AND the reasoning-block start time survive in the room's own slot.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:app/data/attachments/attachment_store.dart';
import 'package:app/data/files/incoming_files.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/data/local/sent_image_store.dart';
import 'package:app/data/sync/sync_events.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/domain/contracts/media_saver.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/domain/value_objects/image_size.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// Per-room in-memory turn state (the "live" half of a session, never
/// persisted): the two streaming segment buffers, the reasoning-block start
/// time, the coalesce timer, the whole-turn working flag and the room's queued
/// messages. Keyed by `(epk, room)` in [SyncService._turns] — one slot per
/// room so switching away from a streaming chat neither loses its content nor
/// resets its thinking counter.
class _RoomTurn {
  final String epk;
  final String room;

  _RoomTurn(this.epk, this.room);

  // Streaming — two block kinds share ONE live slot: reasoning
  // (`agent_thinking`) and answer text (`agent_chunk`). Content blocks are
  // sequential, so only one kind is ever open at a time; a delta of the other
  // kind closes the open one first.
  final StringBuffer chunkBuffer = StringBuffer();
  String chunkReplyTo = '';
  final StringBuffer thinkingBuffer = StringBuffer();
  String thinkingReplyTo = '';
  // When the live reasoning segment started — the row it folds into carries
  // the elapsed time, and the streaming block ticks it
  // (StreamingMessage.startedAt).
  DateTime? thinkingStartedAt;
  Timer? flushTimer;
  StreamingMessage? streaming;

  // Whether this room's agent is currently producing a reply. Spans the
  // WHOLE turn (send/echo → agent_done), not just the token-streaming window.
  bool working = false;
  bool sawRemoteWorking = false;
  // Id of the user message the in-flight reply is answering — the `cancel`
  // target while working. Null when idle.
  String? workingReplyTo;

  List<QueuedMsg> queuedMessages = const [];

  /// Plan/63 — the agent's todo list for this room (pi-todo), as last published
  /// by the Pi. Room state, not turn state: it outlives turns and survives the
  /// user switching away and back, exactly like [queuedMessages].
  TodoState todos = TodoState();
}

/// Transport-level error codes (mirrors the Pi's `KnownErrorCode`).
const _knownErrorCodes = {
  'tool_approval_required',
  'invalid_message',
  'unsupported_type',
  'too_large',
  'rate_limited',
  'timeout',
  'internal_error',
  'provider_error',
  'unknown_peer',
};

class SyncService extends Service {
  final ConnectionManager _conn;
  final LocalBoxes _boxes;

  StreamSubscription<ConnectionStatus>? _connSub;
  // Fallback only: channels that cannot tag their inbound frames get their
  // `serverMessages` treated as the bound room's (see [_onStatus]).
  StreamSubscription<ServerMessage>? _msgSub;
  StreamSubscription<RoomMessage>? _roomMsgSub;
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  StreamSubscription<Map<String, PresenceState>>? _presenceSub;

  // Active session being written (follows ConnectionManager).
  String? _activeEpk;
  String _activeRoomId = 'main';

  // Per-room in-memory turn state — survives room switches; only the
  // UI-facing streams/gatters follow the ACTIVE room's slot.
  final Map<String, _RoomTurn> _turns = {};

  // In-memory dedupe + ordering for the active session's msgs box. Rebuilt on
  // [activate]. Key = `<role>:<id>` so a user msg and the assistant reply that
  // shares its id don't collide.
  final Map<String, int> _idToSeq = {};
  int _nextSeq = 0;
  bool _indexLoaded = false;

  // Serialise box mutations so concurrent async writes stay ordered.
  Future<void> _writeChain = Future<void>.value();

  final StreamController<StreamingMessage?> _streamingController =
      StreamController<StreamingMessage?>.broadcast();

  final StreamController<SessionEvent> _eventController =
      StreamController<SessionEvent>.broadcast();

  // Plan/57 — transient interactive extension prompts (ask_user via pi-ask).
  // Never persisted (live UI requests, not chat history); surfaced to the
  // ChatViewModel, which opens a full-screen modal.
  final StreamController<ExtensionUiRequest> _extensionUiController =
      StreamController<ExtensionUiRequest>.broadcast();

  final StreamController<List<QueuedMsg>> _queuedController =
      StreamController<List<QueuedMsg>>.broadcast();

  final StreamController<TodoState> _todoController =
      StreamController<TodoState>.broadcast();

  final StreamController<bool> _workingController =
      StreamController<bool>.broadcast();

  /// Fires a card id whenever [_fileReceive] changed, so the chat can repaint
  /// the progress bar without the DB being touched for every chunk.
  final StreamController<String> _fileReceiveController =
      StreamController<String>.broadcast();

  /// Chunked Pi → App transfers in flight, by card id. In-memory only: a
  /// transfer the app lost leaves no row behind, and the card falls back to
  /// "tap to load", which re-requests the file.
  final Map<String, FileReceiveProgress> _fileReceive = {};

  /// Metadata of each in-flight transfer, kept so a failure can rewrite the
  /// card it already created with the reason it stopped.
  final Map<String, _IncomingCard> _incomingCards = {};

  /// Byte sink for the chunked receive path. Created on the first transfer (it
  /// needs an open box for a real path, like [_attachments]).
  IncomingFiles? _incomingFiles;

  bool _pendingSyncRequest = false;
  Timer? _syncDebounce;

  /// Resume token for the bound room's newest applied history event, mirrored
  /// from its [SessionIndexRecord]. Null until a history is applied (or after a
  /// session wipe), which makes the next `session_sync` ask for a full replay.
  String? _syncCursor;

  /// How many of the bound room's rows came out of a replay (mirrored from
  /// [SessionIndexRecord.syncedRows]). Everything past it was written from a
  /// live frame and is provisional: a reply replaces the rows it brings back and
  /// leaves the rest. Null when this cache has no frontier (written before it
  /// existed, or after a session wipe) — [_loadIndex] then also drops the cursor
  /// so a full replay substitutes the cache once.
  int? _syncedRows;

  /// `session_sync` requests this device has sent and not yet had answered, by
  /// id. A reply answers ONE of them, and the moment that request left is the
  /// line between "the Pi could see this row" and "the Pi could not": rows this
  /// app wrote after it cannot be in the reply, so a re-sync leaves them alone
  /// ([_applyHistory]) instead of replacing them with silence.
  final Map<String, DateTime> _syncAsked = {};

  /// A few in flight is the normal case (room entry + the online edge); the cap
  /// only stops a channel that never answers from growing the map.
  static const int _maxSyncAsked = 8;

  /// When this device asked for the reply with [inReplyTo], and forget it.
  ///
  /// Only a full replay needs it (it substitutes the cache, so the rows written
  /// while it was in flight have to be told apart); a delta decides by content
  /// instead. A reply this device cannot place falls back to the oldest request
  /// still in flight, and null means there is nothing to go on — a full replay
  /// then treats its own event list as the whole truth.
  DateTime? _takeSyncRequest(String? inReplyTo) {
    // A request whose reply never came would otherwise linger and become the
    // fallback for every later reply, dating rows as "newer" for good.
    final stale = DateTime.now().subtract(const Duration(minutes: 2));
    _syncAsked.removeWhere((_, askedAt) => askedAt.isBefore(stale));
    if (inReplyTo != null) {
      final askedAt = _syncAsked.remove(inReplyTo);
      if (askedAt != null) return askedAt;
    }
    return _syncAsked.isEmpty ? null : _syncAsked.values.first;
  }

  // Plan/32 safety net — if the relay never echoes a sent message back, the
  // optimistic `pending:true` bubble would spin forever. After this window we
  // remove the bubble SILENTLY (no "failed" state, no spinner). The real fix
  // lives in the relay; this is the app-side backstop. Per-message (`id`)
  // timers are armed only when a send is actually attempted online, and
  // cancelled on echo, user-cancel, session switch, and dispose.
  final Duration pendingSendTimeout;
  final Map<String, Timer> _pendingSendTimers = {};

  // Cache for the bytes of files the Pi sent to the phone. Resolved lazily
  // from the msgs box dir (it needs an OPEN box for a real path), so tests
  // that never send a file never touch the filesystem.
  AttachmentStore? _attachments;

  /// The phone's own archive of the pictures the user sent (`sent_images/`),
  /// resolved the same lazy way. Rows reference it by content hash, so a
  /// history replay can never delete a picture from the transcript.
  SentImageStore? _sentImages;

  /// The one tool the app renders as something other than a tool card.
  static const String _sendToPhoneTool = 'send_to_phone';

  /// Live `send_to_phone` calls whose tool card was skipped, so the matching
  /// `tool_result` can be recognised (a bare result frame carries no tool name).
  final Set<String> _attachmentToolCalls = {};
  /// Tool calls the Pi classified as writing, kept even when the verdict lands
  /// before the row does (local rules answer at `tool_execution_start`). The
  /// row is marked when it is created; a verdict that lands later marks it
  /// directly.
  final Set<String> _writeToolCalls = {};

  /// Writes a card's file into the phone's storage. Null where the platform has
  /// no channel for it (desktop builds, tests) — reported, never faked.
  final MediaSaver? _mediaSaver;

  SyncService(
    this._conn,
    this._boxes, {
    this.pendingSendTimeout = const Duration(seconds: 20),
    AttachmentStore? attachmentStore,
    SentImageStore? sentImageStore,
    MediaSaver? mediaSaver,
  }) : _attachments = attachmentStore,
       _sentImages = sentImageStore,
       _mediaSaver = mediaSaver {
    _connSub = _conn.statusStream.listen(_onStatus);
    _roomsSub = _conn.roomsStream.listen((_) {
      _writeRuntime();
      _syncTurnStateFromRoomMeta();
    });
    _presenceSub = _conn.presenceStream.listen((_) => _writeRuntime());
    // Background ingestion: EVERY room's inbound frames (the active room's
    // frames arrive here too — the handler skips them; the writer path owns
    // those). Feeds the non-active rooms' turn state so a streaming room the
    // user is not viewing keeps accumulating.
    _roomMsgSub = _conn.roomMessages.listen(_onRoomMessage);
    _onStatus(_conn.status); // replay current
  }

  // ---------------------------------------------------------------------------
  // Public surface (commands + in-memory streams)
  // ---------------------------------------------------------------------------

  /// The ACTIVE room's live streaming slot (null when idle / unbound).
  StreamingMessage? get streaming => _activeTurn?.streaming;
  Stream<StreamingMessage?> get streamingStream => _streamingController.stream;
  Stream<SessionEvent> get events => _eventController.stream;

  // ---------------------------------------------------------------------------
  // Pi → App attachments
  // ---------------------------------------------------------------------------

  /// Ask the Pi for the bytes behind an attachment card that has none yet.
  ///
  /// A card rebuilt from `session_history` arrives as metadata only (the
  /// history budget has no room for base64), so this is what puts something on
  /// screen. The answer comes back as a [FileOffer] reusing the card id, which
  /// lands in the same upsert the live offer uses.
  ///
  /// Deliberately NOT automatic: opening an old room must not pull every file
  /// that was ever sent, so the card asks when the user actually looks at it.
  Future<void> requestAttachment(String attachmentId, String path) async {
    final ch = _conn.channel;
    if (ch == null || _activeEpk == null) return;
    // ignore: discarded_futures
    ch.send(
      FileGet(id: 'get_${uuid7()}', path: path, attachmentId: attachmentId),
    );
  }

  /// The bytes cached for a card, or null when it was never fetched.
  Future<Uint8List?> attachmentBytes(String blobName) async {
    final store = _attachmentStore();
    if (store == null) return null;
    return store.get(blobName);
  }

  /// The archived bytes of a picture the user sent, or null when this phone has
  /// no copy (pruned, or a row written before the archive existed).
  Future<Uint8List?> sentImageBytes(String blob) async {
    final store = _sentImageStore();
    if (store == null) return null;
    return store.get(blob);
  }

  /// The absolute path of a cached blob, for handing it to the platform.
  Future<String?> attachmentPath(String blobName) async {
    final store = _attachmentStore();
    if (store == null) return null;
    return store.pathOf(blobName);
  }

  /// Copy a card's cached file into the phone's own storage (gallery for
  /// images, Downloads otherwise) and return where it went.
  ///
  /// Throws [MediaSaveException] — a card whose blob was pruned away, or a
  /// platform without the channel, has to be reported, not silently swallowed.
  Future<String> saveAttachment(AttachmentMsg msg) async {
    final blob = msg.blobName;
    if (blob == null) {
      throw const MediaSaveException(
        'missing_file',
        'This file has not been loaded on the phone yet',
      );
    }
    final path = await attachmentPath(blob);
    if (path == null) {
      throw const MediaSaveException(
        'missing_file',
        'The local copy is gone — load the file and try again',
      );
    }
    final saver = _mediaSaver;
    if (saver == null) {
      throw const MediaSaveException(
        'unsupported',
        'Saving files is not available on this platform',
      );
    }
    return saver.save(path: path, mime: msg.mime, name: msg.name);
  }

  AttachmentStore? _attachmentStore() {
    final existing = _attachments;
    if (existing != null) return existing;
    final epk = _activeEpk;
    if (epk == null) return null;
    final box = _boxes.isMsgsBoxOpen(epk, _activeRoomId)
        ? _boxes.openMsgsBox(epk, _activeRoomId)
        : null;
    final path = box?.path;
    if (path == null) return null;
    return _attachments = AttachmentStore.forBox(path);
  }

  /// The sent-picture archive, resolved from [msgsBox] when the caller already
  /// holds the box it is writing (a history replay may land after a room switch,
  /// so the active room is not good enough there).
  SentImageStore? _sentImageStore({Box<dynamic>? msgsBox}) {
    final existing = _sentImages;
    if (existing != null) return existing;
    var path = msgsBox?.path;
    if (path == null) {
      final epk = _activeEpk;
      if (epk == null) return null;
      path = _boxes.isMsgsBoxOpen(epk, _activeRoomId)
          ? _boxes.openMsgsBox(epk, _activeRoomId).path
          : null;
    }
    if (path == null) return null;
    return _sentImages = SentImageStore.forBox(path);
  }

  /// Moves a row's inline image bytes into the phone's archive and returns the
  /// same list with `blob` + pixel size instead of `data`.
  ///
  /// Runs on EVERY write path that can carry a picture — the optimistic send,
  /// the Pi's echo, the replayed history — because the row is the only thing a
  /// replay can rewrite. The write is content addressed and skipped when the
  /// blob already exists, so a re-sync replaying bytes this phone already holds
  /// costs one hash and no I/O.
  Future<List<MessageImage>> _archiveImages(
    List<MessageImage> images, {
    Box<dynamic>? msgsBox,
  }) async {
    if (images.isEmpty) return images;
    final store = _sentImageStore(msgsBox: msgsBox);
    // No data dir (a test, or a box that was never opened): keep the bytes in
    // the row rather than dropping them.
    if (store == null) return images;
    var changed = false;
    final out = <MessageImage>[];
    for (final img in images) {
      if (img.archived || img.data.isEmpty) {
        out.add(img);
        continue;
      }
      Uint8List bytes;
      try {
        bytes = base64Decode(img.data);
      } catch (_) {
        out.add(img);
        continue;
      }
      final blob = await store.put(bytes);
      if (blob == null) {
        out.add(img);
        continue;
      }
      final size = probeImageSize(bytes);
      out.add(
        MessageImage(
          mime: img.mime,
          blob: blob,
          width: size?.width,
          height: size?.height,
        ),
      );
      changed = true;
    }
    return changed ? out : images;
  }

  /// Plan/57 — stream of interactive extension_ui_request prompts (ask_user
  /// via pi-ask). Transient: not written to the DB; the ChatViewModel renders
  /// a full-screen modal and replies via [respondExtensionUi].
  Stream<ExtensionUiRequest> get extensionUiRequestStream =>
      _extensionUiController.stream;
  List<QueuedMsg> get queuedMessages =>
      _activeTurn?.queuedMessages ?? const [];
  String? get queuedText =>
      queuedMessages.isEmpty ? null : queuedMessages.first.text;
  Stream<List<QueuedMsg>> get queuedStream => _queuedController.stream;

  /// Plan/63 — the ACTIVE room's todo list (pi-todo). Empty when the agent kept
  /// no list, which is also what a Pi without the plugin reports.
  TodoState get todos => _activeTurn?.todos ?? TodoState();
  Stream<TodoState> get todosStream => _todoController.stream;

  /// True while the ACTIVE room's agent is producing a reply (whole turn).
  bool get isWorking => _activeTurn?.working ?? false;
  Stream<bool> get workingStream => _workingController.stream;

  /// `cancel` target for the in-flight reply (null when idle).
  String? get workingReplyTo => _activeTurn?.workingReplyTo;

  String? get activeEpk => _activeEpk;
  String get activeRoomId => _activeRoomId;

  // --- Chunked Pi → App transfers (`file_send_*`) -----------------------------

  /// How far the incoming file for [id] got, or null when nothing is arriving
  /// for that card. Applied to the card by the chat view model, so progress is
  /// never persisted: a transfer the app loses simply ends.
  FileReceiveProgress? fileReceiveOf(String id) => _fileReceive[id];

  /// Emits a card id whose [fileReceiveOf] changed.
  Stream<String> get fileReceiveStream => _fileReceiveController.stream;

  /// LOCAL (fenlyin): the model the ACTIVE room is running (room_meta.model)
  /// — stamped onto LIVE rows so their caption matches the Pi's per-message
  /// model from the next re-sync (the live wire frames carry no model).
  /// `null` when no room has reported one (older Pi builds).
  String? get _activeRoomModel {
    final epk = _activeEpk;
    if (epk == null) return null;
    // `roomsFor` normalizes the epk encoding (url-safe vs standard base64);
    // the raw map key would silently miss for url-safe peers.
    final rooms = _conn.roomsFor(epk);
    for (final r in rooms) {
      if (r.roomId == _activeRoomId) return r.model;
    }
    return null;
  }

  /// The slot whose turn state the UI-facing getters/streams reflect.
  _RoomTurn? get _activeTurn {
    final epk = _activeEpk;
    if (epk == null) return null;
    return _turns[LocalBoxes.sessionKey(epk, _activeRoomId)];
  }

  _RoomTurn _turn(String epk, String room) => _turns.putIfAbsent(
    LocalBoxes.sessionKey(epk, room),
    () => _RoomTurn(epk, room),
  );

  bool _isActive(_RoomTurn t) =>
      t.epk == _activeEpk && t.room == _activeRoomId;

  /// Bind the writer to a (peer, room). Opens the box and rebuilds the
  /// dedupe/seq index from it. Called by the chat when it mounts / switches
  /// rooms; also adopted automatically on the first StatusOnline.
  Future<void> activate(String epk, String roomId) async {
    final room = roomId.isEmpty ? 'main' : roomId;
    if (_activeEpk == epk && _activeRoomId == room && _indexLoaded) return;
    // Session switch: drop the previous room's no-echo send backstops (its
    // pending rows re-arm when ITS box loads — see _loadIndex). Per-room turn
    // state deliberately SURVIVES: a room still mid-turn keeps accumulating
    // (working flag, streaming buffers, reasoning start time) in its own slot,
    // so returning to it restores the in-flight bubble and its thinking
    // counter instead of starting from zero.
    _cancelAllSendTimers();
    // A transfer in flight belongs to the room that was bound: its bytes belong
    // to a card in that box, and its Pi-side sender fails on its own timeout
    // (the tool reports it). Dropping the parts keeps a room switch from
    // leaving half a file in the cache.
    if (_activeEpk != epk || _activeRoomId != room) {
      // ignore: discarded_futures
      _abortIncomingTransfers();
    }
    final prevTurn = _activeEpk != null
        ? _turns[LocalBoxes.sessionKey(_activeEpk!, _activeRoomId)]
        : null;
    _activeEpk = epk;
    _activeRoomId = room;
    // The resume state belongs to the room that was bound, and [_loadIndex]
    // loads this one's below: until then "unknown" is the safe reading — a
    // cursor from the PREVIOUS room that the Pi happened to place would answer
    // with a delta this box cannot merge, and an unknown frontier keeps every
    // row instead of dropping the ones it cannot account for.
    _syncedRows = null;
    _syncCursor = null;
    _syncAsked.clear();
    // Re-aim the UI-facing streams at the NEW room's slot: when the previous
    // room was mid-turn (working pill / live bubble), publish the new room's
    // state — or the cleared sentinel — so listeners that don't re-seed on
    // their own (a still-mounted chat VM, a quick A→B→A hop) stop showing the
    // previous room's working state. A genuinely idle switch emits nothing.
    if (prevTurn != null &&
        (prevTurn.working || prevTurn.streaming != null)) {
      final nextTurn = _turns[LocalBoxes.sessionKey(epk, room)];
      if (!_streamingController.isClosed) {
        _streamingController.add(nextTurn?.streaming);
      }
      if (!_workingController.isClosed) {
        _workingController.add(nextTurn?.working ?? false);
      }
    }
    // Plan/63 — the todo ball is room-scoped like the working pill, so the
    // switch re-aims it unconditionally: a chat that stays mounted must never
    // keep showing the list of the room it just left.
    if (!_todoController.isClosed) {
      _todoController.add(
        _turns[LocalBoxes.sessionKey(epk, room)]?.todos ?? TodoState(),
      );
    }
    await _loadIndex();
    // The room just bound may have finished its turn while the app was
    // elsewhere (backgrounded, or the `agent_done` frame lost): the relay's meta
    // is the authority on whether it is still working, so reconcile here —
    // otherwise the chat opens with a working pill and a thinking counter that
    // keep ticking while Home shows the room as idle. A no-op unless the relay
    // confirmed this turn working earlier. AFTER [_loadIndex]: closing a stale
    // segment persists it, and writing needs THIS room's seq index.
    _syncTurnStateFromRoomMeta();
    _writeRuntime();
  }

  Future<void> sendMessage(
    String text, {
    List<MessageImage>? images,
    List<OutgoingFile>? files,
    UserMessageStreamingBehavior? streamingBehavior,
  }) async {
    final imgs = images ?? const [];
    final fls = files ?? const [];
    final epk = _activeEpk;
    final id = _newId();
    final now = DateTime.now();
    final isSteer = streamingBehavior == UserMessageStreamingBehavior.steer;
    // Optimistic pending row (#defaults: optimistic + dedupe by id).
    final t = epk != null ? _turn(epk, _activeRoomId) : null;
    if (epk != null) {
      await _upsert(
        MsgRole.user,
        id,
        (seq, _) => MessageRecord(
          id: id,
          seq: seq,
          role: MsgRole.user,
          text: text,
          images: imgs,
          // The Pi's path only arrives with the echo; the pending rows show
          // the names so the bubbles read correctly while they are in flight.
          files: fls.map((f) => MessageFile(name: f.name)).toList(),
          ts: now,
          pending: true,
          steering: isSteer,
        ),
      );
      if (!isSteer) {
        _setWorking(
          t!,
          true,
          preview: _preview(text, imgs, fls.map((f) => MessageFile(name: f.name)).toList()),
          replyTo: id,
        );
      }
      // Arm the no-echo backstop for this row. The timeout is keyed off the
      // row's `ts`, NOT online-ness: an offline "held pending" send is reaped
      // 20s after its ts too, and ANY pending row is re-armed on session load
      // (see _loadIndex). So a quick session-switch or an app restart still
      // reaps a stale bubble instead of letting it spin "sending…" forever.
      _armSendTimeout(id, now);
    }
    final ch = _conn.channel;
    if (ch == null) {
      debugPrint(
        '[msg-send] id=$id (offline → held pending, reaped in '
        '${pendingSendTimeout.inSeconds}s)',
      );
      return;
    }
    // Seed an EMPTY streaming buffer so the blinking cursor shows during the
    // "thinking" gap before the first agent_chunk (pre-31 behavior). In-memory
    // only (#7) — never written to the DB. agent_chunk appends; agent_done
    // clears it (even for a text-less, tool-only turn).
    // Steering messages should not create a new cursor, because they do not
    // start a fresh assistant turn.
    if (!isSteer && t != null) {
      _emitStreaming(t, StreamingMessage(inReplyTo: id));
    }
    debugPrint('[msg-send] id=$id text=${_preview(text, imgs, fls.map((f) => MessageFile(name: f.name)).toList())}');
    await ch.send(
      UserMessage(
        id: id,
        text: text,
        streamingBehavior: streamingBehavior,
        images: imgs.isEmpty
            ? null
            : imgs.map((i) => WireImage(data: i.data, mime: i.mime)).toList(),
        files: fls.isEmpty
            ? null
            : fls.map(
                (f) => WireFile(name: f.name, text: f.text, path: f.path),
              ).toList(),
      ),
    );
  }

  /// Arm (or re-arm) the silent no-echo backstop for a pending row, keyed by
  /// `id`. The window is the time REMAINING relative to the row's [ts], so a
  /// row loaded from disk already past [pendingSendTimeout] fires immediately
  /// (floored at zero). Idempotent — cancels any existing timer for `id`.
  void _armSendTimeout(String id, DateTime ts) {
    _pendingSendTimers.remove(id)?.cancel();
    final remaining = pendingSendTimeout - DateTime.now().difference(ts);
    _pendingSendTimers[id] = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      () => _onSendTimeout(id),
    );
  }

  /// No echo arrived within [pendingSendTimeout]: drop the optimistic bubble
  /// silently and unwind only the turn state that belongs to THIS `id`.
  void _onSendTimeout(String id) {
    _pendingSendTimers.remove(id);
    // ignore: discarded_futures
    _removeById(id);
    final t = _activeTurn;
    // Clear the thinking cursor only if it's seeded for this message.
    if (t != null && t.streaming?.inReplyTo == id) _emitStreaming(t, null);
    // Clear working ONLY if this id owns it — never knock down a turn that a
    // different (echoed) message is already driving.
    if (t != null && t.workingReplyTo == id) _setWorking(t, false);
    debugPrint(
      '[msg-timeout] id=$id removed (no echo in '
      '${pendingSendTimeout.inSeconds}s)',
    );
  }

  void _cancelAllSendTimers() {
    for (final t in _pendingSendTimers.values) {
      t.cancel();
    }
    _pendingSendTimers.clear();
  }

  /// Test seam — number of armed no-echo timers (asserts no leak on reset).
  @visibleForTesting
  int get debugPendingSendTimerCount => _pendingSendTimers.length;

  /// Test seam — deliver one already-decoded server frame through the normal
  /// dispatch path. Lets a widget test drive a frame the relay would send
  /// (e.g. an extension's notify) without standing up a socket.
  @visibleForTesting
  void onServerMessageForTest(ServerMessage msg) => _onServerMessage(msg);

  Future<void> queueMessage(String text) async {
    final ch = _conn.channel;
    if (ch == null) return;
    final epk = _activeEpk;
    if (epk == null) return;
    final t = _turn(epk, _activeRoomId);
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final id = _newId();
    _setQueuedMessages(t, [
      ...t.queuedMessages,
      QueuedMsg(
        id: id,
        text: trimmed,
        editable: true,
        createdAt: DateTime.now(),
      ),
    ]);
    await ch.send(QueuedMessageSet(id: id, text: trimmed));
  }

  Future<void> setQueuedMessage(String text) => queueMessage(text);

  Future<void> clearQueuedMessage([String? targetId]) async {
    final epk = _activeEpk;
    if (epk == null) return;
    final t = _turn(epk, _activeRoomId);
    if (targetId == null) {
      _setQueuedMessages(t, const []);
    } else {
      _setQueuedMessages(t, [
        for (final item in t.queuedMessages)
          if (item.id != targetId) item,
      ]);
    }
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(QueuedMessageClear(id: _newId(), targetId: targetId));
  }

  Future<void> clearQueuedMessages() => clearQueuedMessage();

  Future<void> cancel(String targetId) async {
    // User-driven cancel of this message → disarm its no-echo backstop too.
    _pendingSendTimers.remove(targetId)?.cancel();
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(Cancel(id: _newId(), targetId: targetId));
  }

  /// Plan/57 — respond to an interactive extension_ui_request (ask_user).
  /// The ChatViewModel builds the [ExtensionUiResponse] (value/confirmed/
  /// cancelled + optional `ask` envelope); the SyncService just ships it.
  /// Returns false when there is no live channel or the send fails so the
  /// caller can surface a retryable failure immediately instead of waiting on
  /// the sheet's 25s backstop.
  Future<bool> respondExtensionUi(ExtensionUiResponse resp) async {
    final ch = _conn.channel;
    if (ch == null) return false;
    try {
      await ch.send(resp);
      return true;
    } catch (error) {
      debugPrint('[extension-ui] failed to send response: $error');
      return false;
    }
  }

  Future<void> approveTool(String toolCallId, ApproveDecision decision) async {
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(
      ApproveTool(id: _newId(), toolCallId: toolCallId, decision: decision),
    );
    await _upsert(MsgRole.tool, toolCallId, (seq, existing) {
      final base =
          existing?.tool ??
          ToolEventData(toolCallId: toolCallId, tool: 'unknown');
      return (existing ??
              MessageRecord(
                id: toolCallId,
                seq: seq,
                role: MsgRole.tool,
                ts: DateTime.now(),
                model: _activeRoomModel,
              ))
          .copyWith(
            tool: base.copyWith(
              status: decision == ApproveDecision.allow
                  ? ToolEventStatus.allowed
                  : ToolEventStatus.denied,
            ),
          );
    });
  }

  void requestSync() {
    final ch = _conn.channel;
    if (ch == null || _activeEpk == null) {
      _pendingSyncRequest = true;
      return;
    }
    _pendingSyncRequest = false;
    // Resume from the newest event this device holds, so a reconnect or a
    // re-entry into a room it already has transfers only what is new. The Pi
    // answers a cursor it cannot place with a full replay, which is the same
    // substitute-the-cache behaviour as before — so a missing or stale cursor
    // costs nothing but a round trip it was going to make anyway.
    final id = _newId();
    _syncAsked[id] = DateTime.now();
    while (_syncAsked.length > _maxSyncAsked) {
      _syncAsked.remove(_syncAsked.keys.first);
    }
    final since = _syncCursorFor(_activeEpk!, _activeRoomId);
    debugPrint(
      '[sync] session_sync room=$_activeRoomId '
      'since=${since == null ? 'none → full replay' : 'cursor'}',
    );
    ch.send(SessionSync(id: id, since: since));
  }

  /// The resume token stored for `(epk, room)`, or null when this device has
  /// never applied a history for it (or has since dropped it).
  String? _syncCursorFor(String epk, String room) {
    if (epk != _activeEpk || room != _activeRoomId) return null;
    return _syncCursor;
  }

  /// Plan/28 — `session_new` acked: wipe the active session's rows + index.
  Future<void> clearActiveSession() async {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    final t = _turn(epk, room);
    // Session wiped → any optimistic sends/streaming/working state are moot.
    _cancelAllSendTimers();
    _discardStreamingState(t);
    _setQueuedMessages(t, const []);
    _setTodos(t, TodoState());
    _setWorking(t, false);
    await _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      await box.clear();
      _idToSeq.clear();
      _nextSeq = 0;
      // The wiped session has neither a resume token nor a replay frontier: a
      // leftover cursor would make the next sync a delta on top of an empty box.
      _syncCursor = null;
      _syncedRows = null;
      _indexLoaded = true;
      final idx = _boxes.sessionsIndexBox();
      await idx.delete(LocalBoxes.sessionKey(epk, room));
    });
  }

  // ---------------------------------------------------------------------------
  // Channel → DB (active room) + per-room turn state
  // ---------------------------------------------------------------------------

  void _onStatus(ConnectionStatus s) {
    _msgSub?.cancel();
    _msgSub = null;
    if (s is StatusOnline) {
      // Plan/32f — bind these writes to the PEER that owns the channel RIGHT
      // NOW. After a `switchTo`, a late frame from the OLD peer's channel must
      // not land in the NEW session's box: `_activeEpk` has already moved (the
      // chat calls `activate()` before `switchTo`), so a straggler chat-1 frame
      // would otherwise be written to chat-2's box and bleed across until
      // chat-2's history re-applied.
      final originEpk = _conn.activePeer?.remoteEpk;
      // A channel that tags its frames (production WS, via [IRoomFrameLink])
      // is consumed through `roomMessages` ONLY — decoding the same envelope
      // twice would append every streamed delta twice. `serverMessages` is the
      // fallback for channels with no room attribution (in-memory transports,
      // test fakes): there every frame necessarily belongs to the bound room.
      if (s.channel is! IRoomFrameLink) {
        _msgSub = s.channel.serverMessages.listen(
          (msg) => _onServerMessage(msg, originEpk),
          onError: (Object _, StackTrace _) {},
        );
      }
      // ignore: discarded_futures
      _onlineActivated();
    }
    _writeRuntime();
  }

  /// One inbound frame, tagged with the room that produced it — the single feed
  /// for both the session writer and every room's in-memory turn state.
  ///
  /// The room comes from the FRAME, never from the connection's addressed room:
  /// `ConnectionManager.switchRoom` is one mutable field that chat pages,
  /// notification taps and room rides all re-assert, so it drifts away from the
  /// chat on screen. Trusting it wrote another session's frames into the open
  /// transcript while the open chat's own frames were skipped as "background" —
  /// a room Home showed as idle displayed a stranger's reasoning, with the
  /// working pill and thinking counter (`startedAt`) carried over from it.
  void _onRoomMessage(RoomMessage m) {
    if (m.epk == _activeEpk && m.roomId == _activeRoomId) {
      // The chat on screen: the session writer owns it, DB rows included.
      _onServerMessage(m.message, m.epk);
      return;
    }
    // Some other room — in-memory turn state only, so a streaming room the
    // user is not viewing keeps filling its own slot.
    final t = _turn(m.epk, m.roomId);
    switch (m.message) {
      case AgentChunk(:final inReplyTo, :final delta):
        _applyChunk(t, inReplyTo, delta);
      case AgentThinking(:final inReplyTo, :final delta):
        _applyThinking(t, inReplyTo, delta);
      case AgentDone(:final inReplyTo):
        _applyAgentDone(t, inReplyTo);
      case UserInput(
        :final id,
        :final text,
        :final images,
        :final files,
        :final streamingBehavior,
      ):
        if (t.queuedMessages.any((item) => item.id == id)) {
          _setQueuedMessages(t, [
            for (final item in t.queuedMessages)
              if (item.id != id) item,
          ]);
        }
        if (streamingBehavior == UserMessageStreamingBehavior.steer) {
          _setActivity(
            m.epk,
            m.roomId,
            SessionActivity.working,
            preview: _userText(text),
          );
        } else {
          _setWorking(
            t,
            true,
            preview: _preview(
              _userText(text),
              _messageImages(images),
              _messageFiles(files),
            ),
            replyTo: id,
          );
          if (t.streaming?.inReplyTo != id) {
            _emitStreaming(t, StreamingMessage(inReplyTo: id));
          }
        }
      case Cancelled(:final targetId):
        _pendingSendTimers.remove(targetId)?.cancel();
        _applyCancelled(t, targetId);
      case UploadComplete():
        // Consumed by the upload service (its own subscription on this
        // broadcast stream); the transcript ignores it.
        break;
      case ErrorMessage():
        _discardStreamingState(t);
        _setWorking(t, false);
      case QueuedMessageState(:final items):
        _setQueuedMessages(t, [
          for (final item in items)
            QueuedMsg(
              id: item.id,
              text: item.text,
              editable: item.editable,
              createdAt: item.createdAt,
            ),
        ]);
      case final TodoState todos:
        // Plan/63 — a background room's list updates in its own slot, so
        // opening that chat shows the rows without waiting for a re-sync.
        _setTodos(t, todos);
      default:
        // DB-backed frames (AgentMessage, Tool*, SessionHistory, …) for a
        // background room: not the writer's job; recovered by re-sync.
        break;
    }
  }

  Future<void> _onlineActivated() async {
    final peer = _conn.activePeer;
    if (peer != null && _activeEpk == null) {
      await activate(peer.remoteEpk, _conn.activeRoomId);
    }
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 200), requestSync);
    if (_pendingSyncRequest) requestSync();
  }

  void _onServerMessage(ServerMessage msg, [String? originEpk]) {
    // Plan/32f — drop frames from a peer whose channel is no longer the active
    // session (a stale connection still draining after `switchTo`). Without
    // this, a straggler write targets `_activeEpk` — which already points at
    // the NEW chat — and bleeds the old session's messages into the new box.
    // Only gate when BOTH origin and active are set and differ: pre-bind
    // (`_activeEpk == null`, cold boot before `activate`) must still flow, and
    // direct test calls without an origin aren't gated.
    if (originEpk != null && _activeEpk != null && originEpk != _activeEpk) {
      return;
    }
    // Turn-state slot for the active room (null pre-bind, before any
    // activate — DB writes are no-ops then too, so skipping turn state is
    // consistent).
    final epk = _activeEpk;
    final t = epk != null ? _turn(epk, _activeRoomId) : null;
    switch (msg) {
      case AgentChunk(:final inReplyTo, :final delta):
        if (t == null) return;
        _applyChunk(t, inReplyTo, delta);

      case AgentThinking(:final inReplyTo, :final delta):
        if (t == null) return;
        _applyThinking(t, inReplyTo, delta);

      case AgentDone(:final inReplyTo):
        if (t == null) return;
        _applyAgentDone(t, inReplyTo);

      case AgentMessage(:final inReplyTo, :final text):
        // ignore: discarded_futures
        _upsert(
          MsgRole.assistant,
          inReplyTo,
          (seq, existing) =>
              existing ??
              MessageRecord(
                id: inReplyTo,
                seq: seq,
                role: MsgRole.assistant,
                text: text,
                ts: DateTime.now(),
                model: _activeRoomModel,
              ),
        );

      case QueuedMessageState(:final items):
        if (t == null) return;
        _setQueuedMessages(t, [
          for (final item in items)
            QueuedMsg(
              id: item.id,
              text: item.text,
              editable: item.editable,
              createdAt: item.createdAt,
            ),
        ]);

      case SteerConsumed(:final id):
        _clearSteeringLabel(id);

      case final TodoState todos:
        if (t == null) return;
        _setTodos(t, todos);

      case UserInput(
        :final id,
        :final text,
        :final images,
        :final files,
        :final streamingBehavior,
      ):
        // Echo dedupes against the optimistic row (same id): confirm it
        // (pending=false) or insert as confirmed (foreign device).
        debugPrint('[msg-echo] id=$id');
        // Echo arrived → the send landed; disarm the no-echo backstop.
        _pendingSendTimers.remove(id)?.cancel();
        if (t != null && t.queuedMessages.any((item) => item.id == id)) {
          _setQueuedMessages(t, [
            for (final item in t.queuedMessages)
              if (item.id != id) item,
          ]);
        }
        // ignore: discarded_futures
        _upsert(
          MsgRole.user,
          id,
          (seq, existing) => existing != null
              // The echo is where the Pi reports the path it saved an upload
              // to, so merge it in rather than keeping the local name-only row.
              ? existing.copyWith(pending: false, files: _messageFiles(files))
              : MessageRecord(
                  id: id,
                  seq: seq,
                  role: MsgRole.user,
                  text: _userText(text),
                  images: _messageImages(images),
                  files: _messageFiles(files),
                  ts: DateTime.now(),
                ),
        );
        if (t == null) return;
        // Steering input should not start/replace the working turn bubble.
        if (streamingBehavior == UserMessageStreamingBehavior.steer) {
          _setActivity(
            epk!,
            _activeRoomId,
            SessionActivity.working,
            preview: _userText(text),
          );
        } else {
          _setWorking(t, true, preview: _userText(text), replyTo: id);
          // Show the thinking cursor for this turn (foreign-device echo, or the
          // local echo when the send-seed was already cleared). Guarded so it
          // never wipes a buffer that's already accumulating for this id.
          if (t.streaming?.inReplyTo != id) {
            _emitStreaming(t, StreamingMessage(inReplyTo: id));
          }
        }

      case ToolRequest(:final toolCallId, :final tool, :final args):
        // Sequential ordering: close the open segment(s) as their own rows
        // BEFORE the tool, so "reasoning → narration → command → narration"
        // renders in order instead of all text landing after the commands.
        if (t != null) {
          _finalizeThinkingSegment(t);
          _finalizeTextSegment(t);
        }
        // `send_to_phone` has its own card (see `FileOffer`); a tool card for
        // the same event would just be a duplicate. Remember the call so the
        // matching `tool_result` can be judged too (a FAILURE still becomes a
        // tool row — the only place the user learns it didn't go).
        if (tool == _sendToPhoneTool) {
          _attachmentToolCalls.add(toolCallId);
          break;
        }
        // ignore: discarded_futures
        _upsert(
          MsgRole.tool,
          toolCallId,
          (seq, existing) =>
              existing ??
              MessageRecord(
                id: toolCallId,
                seq: seq,
                role: MsgRole.tool,
                ts: DateTime.now(),
                model: _activeRoomModel,
                tool: ToolEventData(
                  toolCallId: toolCallId,
                  tool: tool,
                  args: args,
                  write: _writeToolCalls.contains(toolCallId),
                ),
              ),
        );

      case ToolWrite(:final toolCallId, :final write):
        if (!write) break;
        _writeToolCalls.add(toolCallId);
        // No row yet: `ToolRequest`/`ToolResult` will mark it when it appears.
        if (_idToSeq[_key(MsgRole.tool, toolCallId)] == null) break;
        // ignore: discarded_futures
        _upsert(MsgRole.tool, toolCallId, (seq, existing) {
          final base =
              existing?.tool ??
              ToolEventData(toolCallId: toolCallId, tool: 'unknown');
          return (existing ??
                  MessageRecord(
                    id: toolCallId,
                    seq: seq,
                    role: MsgRole.tool,
                    ts: DateTime.now(),
                    model: _activeRoomModel,
                  ))
              .copyWith(tool: base.copyWith(write: true));
        });

      case ToolResult(:final toolCallId, :final result, :final error, :final diff):
        // A `send_to_phone` that succeeded is already on screen as its
        // attachment card; only the failure needs the tool timeline.
        if (_attachmentToolCalls.remove(toolCallId) && error == null) break;
        // ignore: discarded_futures
        _upsert(MsgRole.tool, toolCallId, (seq, existing) {
          final base =
              existing?.tool ??
              ToolEventData(toolCallId: toolCallId, tool: 'unknown');
          return (existing ??
                  MessageRecord(
                    id: toolCallId,
                    seq: seq,
                    role: MsgRole.tool,
                    ts: DateTime.now(),
                    model: _activeRoomModel,
                  ))
              .copyWith(
                tool: base.copyWith(
                  status: error != null
                      ? ToolEventStatus.failed
                      : ToolEventStatus.completed,
                  result: result,
                  error: error,
                  diff: diff,
                  write: base.write || _writeToolCalls.contains(toolCallId),
                ),
              );
        });

      case Cancelled(:final targetId):
        _pendingSendTimers.remove(targetId)?.cancel();
        if (t != null) _applyCancelled(t, targetId);

      case Bye(:final rawReason):
        if (!_eventController.isClosed) {
          _eventController.add(PeerWentOffline(rawReason));
        }
        if (t != null) {
          _clearSteeringLabels();
          _discardStreamingState(t);
          _setWorking(t, false);
        }
        final peer = _conn.activePeer;
        if (peer != null) {
          // ignore: discarded_futures
          _conn.switchTo(peer);
        }

      case SessionHistory():
        // ignore: discarded_futures
        _applyHistory(msg);

      case UploadComplete():
        break; // the upload service owns this stream; nothing to store
      case ErrorMessage(:final code, :final message):
        if (code.contains('unknown_peer')) {
          if (!_eventController.isClosed) {
            _eventController.add(const PairingRevoked());
          }
          break;
        }
        if (t != null) {
          _discardStreamingState(t);
          _setWorking(t, false);
        }
        _clearSteeringLabels();
        // ignore: discarded_futures
        _upsert(
          MsgRole.assistant,
          _newId(),
          (seq, _) => MessageRecord(
            id: 'err_$seq',
            seq: seq,
            role: MsgRole.assistant,
            // A known transport code is worth labelling; a Pi-side marker like
            // `command_failed` is bookkeeping, and its message is the part
            // written for a human — so that stands alone.
            text: _labelledError(code, message),
            ts: DateTime.now(),
            model: _activeRoomModel,
          ),
        );

      case Compaction(:final summary, :final tokensBefore, :final ts):
        _writeCompaction(summary, tokensBefore, ts);

      case FileOffer(
        :final id,
        :final name,
        :final path,
        :final mime,
        :final size,
        :final data,
        :final note,
        :final resized,
        :final originalSize,
        :final toolCallId,
      ):
        // The Pi handing us a file (`send_to_phone`, or the answer to a
        // `file_get`). Sequential ordering: the card belongs where the tool ran,
        // so close the open text/reasoning segments first, exactly like
        // `ToolRequest` does.
        if (t != null) {
          _finalizeThinkingSegment(t);
          _finalizeTextSegment(t);
        }
        // ignore: discarded_futures
        _writeAttachment(
          id: id,
          name: name,
          path: path,
          mime: mime,
          size: size,
          data: data,
          note: note,
          resized: resized,
          originalSize: originalSize,
          toolCallId: toolCallId,
        );

      case FileSendStart(
        :final id,
        :final name,
        :final path,
        :final mime,
        :final size,
        :final note,
      ):
        // The same hand-off, streamed: the file does not fit one envelope.
        // Sequential ordering is the same, so the card lands where the tool ran.
        if (t != null) {
          _finalizeThinkingSegment(t);
          _finalizeTextSegment(t);
        }
        // ignore: discarded_futures
        _beginIncomingTransfer(
          id: id,
          name: name,
          path: path,
          mime: mime,
          size: size,
          note: note,
        );

      case FileSendChunk(:final id, :final index, :final data):
        // ignore: discarded_futures
        _appendIncomingChunk(id: id, index: index, data: data);

      case FileSendEnd(:final id, :final sha256):
        // ignore: discarded_futures
        _finishIncomingTransfer(id: id, sha256: sha256);

      case ExtensionUiRequest():
        // Plan/57 — transient interactive prompt (ask_user via pi-ask).
        // Surface to the UI; never persist (it's a live request, not history).
        _extensionUiController.add(msg);
        break;
      case Pong():
      case PairOk():
      case PairError():
      case ActionOk():
      case ActionError():
      case ModelsList():
      // Command channel: the `/` palette catalogue is consumed by the
      // ActionsRepository (it asked for it), the action replies with it, and a
      // `!` shell execution rides the normal tool stream as a `bash` card.
      // Nothing here belongs in the transcript.
      case CommandsList():
      // Session picker (plan/59): consumed by the ActionsRepository (it asked
      // for it). Nothing belongs in the transcript.
      case SessionsList():
        break;
    }
  }

  /// Error text for the transcript: `⚠ code: message` for transport codes the
  /// app knows, `⚠ message` for Pi-side markers (`command_failed`, …) whose
  /// code is bookkeeping rather than something to show.
  static String _labelledError(String code, String message) {
    if (!_knownErrorCodes.contains(code)) return '⚠ $message';
    return '⚠ $code: $message';
  }

  /// Plan/32 — persist a compaction as a system row so it renders a system
  /// bubble in the chat and survives a re-sync. Keyed by `ts` when present so
  /// the live message and its history replay collapse to one row.
  void _writeCompaction(String summary, int? tokensBefore, int? ts) {
    final id = 'compaction_${ts ?? uuid7()}';
    final when = ts != null
        ? DateTime.fromMillisecondsSinceEpoch(ts)
        : DateTime.now();
    // ignore: discarded_futures
    _upsert(
      MsgRole.compaction,
      id,
      (seq, existing) =>
          existing ??
          MessageRecord(
            id: id,
            seq: seq,
            role: MsgRole.compaction,
            text: summary,
            tokensBefore: tokensBefore,
            ts: when,
            model: _activeRoomModel,
          ),
    );
  }

  /// Pi → App file hand-off: cache the bytes, then upsert the card.
  ///
  /// Metadata-only offers (a replay that raced ahead of the bytes) keep the
  /// card and leave `blob` untouched, so a card that already has its content
  /// never degrades into a "tap to load" placeholder because a re-sync landed.
  Future<void> _writeAttachment({
    required String id,
    required String name,
    required String path,
    required String mime,
    required int size,
    required String? data,
    required String? note,
    required bool resized,
    required int? originalSize,
    String? toolCallId,
    /// Blob already stored by the chunked receive path (the bytes never reach
    /// this method — they went straight to disk).
    String? storedBlob,
    /// Why the transfer stopped, for the card to show instead of a preview.
    String? error,
  }) async {
    String? blob = storedBlob;
    if (blob == null && data != null && data.isNotEmpty) {
      try {
        blob = await _attachmentStore()?.put(id, base64Decode(data));
      } catch (_) {
        // A malformed payload must not kill the card: the metadata still tells
        // the user what the Pi tried to send.
        blob = null;
      }
    }
    // ignore: discarded_futures
    _upsert(
      MsgRole.attachment,
      id,
      (seq, existing) => MessageRecord(
        id: id,
        seq: seq,
        role: MsgRole.attachment,
        ts: existing?.ts ?? DateTime.now(),
        model: existing?.model ?? _activeRoomModel,
        attachment: AttachmentData(
          name: name,
          path: path,
          mime: mime,
          size: size,
          note: note,
          resized: resized,
          originalSize: originalSize,
          blobName: blob ?? existing?.attachment?.blobName,
          error: error,
          // The bytes a `file_get` brings back carry no tool call, so an
          // existing association has to survive the upsert — otherwise the
          // card would jump out of the tool row the moment the user taps it.
          toolCallId: toolCallId ?? existing?.attachment?.toolCallId,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Chunked Pi → App transfers (`file_send_*`)
  // ---------------------------------------------------------------------------
  //
  // The card exists from the FIRST frame, so the user watches the transfer
  // instead of a dead chat during a 100 MiB push. Progress itself is in-memory
  // ([fileReceiveOf]): writing a row per chunk would put a base64-sized file
  // through Hive for a number that only repaints a bar.

  void _sendToChannel(ClientMessage msg) {
    final ch = _conn.channel;
    if (ch == null) return;
    // ignore: discarded_futures
    ch.send(msg);
  }

  void _emitFileReceive(String id) {
    if (!_fileReceiveController.isClosed) _fileReceiveController.add(id);
  }

  IncomingFiles? _incomingStore() {
    final existing = _incomingFiles;
    if (existing != null) return existing;
    final store = _attachmentStore();
    if (store == null) return null;
    return _incomingFiles = IncomingFiles(store);
  }

  Future<void> _beginIncomingTransfer({
    required String id,
    required String name,
    required String path,
    required String mime,
    required int size,
    String? note,
  }) async {
    final sink = _incomingStore();
    if (sink == null) {
      _sendToChannel(
        FileSendAbort(
          id: id,
          code: 'unavailable',
          message: 'The chat is not bound to a session yet',
        ),
      );
      return;
    }
    try {
      await sink.begin(id: id, size: size);
    } on IncomingFileError catch (e) {
      _sendToChannel(FileSendAbort(id: id, code: e.code, message: e.message));
      return;
    }
    _incomingCards[id] = _IncomingCard(
      name: name,
      path: path,
      mime: mime,
      size: size,
      note: note,
    );
    _fileReceive[id] = FileReceiveProgress(
      id: id,
      name: name,
      received: 0,
      total: size,
    );
    // Ready before the row write: the Pi starts streaming immediately, and the
    // card catches up a moment later.
    _sendToChannel(FileSendReady(id: id));
    _emitFileReceive(id);
    await _writeAttachment(
      id: id,
      name: name,
      path: path,
      mime: mime,
      size: size,
      data: null,
      note: note,
      resized: false,
      originalSize: null,
    );
  }

  Future<void> _appendIncomingChunk({
    required String id,
    required int index,
    required String data,
  }) async {
    final sink = _incomingFiles;
    if (sink == null) {
      _sendToChannel(
        FileSendAbort(
          id: id,
          code: 'session_lost',
          message: 'No transfer with that id',
        ),
      );
      return;
    }
    try {
      final received = await sink.append(id: id, index: index, data: data);
      final current = _fileReceive[id];
      if (current != null) {
        _fileReceive[id] = current.advancedTo(received);
        _emitFileReceive(id);
      }
      _sendToChannel(FileSendAck(id: id, index: index));
    } on IncomingFileError catch (e) {
      await _failIncomingTransfer(id, e);
    }
  }

  Future<void> _finishIncomingTransfer({
    required String id,
    required String sha256,
  }) async {
    final sink = _incomingFiles;
    final card = _incomingCards[id];
    if (sink == null || card == null) {
      _sendToChannel(
        FileSendAbort(
          id: id,
          code: 'session_lost',
          message: 'No transfer with that id',
        ),
      );
      return;
    }
    final String blob;
    try {
      blob = await sink.finish(id: id, sha256: sha256);
    } on IncomingFileError catch (e) {
      await _failIncomingTransfer(id, e);
      return;
    }
    _incomingCards.remove(id);
    _fileReceive.remove(id);
    _emitFileReceive(id);
    _sendToChannel(FileSendComplete(id: id));
    // The bytes are already in the cache; this only attaches them to the card.
    await _writeAttachment(
      id: id,
      name: card.name,
      path: card.path,
      mime: card.mime,
      size: card.size,
      data: null,
      note: card.note,
      resized: false,
      originalSize: null,
      storedBlob: blob,
    );
  }

  /// Stop one transfer: drop its bytes, tell the Pi why, and leave the card in
  /// place explaining that it never arrived.
  Future<void> _failIncomingTransfer(String id, IncomingFileError error) async {
    await _incomingFiles?.abort(id);
    final card = _incomingCards.remove(id);
    _fileReceive.remove(id);
    _emitFileReceive(id);
    _sendToChannel(
      FileSendAbort(id: id, code: error.code, message: error.message),
    );
    if (card == null) return;
    await _writeAttachment(
      id: id,
      name: card.name,
      path: card.path,
      mime: card.mime,
      size: card.size,
      data: null,
      note: card.note,
      resized: false,
      originalSize: null,
      error: error.message,
    );
  }

  Future<void> _abortIncomingTransfers() async {
    if (_incomingCards.isEmpty && _fileReceive.isEmpty) return;
    final ids = {..._incomingCards.keys, ..._fileReceive.keys};
    await _incomingFiles?.abortAll();
    _incomingCards.clear();
    _fileReceive.clear();
    for (final id in ids) {
      _emitFileReceive(id);
    }
  }

  Future<void> _applyHistory(SessionHistory h) async {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    final replayed = _convertHistory(h.events);
    debugPrint(
      '[sync] history in ${h.isDelta ? 'delta' : 'full'} '
      'events=${h.events.length} rows=${replayed.length} '
      'truncated=${h.truncated} cursor=${h.cursor == null ? 'none' : 'given'}',
    );
    // A reply describes the session as the Pi saw it when it answered, so a row
    // this device wrote AFTER asking cannot be in it. Those rows stay: dropping
    // them would lose them for good, because this reply's own cursor already
    // points past them — a picture sent while the sync was in flight would never
    // come back.
    final askedAt = _takeSyncRequest(h.inReplyTo);
    bool isNewer(MessageRecord r) {
      // A pending row is preserved on its own below, whatever its age.
      if (r.pending) return false;
      final ts = r.ts;
      return askedAt == null ? false : ts != null && ts.isAfter(askedAt);
    }

    // Read and apply hold the SAME write slot: a live frame landing between the
    // two would be a row this reply knows nothing about, and the merge below is
    // written against the rows that were on disk when it read.
    await _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      final onDisk = box.toMap().entries.toList()
        ..sort((a, b) => (a.key as num).compareTo(b.key as num));
      final existing = [
        for (final e in onDisk)
          (seq: (e.key as num).toInt(), row: MessageRecord.fromJson(_coerce(e.value))),
      ];
      final newer = [
        for (final e in existing)
          if (isNewer(e.row)) e.row,
      ];
      final List<MessageRecord> rows;
      final List<MessageRecord> superseded;
      final int frontier;
      // Where this reply's own rows start in [rows]: after the already replayed
      // prefix for a delta, at the beginning for a full replay.
      var replayedFrom = 0;
      if (!h.isDelta) {
        // A pending bubble is the app's own, unconfirmed copy of something the
        // reply cannot describe yet: it is preserved below, never superseded.
        superseded = [
          for (final e in existing)
            if (!isNewer(e.row) && !e.row.pending) e.row,
        ];
        rows = [...replayed, ...newer];
        frontier = replayed.length;
      } else {
        // A delta carries only what the Pi sent after the cursor this device
        // last stored, so it lands on top of the rows on disk: the rows a replay
        // already produced ([_syncedRows]) stand as they are, and the live tail
        // past them is what this reply re-delivers. With no request time nothing
        // counts as newer, so the matching alone decides which tail rows go.
        final cut = _syncedRows == null
            ? existing.length
            : math.min(_syncedRows!, existing.length);
        final kept = [
          for (final e in existing)
            if (e.seq < cut) e.row,
        ];
        final appended = _convertHistory(h.events, seqOffset: kept.length);
        // Rows this reply repeats of the ones already replayed fold into them,
        // leaving [fresh] as the part of the reply the cache has never seen.
        final folded = _mergeReplayed(kept, appended);
        final fresh = folded.fresh;
        // Which tail rows this reply re-delivers. Time alone cannot say it: the
        // Pi answers a snapshot, so a row written a moment before the request
        // can still be missing from the reply (its event had not been persisted
        // yet) — and that row would be lost for good, because the reply's own
        // cursor already points past it. So a row is only replaced when the
        // reply brings the same thing back; anything else waits, on screen, for
        // the reply that owns it.
        final replaced = <MessageRecord>[];
        final tail = [
          for (final e in existing)
            if (e.seq >= cut) e.row,
        ];
        final brought = _contentRows(fresh);
        // Where each tail row's copy sits in this reply (null: not brought back).
        final twinAt = <int?>[];
        for (final row in tail) {
          final twin = _claimedBy(row, brought);
          if (twin == null) {
            twinAt.add(null);
            continue;
          }
          // The reply's copy stands in for the live one — carrying over what
          // only the live row knew (a tool's name and args, see [_adopt]).
          final at = fresh.indexOf(twin);
          if (at >= 0) fresh[at] = _adopt(row, twin);
          twinAt.add(at < 0 ? null : at);
          replaced.add(row);
        }
        // The tail in the REPLY's order — that is the Pi's own, the order the
        // session file was written in — with every live row the reply does not
        // bring back inserted just before the reply row that followed it on
        // disk. Hanging them at the end instead moved a row across the ones it
        // preceded: a reasoning block that could not be paired up (see
        // [_claimedBy]) landed BELOW the answer it produced, so the transcript
        // ended on a thinking block.
        final anchored = <int, List<MessageRecord>>{};
        var anchor = fresh.length;
        for (var i = tail.length - 1; i >= 0; i--) {
          final at = twinAt[i];
          if (at != null) {
            anchor = at;
            continue;
          }
          (anchored[anchor] ??= []).insert(0, tail[i]);
        }
        rows = [...folded.kept];
        for (var i = 0; i <= fresh.length; i++) {
          final survivors = anchored[i];
          if (survivors != null) rows.addAll(survivors);
          if (i < fresh.length) rows.add(fresh[i]);
        }
        superseded = replaced;
        frontier = rows.length;
        replayedFrom = kept.length;
      }
      await _reconcileHistoryLocked(
        epk: epk,
        room: room,
        rows: rows,
        frontier: frontier,
        replayedFrom: replayedFrom,
        superseded: superseded,
        sessionStartedAt: h.sessionStartedAt,
        cursor: h.cursor,
        currentModel: h.model,
        currentThinking: h.thinking,
      );
    });
  }

  /// The rows a reply brings, keyed so a live row can be recognised as the same
  /// message. The ids differ on purpose (the app's own id live, `sync_<ts>` on
  /// the way back), so the content is what pairs them — one entry per row, so a
  /// text that appears twice needs two matches, not one.
  static Map<String, List<MessageRecord>> _contentRows(List<MessageRecord> rows) {
    final keys = <String, List<MessageRecord>>{};
    for (final row in rows) {
      final key = _contentKey(row);
      if (key == null) continue;
      (keys[key] ??= []).add(row);
    }
    return keys;
  }

  /// The identity a replayed row and its live twin share, or null when the row
  /// has none (a tool row without a call id).
  static String? _contentKey(MessageRecord r) => switch (r.role) {
    MsgRole.tool => 'tool:${r.tool?.toolCallId}',
    MsgRole.attachment => 'attachment:${r.id}',
    MsgRole.compaction => 'compaction:${r.id}',
    // Pictures are NOT part of it: a replay may come back without them, and that
    // is exactly when the row has to be recognised anyway (see the picture
    // carry-over below).
    MsgRole.user => 'user:${r.text}|${r.files.map((f) => f.name).join(',')}',
    MsgRole.assistant => 'assistant:${r.text}',
    // One bucket for reasoning: their identity embeds a position and the replay
    // may be a capped prefix, so [_claimedBy] pairs them inside the bucket.
    MsgRole.thinking => 'thinking',
  };

  /// The row [brought] re-delivers that stands for [row], if any — consuming it
  /// so two identical messages pair up one to one.
  ///
  /// Reasoning blocks are matched by text instead of a key: their identity
  /// embeds a position, and the copy the Pi sends back is capped (see
  /// [_holdsSameReasoning]) — it is the live text's head plus marker text, which
  /// a plain prefix test never recognises.
  static MessageRecord? _claimedBy(
    MessageRecord row,
    Map<String, List<MessageRecord>> brought,
  ) {
    if (row.role == MsgRole.thinking) {
      final queue = brought[_contentKey(row)];
      if (queue == null) return null;
      final at = queue.indexWhere(
        (t) => _holdsSameReasoning(row.text, t.text),
      );
      return at < 0 ? null : queue.removeAt(at);
    }
    final key = _contentKey(row);
    if (key == null) return null;
    final queue = brought[key];
    if (queue == null || queue.isEmpty) return null;
    return queue.removeAt(0);
  }

  /// The marker the Pi appends to a reasoning block it had to cap on the way out
  /// of `session_history` (16 KiB per block, live streaming is uncapped — see
  /// PROTOCOL.md). Everything before it is a prefix of the whole block.
  static const String _thinkingCapMarker = '…[thinking truncated]';

  /// Whether [live] and [replayed] are the same reasoning block.
  ///
  /// Equality is the normal case; a block past the Pi's cap comes back as its own
  /// head followed by [_thinkingCapMarker], so the two texts differ in the tail
  /// and the replayed one is NOT a prefix of the other.
  static bool _holdsSameReasoning(String live, String replayed) {
    if (live == replayed) return true;
    final cap = replayed.indexOf(_thinkingCapMarker);
    if (cap <= 0) return false;
    // The cap falls inside the text and the marker is separated from it by a
    // newline: drop the marker AND the gap before it, so what is left is the
    // head of the block exactly as the live row cut it.
    final head = replayed.substring(0, cap).trimRight();
    return head.isNotEmpty &&
        live.length > head.length &&
        live.startsWith(head);
  }

  /// The reply's rows folded into the ones already replayed: a reply that
  /// re-delivers an event this device already applied replaces that row instead
  /// of piling a second copy next to it.
  ///
  /// Two `session_sync` requests can be in flight at once (entry + online edge),
  /// and the second reply then repeats what the first one already wrote — the
  /// same identity twice is the same message, not another one. Ids are what the
  /// Pi keys its replay by (it re-names user rows `sync_<ts>`, which is still
  /// stable for ONE message), except for reasoning blocks, whose id embeds their
  /// position in the batch — those match on their content instead.
  ///
  /// Returns the replayed prefix with those copies folded in, plus — in the
  /// reply's own order — the rows that had no home there: the live tail is what
  /// those are matched against.
  static ({List<MessageRecord> kept, List<MessageRecord> fresh}) _mergeReplayed(
    List<MessageRecord> kept,
    List<MessageRecord> appended,
  ) {
    if (appended.isEmpty) {
      return (kept: kept, fresh: const <MessageRecord>[]);
    }
    final byKey = <String, int>{
      for (var i = 0; i < kept.length; i++)
        '${kept[i].role.name}:${kept[i].id}': i,
    };
    final thinking = <String, int>{};
    for (var i = 0; i < kept.length; i++) {
      final ts = kept[i].ts;
      // A session file without timestamps leaves `ts` null: content alone is not
      // an identity then ("let me check" twice is two blocks), so those stay
      // id-only.
      if (kept[i].role == MsgRole.thinking && ts != null) {
        thinking['${ts.millisecondsSinceEpoch}:${kept[i].text}'] = i;
      }
    }
    final merged = [...kept];
    final fresh = <MessageRecord>[];
    for (final row in appended) {
      final at =
          byKey['${row.role.name}:${row.id}'] ??
          (row.role == MsgRole.thinking
              ? thinking['${row.ts?.millisecondsSinceEpoch}:${row.text}']
              : null);
      if (at == null) {
        fresh.add(row);
        continue;
      }
      merged[at] = _adopt(merged[at], row);
    }
    return (kept: merged, fresh: fresh);
  }

  /// [replayed] taking the place of [keptRow].
  ///
  /// A `tool_result` replayed on its own carries no tool name, so the row that
  /// already knows which tool ran (and what it was asked to do) keeps both and
  /// only takes the outcome — otherwise the card would turn into `unknown`
  /// because a sync happened to split the call from its result.
  static MessageRecord _adopt(MessageRecord keptRow, MessageRecord replayed) {
    final known = keptRow.tool;
    final again = replayed.tool;
    if (known == null || again == null) return replayed;
    // A replayed request has no outcome yet; the row that already has one must
    // not go back to looking like it is still running.
    if (again.status == ToolEventStatus.pending &&
        known.status != ToolEventStatus.pending) {
      return keptRow;
    }
    return keptRow.copyWith(
      tool: known.tool == 'unknown'
          ? again
          : known.copyWith(
              status: again.status,
              result: again.result,
              error: again.error,
              diff: again.diff,
            ),
    );
  }

  /// Write [rows] as the room's transcript — plus the index entry that says
  /// where this device resumes from — with the write slot already held.
  ///
  /// [frontier] is how many of [rows] came out of a replay; the rest were
  /// written from live frames after this reply was asked for, and the next reply
  /// is the one that owns them. [superseded] are the rows on disk this reply
  /// replaces: their cached blobs and pictures are carried over, because a
  /// replay carries no bytes. Returns false when the room switched out from
  /// under it.
  Future<bool> _reconcileHistoryLocked({
    required String epk,
    required String room,
    required List<MessageRecord> rows,
    required int frontier,
    required int replayedFrom,
    required List<MessageRecord> superseded,
    required int sessionStartedAt,
    required String? cursor,
    WireModel? currentModel,
    ThinkingLevel? currentThinking,
  }) async {
    if (_activeEpk != epk || _activeRoomId != room) return false;
    // The room's CURRENT model comes from the reply's snapshot, never from the
    // history rows: they only prove what generated PAST replies, so adopting
    // the last assistant row made a fresh model switch look reverted on every
    // replay (re-enter a room / reconnect / session switch) — and it was
    // persisted, so the wrong model survived a cold start.
    if (currentModel != null && currentModel.name.isNotEmpty) {
      _conn.updateRoomModel(epk, room, currentModel.name);
    } else if ((_activeRoomModel ?? '').isEmpty) {
      // Older Pi without the snapshot: harmless self-heal only when the room
      // has NO model at all. Never let it override a model the Pi already
      // confirmed over `room_meta`, since a row can only be older than the
      // room's current selection.
      String? lastAssistantModel;
      for (final r in rows.reversed) {
        if (r.role == MsgRole.assistant) {
          lastAssistantModel = r.model;
          break;
        }
      }
      if (lastAssistantModel != null && lastAssistantModel.isNotEmpty) {
        _conn.updateRoomModel(epk, room, lastAssistantModel);
      }
    }
    // The thinking level has no history rows to infer from, so the snapshot is
    // the only correction path for a room whose meta frame was missed.
    if (currentThinking != null) {
      _conn.updateRoomThinking(epk, room, currentThinking);
    }
    final historyIds = {for (final r in rows) _key(r.role, r.id)};
    // Rows this reply claims are gone on purpose — including a pending bubble it
    // just answered, which must not come back as a second, still-spinning copy.
    final claimed = {for (final r in superseded) _key(r.role, r.id)};
    final box = await _boxes.msgsBox(epk, room);
    // Preserve local pending user rows the Pi hasn't echoed yet.
    final preserved = <MessageRecord>[];
    // Attachment cards come back from history as metadata only, so carry the
    // cached blob name over — otherwise every re-sync would turn a room full
    // of already-seen screenshots back into "tap to load".
    final blobs = <String, String>{};
    // The rows currently on disk, by box position: the picture restore below
    // and the `desired` diff both need the OLD row, not just its value.
    final current = <int, MessageRecord>{};
    final onDisk = box.toMap().entries.toList()
      ..sort((a, b) => (a.key as num).compareTo(b.key as num));
    for (final entry in onDisk) {
      final seq = (entry.key as num).toInt();
      final r = MessageRecord.fromJson(_coerce(entry.value));
      current[seq] = r;
      if (r.role == MsgRole.attachment) {
        final blob = r.attachment?.blobName;
        if (blob != null) blobs[r.id] = blob;
      }
      final key = _key(r.role, r.id);
      if (r.role == MsgRole.user &&
          r.pending &&
          !historyIds.contains(key) &&
          !claimed.contains(key)) {
        preserved.add(r);
      }
    }
    // Pictures the user sent outlive the Pi's copy of them: the bytes are in the
    // phone's archive, and this replay is the only thing that could erase them
    // from the transcript. A replay that comes back WITHOUT the image payload
    // (the Pi's session file was cleaned, or the payload fell out of the replay's
    // byte budget) keeps the picture the same message already had: by position
    // and id for a re-run reply, by text for the live rows this one replaces —
    // a replayed message gets the Pi's id (`sync_<ts>`), not the app's.
    final displaced = <String, List<List<MessageImage>>>{};
    for (final r in superseded) {
      // Every replaced message takes a slot, picture or not: the k-th replayed
      // row of a text is the k-th replaced one, so an image-less message in
      // between must consume its slot instead of handing its neighbour's
      // picture to the wrong bubble.
      if (r.role == MsgRole.user) (displaced[r.text] ??= []).add(r.images);
    }
    // Pair by text only when both sides agree on how many messages carry it: a
    // reply that re-delivers one of two same-text messages cannot say which
    // picture belongs to which, and a wrong picture is worse than none.
    // Only the rows THIS reply produced count: the ones before [replayedFrom]
    // came out of an earlier reply, already carry their pictures, and would
    // otherwise outnumber the pictures waiting here (that mismatch used to drop
    // the picture of a text the room had already seen).
    final replayedOfText = <String, int>{};
    for (var i = replayedFrom; i < frontier && i < rows.length; i++) {
      final r = rows[i];
      if (r.role == MsgRole.user) {
        replayedOfText[r.text] = (replayedOfText[r.text] ?? 0) + 1;
      }
    }
    final pairable = {
      for (final e in displaced.entries)
        if ((replayedOfText[e.key] ?? 0) == e.value.length) e.key,
    };
    for (var i = 0; i < rows.length; i++) {
      final blob = blobs[rows[i].id];
      final a = rows[i].attachment;
      if (blob != null && a != null && a.blobName == null) {
        rows[i] = rows[i].copyWith(
          attachment: AttachmentData(
            name: a.name,
            path: a.path,
            mime: a.mime,
            size: a.size,
            note: a.note,
            resized: a.resized,
            originalSize: a.originalSize,
            blobName: blob,
            toolCallId: a.toolCallId,
          ),
        );
      }
    }
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.role != MsgRole.user) continue;
      var images = row.images;
      // One slot per replayed row, taken whether or not this reply brought the
      // bytes: the k-th replayed row of a text is the k-th replaced row of it.
      List<MessageImage>? carried;
      if (i >= replayedFrom && i < frontier && pairable.contains(row.text)) {
        final queue = displaced[row.text];
        if (queue != null && queue.isNotEmpty) carried = queue.removeAt(0);
      }
      if (images.isEmpty) {
        final old = current[i];
        if (old != null &&
            old.role == MsgRole.user &&
            old.id == row.id &&
            old.text == row.text &&
            old.images.isNotEmpty) {
          images = old.images;
        } else if (carried != null) {
          images = carried;
        }
      }
      if (images.isEmpty) continue;
      rows[i] = row.copyWith(images: await _archiveImages(images, msgsBox: box));
    }
    // Desired ordered state: history (seq = index) then preserved pending.
    final desired = <MessageRecord>[
      for (var i = 0; i < rows.length; i++) rows[i].copyWith(seq: i),
      for (var j = 0; j < preserved.length; j++)
        preserved[j].copyWith(seq: rows.length + j),
    ];
    // Reconcile the box to `desired` with the MINIMUM number of writes.
    //
    // The old path did `box.clear()` + re-put every row. Hive emits a watch
    // event per deleted AND per put key, so the read repo re-emitted ~2N
    // times — tearing the whole list down to EMPTY and rebuilding it — on
    // EVERY SessionHistory the relay re-delivered (which it does on every
    // reconnect). That was the flicker/"embaralha e some". Diffing instead
    // means a re-sent identical history produces ZERO box writes → ZERO
    // emits → no rebuild; a changed history only rewrites the rows that
    // actually differ.
    //
    // A rewrite that DOES change rows still lands one watch event per row, so
    // the box is held quiet for the duration: a reader keeps its mirror current
    // and publishes a single snapshot when the last row is in, instead of
    // rebuilding the whole transcript (and re-following the bottom) per row.
    final gate = LocalBoxes.quietGate(LocalBoxes.msgsBoxName(epk, room));
    var deleted = 0;
    var wrote = 0;
    gate.hold();
    try {
      for (final k in box.keys.toList()) {
        if ((k as num).toInt() >= desired.length) {
          await box.delete(k);
          deleted++;
        }
      }
      for (var i = 0; i < desired.length; i++) {
        final newJson = desired[i].toJson();
        final curRaw = box.get(i);
        // Normalise the stored value through fromJson→toJson so the compare is
        // independent of however Hive ordered the persisted map.
        final curNorm = curRaw == null
            ? null
            : jsonEncode(MessageRecord.fromJson(_coerce(curRaw)).toJson());
        if (curNorm != jsonEncode(newJson)) {
          await box.put(i, newJson);
          wrote++;
        }
      }
    } finally {
      gate.release();
    }
    debugPrint(
      '[sync] history applied room=$room rows=${desired.length} wrote=$wrote '
      'deleted=$deleted preserved=${preserved.length}'
      '${wrote == 0 && deleted == 0 ? ' (cache already matched)' : ''}',
    );
    if (_activeEpk == epk && _activeRoomId == room) {
      _idToSeq
        ..clear()
        ..addEntries([
          for (var i = 0; i < desired.length; i++)
            MapEntry(_key(desired[i].role, desired[i].id), i),
        ]);
      _nextSeq = desired.length;
      // Where this device resumes from, in the SAME write as the rows it
      // describes: a reply landing between a box write and a later index write
      // would otherwise resume from a cursor older than the rows on disk.
      _syncedRows = frontier;
      if (cursor != null) _syncCursor = cursor;
      _indexLoaded = true;
    }
    // The resume token is persisted for the room the reply described even when
    // the chat moved on mid-apply: those rows ARE on disk, and dropping the
    // token here would make the next entry ask for the whole mirror again.
    final idx = _boxes.sessionsIndexBox();
    final indexKey = LocalBoxes.sessionKey(epk, room);
    final raw = idx.get(indexKey);
    final entry = raw is Map
        ? SessionIndexRecord.fromJson(raw.cast<String, dynamic>())
        : SessionIndexRecord(epk: epk, roomId: room);
    await idx.put(
      indexKey,
      entry
          .copyWith(
            sessionStartedAt: DateTime.fromMillisecondsSinceEpoch(
              sessionStartedAt,
            ),
            syncCursor: cursor ?? entry.syncCursor,
            syncedRows: frontier,
          )
          .toJson(),
    );
    return true;
  }

  /// The caption's timestamp. `ts` 0 is the mapper's "unknown" sentinel
  /// (timestamp-less session files) — the row must not render "1970-01-01".
  DateTime? _tsOf(SessionHistoryEvent e) =>
      e.ts > 0 ? DateTime.fromMillisecondsSinceEpoch(e.ts) : null;

  /// Map replayed events onto rows.
  ///
  /// [seqOffset] is where this batch starts in the room's transcript: zero for a
  /// full replay (the rows ARE the transcript), and the number of rows already
  /// stored for a delta. The offset only matters because some row ids embed the
  /// position (thinking rows), and a delta that restarted numbering at zero would
  /// collide with the row it is appending next to.
  List<MessageRecord> _convertHistory(
    List<SessionHistoryEvent> events, {
    int seqOffset = 0,
  }) {
    final out = <MessageRecord>[];
    var seq = seqOffset;
    // A `tool_result` event carries no tool name, so the request is what says
    // "this was a send_to_phone" — and whether its card already exists.
    final toolNameByCallId = <String, String>{};
    // Write verdicts replayed ahead of their `tool_request`, applied when the
    // row is created (see the live `ToolWrite` case for the ordering rules).
    final writeToolCallIds = <String>{};
    for (final e in events) {
      switch (e) {
        case UserInputEvt(:final id, :final text, :final images, :final files):
          out.add(
            MessageRecord(
              id: id,
              seq: seq++,
              role: MsgRole.user,
              text: _userText(text),
              images: _messageImages(images),
              files: _messageFiles(files),
              ts: _tsOf(e),
              model: e.model,
            ),
          );
        case AgentMessageEvt(:final inReplyTo, :final text):
          out.add(
            MessageRecord(
              id: inReplyTo,
              seq: seq++,
              role: MsgRole.assistant,
              text: text,
              ts: _tsOf(e),
              model: e.model,
            ),
          );
        case AgentThinkingEvt(:final text, :final durationMs):
          // Reasoning replayed ahead of the answer of the same message (content
          // order is preserved by the mapper). Id is stable per (ts, index) so
          // a re-sent identical history rewrites nothing.
          if (text.isNotEmpty) {
            out.add(
              MessageRecord(
                id: 'thinking_${e.ts}_$seq',
                seq: seq++,
                role: MsgRole.thinking,
                text: text,
                ts: _tsOf(e),
                model: e.model,
                thinkingMs: durationMs,
              ),
            );
          }
        case ToolWriteEvt(:final toolCallId, :final write):
          if (!write) break;
          writeToolCallIds.add(toolCallId);
          final marked = out.lastIndexWhere(
            (m) => m.role == MsgRole.tool && m.tool?.toolCallId == toolCallId,
          );
          if (marked >= 0) {
            out[marked] = out[marked].copyWith(
              tool: out[marked].tool!.copyWith(write: true),
            );
          }
        case ToolRequestEvt(:final toolCallId, :final tool, :final args):
          toolNameByCallId[toolCallId] = tool;
          // The attachment card replaces this row (see the live `ToolRequest`
          // case). A failed send still arrives as a `ToolResultEvt`, which
          // creates its own row below.
          if (tool == _sendToPhoneTool) break;
          out.add(
            MessageRecord(
              id: toolCallId,
              seq: seq++,
              role: MsgRole.tool,
              ts: _tsOf(e),
              model: e.model,
              tool: ToolEventData(
                toolCallId: toolCallId,
                tool: tool,
                args: args,
                write: writeToolCallIds.contains(toolCallId),
              ),
            ),
          );
        case ToolResultEvt(:final toolCallId, :final result, :final error, :final diff):
          final toolName = toolNameByCallId[toolCallId];
          // A successful send is already on screen as its attachment card.
          if (toolName == _sendToPhoneTool && error == null) break;
          final idx = out.lastIndexWhere(
            (m) => m.role == MsgRole.tool && m.tool?.toolCallId == toolCallId,
          );
          final status = error != null
              ? ToolEventStatus.failed
              : ToolEventStatus.completed;
          if (idx >= 0) {
            out[idx] = out[idx].copyWith(
              tool: out[idx].tool!.copyWith(
                status: status,
                result: result,
                error: error,
                diff: diff,
                write:
                    out[idx].tool!.write ||
                    writeToolCallIds.contains(toolCallId),
              ),
            );
          } else {
            out.add(
              MessageRecord(
                id: toolCallId,
                seq: seq++,
                role: MsgRole.tool,
                ts: _tsOf(e),
                model: e.model,
                tool: ToolEventData(
                  toolCallId: toolCallId,
                  // A known name when the request told us (a failed
                  // `send_to_phone` arrives without a row of its own).
                  tool: toolName ?? 'unknown',
                  status: status,
                  result: result,
                  error: error,
                  diff: diff,
                  write: writeToolCallIds.contains(toolCallId),
                ),
              ),
            );
          }
        case CompactionEvt(:final summary, :final tokensBefore):
          out.add(
            MessageRecord(
              id: 'compaction_${e.ts}',
              seq: seq++,
              role: MsgRole.compaction,
              text: summary,
              tokensBefore: tokensBefore,
              ts: _tsOf(e),
              model: e.model,
            ),
          );
        // A file the Pi sent, replayed as metadata only (no bytes — the app
        // pulls them with `file_get` when the card is actually looked at).
        case AttachmentEvt(
          :final id,
          :final name,
          :final path,
          :final mime,
          :final size,
          :final note,
          :final resized,
          :final originalSize,
          :final toolCallId,
        ):
          out.add(
            MessageRecord(
              id: id,
              seq: seq++,
              role: MsgRole.attachment,
              ts: _tsOf(e),
              model: e.model,
              attachment: AttachmentData(
                name: name,
                path: path,
                mime: mime,
                size: size,
                note: note,
                resized: resized,
                originalSize: originalSize,
                toolCallId: toolCallId,
              ),
            ),
          );
      }
    }
    // A card or marker that arrives twice in one reply is still one row: the id
    // is its identity, and the Pi can hand us the same attachment event twice (a
    // re-remembered card, or a byte-only re-delivery).
    final seen = <String>{};
    out.removeWhere((r) {
      if (r.role != MsgRole.attachment && r.role != MsgRole.compaction) {
        return false;
      }
      return !seen.add(_key(r.role, r.id));
    });
    return out;
  }

  // ---------------------------------------------------------------------------
  // Box write helpers (all serialised through _enqueue)
  // ---------------------------------------------------------------------------

  String _key(MsgRole role, String id) => '${role.name}:$id';

  Future<void> _loadIndex() {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      _idToSeq.clear();
      _nextSeq = 0;
      // The resume token rides the session index, so a cold start resumes a
      // room instead of replaying it.
      final rawIdx = _boxes.sessionsIndexBox().get(
        LocalBoxes.sessionKey(epk, room),
      );
      final stored = rawIdx is Map
          ? SessionIndexRecord.fromJson(rawIdx.cast<String, dynamic>())
          : null;
      _syncedRows = stored?.syncedRows;
      _syncCursor = stored?.syncCursor;
      final reasoning = <String>[];
      // A frontier the box cannot back up (rows lost to a half-done wipe, a
      // pruned box) or none at all (a cache written before the frontier existed)
      // means the boundary between replayed and live rows is unknown: a delta
      // could not tell which rows it is re-delivering. Drop the cursor once and
      // let the Pi substitute the cache wholesale — the full replay is the one
      // path that cannot leave a duplicate behind.
      var dropped = '';
      if (_syncCursor != null &&
          (_syncedRows == null || _syncedRows! > box.length)) {
        dropped = _syncedRows == null
            ? ' → dropped (cache has no frontier)'
            : ' → dropped (frontier $_syncedRows > ${box.length} rows)';
        _syncCursor = null;
        _syncedRows = null;
      }
      debugPrint(
        '[sync] load room=$room rows=${box.length} '
        'syncedRows=${stored?.syncedRows} '
        'storedCursor=${stored?.syncCursor == null ? 'none' : 'yes'}$dropped',
      );
      for (final k in box.keys) {
        final seq = (k as num).toInt();
        final r = MessageRecord.fromJson(_coerce(box.get(k)));
        _idToSeq[_key(r.role, r.id)] = seq;
        _nextSeq = math.max(_nextSeq, seq + 1);
        if (r.role == MsgRole.thinking && r.text.isNotEmpty) {
          reasoning.add(r.text);
        }
        // Re-arm the no-echo backstop for any pending row this session owns, so
        // a bubble persisted across an app restart / quick session-switch is
        // reaped by its `ts` instead of spinning forever (already-stale → fires
        // immediately). Timers were cleared by the session switch before this
        // load.
        if (r.role == MsgRole.user && r.pending && r.ts != null) {
          _armSendTimeout(r.id, r.ts!);
        }
      }
      // LOCAL (fenlyin): a cache written before the reasoning pairing fix (see
      // [_holdsSameReasoning]) can hold ONE block twice — the Pi's capped copy
      // where it belongs and the live full copy the merge could not pair with
      // it, hung at the end of the transcript, so a finished conversation read
      // as if it ended on a thinking block. The rows cannot say which copy goes
      // where, but the reply can: dropping the resume token makes the next
      // `session_sync` a full replay, and that substitutes the rows in the order
      // the Pi wrote them. It clears itself — a repaired room holds one copy,
      // which is not the fingerprint.
      if (_holdsSplitReasoning(reasoning)) {
        debugPrint('[sync] load room=$room → cursor dropped (reasoning twice)');
        _syncCursor = null;
        _syncedRows = null;
      }
      _indexLoaded = true;
    });
  }

  /// Whether [texts] holds the same reasoning block twice — one copy capped for
  /// the re-sync mirror, one written live from the uncapped stream. A genuine
  /// transcript cannot match: the Pi caps each block once, so a second copy of
  /// the same head only ever came from this device's own live row.
  static bool _holdsSplitReasoning(List<String> texts) {
    for (var i = 0; i < texts.length; i++) {
      if (!texts[i].contains(_thinkingCapMarker)) continue;
      for (var j = 0; j < texts.length; j++) {
        if (i == j) continue;
        if (_holdsSameReasoning(texts[j], texts[i])) return true;
      }
    }
    return false;
  }

  Future<void> _upsert(
    MsgRole role,
    String id,
    MessageRecord Function(int seq, MessageRecord? existing) build,
  ) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      final active = _activeEpk == epk && _activeRoomId == room;
      if (!active) return;
      final box = await _boxes.msgsBox(epk, room);
      final mapKey = _key(role, id);
      final existingSeq = _idToSeq[mapKey];
      if (existingSeq != null) {
        final existing = MessageRecord.fromJson(_coerce(box.get(existingSeq)));
        await box.put(
          existingSeq,
          (await _archiveRecord(build(existingSeq, existing), box)).toJson(),
        );
      } else {
        final seq = _nextSeq++;
        await box.put(
          seq,
          (await _archiveRecord(build(seq, null), box)).toJson(),
        );
        _idToSeq[mapKey] = seq;
      }
    });
  }

  /// [record] with its pictures moved into the phone's archive. Identity when
  /// the row carries no inline bytes (the usual case).
  Future<MessageRecord> _archiveRecord(
    MessageRecord record,
    Box<dynamic> box,
  ) async {
    if (record.images.isEmpty) return record;
    final archived = await _archiveImages(record.images, msgsBox: box);
    return identical(archived, record.images)
        ? record
        : record.copyWith(images: archived);
  }

  Future<void> _removeById(String id) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      for (final role in MsgRole.values) {
        final seq = _idToSeq.remove(_key(role, id));
        if (seq != null) await box.delete(seq);
      }
    });
  }

  void _clearSteeringLabel(String id) {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    // ignore: discarded_futures
    _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      final seq = _idToSeq[_key(MsgRole.user, id)];
      if (seq == null) return;
      final raw = box.get(seq);
      if (raw == null) return;
      final existing = MessageRecord.fromJson(_coerce(raw));
      if (existing.role != MsgRole.user || !existing.steering) return;
      await box.put(seq, existing.copyWith(steering: false).toJson());
    });
  }

  void _clearSteeringLabels() {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    // ignore: discarded_futures
    _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      for (final key in box.keys.toList()) {
        final raw = box.get(key);
        if (raw == null) continue;
        final existing = MessageRecord.fromJson(_coerce(raw));
        if (existing.role != MsgRole.user || !existing.steering) continue;
        await box.put(
          (key as num).toInt(),
          existing.copyWith(steering: false).toJson(),
        );
      }
    });
  }

  Future<void> _removePendingById(String id) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final box = await _boxes.msgsBox(epk, room);
      for (final role in MsgRole.values) {
        final key = _key(role, id);
        final seq = _idToSeq[key];
        if (seq == null) continue;
        final raw = box.get(seq);
        if (raw == null) {
          _idToSeq.remove(key);
          continue;
        }
        final existing = MessageRecord.fromJson(_coerce(raw));
        if (!existing.pending) continue;
        _idToSeq.remove(key);
        await box.delete(seq);
      }
    });
  }

  void _setActivity(String epk, String room, SessionActivity status, {String? preview}) {
    _updateIndex(
      epk,
      room,
      (cur) => cur.copyWith(
        status: status,
        lastMessageAt: preview != null ? DateTime.now() : null,
        lastMessagePreview: preview,
      ),
    );
  }

  void _setQueuedMessages(_RoomTurn t, List<QueuedMsg> items) {
    final next = List<QueuedMsg>.unmodifiable(items);
    if (t.queuedMessages == next) return;
    t.queuedMessages = next;
    if (_isActive(t) && !_queuedController.isClosed) _queuedController.add(next);
  }

  /// Plan/63 — one room's todo list. `TodoState` compares by value, so a
  /// replayed frame identical to the cached one emits nothing.
  void _setTodos(_RoomTurn t, TodoState state) {
    if (t.todos == state) return;
    t.todos = state;
    if (_isActive(t) && !_todoController.isClosed) _todoController.add(state);
  }

  /// Single source of "a room is working". Drives that room's in-memory
  /// flag/stream (the chat pill, active room only), its durable session index
  /// (Home dot) and — for the connected room — the app-side room-meta
  /// correction the relay-based Home dot falls back on.
  void _syncTurnStateFromRoomMeta() {
    final epk = _activeEpk;
    if (epk == null) return;
    final t = _turns[LocalBoxes.sessionKey(epk, _activeRoomId)];
    final remoteWorking = _conn.isRoomWorking(epk, _activeRoomId);
    if (remoteWorking) {
      if (t != null) t.sawRemoteWorking = true;
      return;
    }
    if (t != null && t.sawRemoteWorking && t.working) {
      // The relay says this room stopped working, but `agent_done` has not been
      // processed (yet): the two signals ride DIFFERENT channels — the meta is
      // a control broadcast, `agent_done` a chat envelope — and the meta's
      // debounce makes it routinely win by a frame or two. Closing the turn
      // here must not throw away text the Pi already streamed: finalize the
      // open segments exactly like `agent_done` does, so the reply lands in the
      // box. An `agent_done` arriving afterwards finds nothing open and no-ops.
      _finalizeThinkingSegment(t);
      final text = _finalizeTextSegment(t);
      _clearSteeringLabels();
      _setWorking(t, false, preview: text.isEmpty ? null : text);
    }
    if (t != null) t.sawRemoteWorking = false;
  }

  void _setWorking(
    _RoomTurn t,
    bool on, {
    String? preview,
    String? replyTo,
  }) {
    _setActivity(
      t.epk,
      t.room,
      on ? SessionActivity.working : SessionActivity.idle,
      preview: preview,
    );
    // App-side correction is only valid for the CONNECTED room — non-active
    // rooms' Home dots stay the relay's domain (their relay meta broadcast is
    // the source of truth).
    if (_isActive(t)) {
      _conn.markRoomWorking(t.epk, t.room, on);
    }
    if (on) {
      if (replyTo != null) t.workingReplyTo = replyTo;
    } else {
      t.workingReplyTo = null;
      t.sawRemoteWorking = false;
    }
    if (t.working == on) return;
    t.working = on;
    if (_isActive(t) && !_workingController.isClosed) _workingController.add(on);
  }

  void _updateIndex(
    String epk,
    String room,
    SessionIndexRecord Function(SessionIndexRecord cur) build,
  ) {
    // ignore: discarded_futures
    _enqueue(() async {
      final idx = _boxes.sessionsIndexBox();
      final key = LocalBoxes.sessionKey(epk, room);
      final raw = idx.get(key);
      final cur = raw is Map
          ? SessionIndexRecord.fromJson(raw.cast<String, dynamic>())
          : SessionIndexRecord(epk: epk, roomId: room);
      await idx.put(key, build(cur).toJson());
    });
  }

  void _writeRuntime() {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    final s = _conn.status;
    final conn = switch (s) {
      StatusOnline() => RuntimeConnection.online,
      StatusConnecting() => RuntimeConnection.connecting,
      StatusRetrying() => RuntimeConnection.retrying,
      StatusOffline() => RuntimeConnection.offline,
      StatusNoPeer() => RuntimeConnection.connecting,
    };
    final presence = (s is StatusOnline && _conn.isRoomLive(epk, room))
        ? RuntimePresence.alive
        : (s is StatusOnline ? RuntimePresence.stale : RuntimePresence.unknown);
    // ignore: discarded_futures
    _enqueue(() async {
      _boxes.runtimeBox().put(
        LocalBoxes.sessionKey(epk, room),
        RuntimeRecord(connection: conn, presence: presence).toJson(),
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Per-room turn state (streaming in-memory only — #7)
  // ---------------------------------------------------------------------------

  void _applyChunk(_RoomTurn t, String inReplyTo, String delta) {
    // Answer text follows the reasoning block → the reasoning segment is
    // over; persist it as its own row before the text starts.
    _finalizeThinkingSegment(t);
    t.chunkBuffer.write(delta);
    t.chunkReplyTo = inReplyTo;
    t.flushTimer?.cancel();
    t.flushTimer = Timer(const Duration(milliseconds: 16), () => _flushStreaming(t));
    _setWorking(t, true, replyTo: inReplyTo);
  }

  void _applyThinking(_RoomTurn t, String inReplyTo, String delta) {
    // Mirror image: a reasoning block after text closes the text segment.
    _finalizeTextSegment(t);
    // First delta of this reasoning segment: stamp the start. Survives room
    // switches (per-room slot) so the thinking counter never resets to zero.
    t.thinkingStartedAt ??= DateTime.now();
    t.thinkingBuffer.write(delta);
    t.thinkingReplyTo = inReplyTo;
    t.flushTimer?.cancel();
    t.flushTimer = Timer(const Duration(milliseconds: 16), () => _flushStreaming(t));
    _setWorking(t, true, replyTo: inReplyTo);
  }

  void _applyAgentDone(_RoomTurn t, String inReplyTo) {
    // Finalize whatever accumulated since the last tool boundary
    // (reasoning first — it precedes text within a message).
    _finalizeThinkingSegment(t);
    final text = _finalizeTextSegment(t);
    if (_isActive(t)) _clearSteeringLabel(inReplyTo);
    _setWorking(t, false, preview: text.isEmpty ? null : text);
  }

  void _applyCancelled(_RoomTurn t, String targetId) {
    _discardStreamingState(t);
    if (_isActive(t)) {
      // Cancel is stop-generation, not delete-history. Only drop a local
      // optimistic row that never got confirmed by the Pi echo; preserve
      // confirmed user/tool rows as the audit trail of what happened.
      // ignore: discarded_futures
      _removePendingById(targetId);
      _clearSteeringLabels();
    }
    _setWorking(t, false);
  }

  /// Drain any coalesced delta sitting in the 16ms buffer into the live slot.
  /// Exactly one of the two buffers is normally non-empty.
  void _flushStreaming(_RoomTurn t) {
    if (t.thinkingBuffer.isNotEmpty) {
      final delta = t.thinkingBuffer.toString();
      t.thinkingBuffer.clear();
      final cur = t.streaming;
      _emitStreaming(
        t,
        (cur != null && cur.thinking && cur.inReplyTo == t.thinkingReplyTo)
            ? cur.appendDelta(delta)
            : StreamingMessage(
                inReplyTo: t.thinkingReplyTo,
                buffer: delta,
                thinking: true,
                startedAt: t.thinkingStartedAt,
              ),
      );
    }
    if (t.chunkBuffer.isEmpty) return;
    final delta = t.chunkBuffer.toString();
    t.chunkBuffer.clear();
    final cur = t.streaming;
    if (cur != null && !cur.thinking && cur.inReplyTo == t.chunkReplyTo) {
      _emitStreaming(t, cur.appendDelta(delta));
    } else {
      _emitStreaming(t, StreamingMessage(inReplyTo: t.chunkReplyTo, buffer: delta));
    }
  }

  /// Persist the accumulated streaming text as a standalone assistant row
  /// (unique id, in chronological seq order) and clear the live cursor.
  /// Called at every tool boundary AND on agent_done so text/tool/text
  /// renders sequentially. No-op when no text segment is open — so a
  /// tool-only, reasoning-only or empty turn never leaves a blank bubble.
  /// Background (non-active) rooms only clear their in-memory segment; their
  /// finalized rows come back via the history re-sync on re-entry.
  /// Returns the finalized text (empty if none).
  String _finalizeTextSegment(_RoomTurn t) {
    final live =
        t.chunkBuffer.isNotEmpty ||
        (t.streaming != null && !t.streaming!.thinking);
    if (!live) return '';
    // Drain any coalesced delta still sitting in the 16ms buffer.
    t.flushTimer?.cancel();
    t.flushTimer = null;
    if (t.chunkBuffer.isNotEmpty) {
      final delta = t.chunkBuffer.toString();
      t.chunkBuffer.clear();
      final cur = t.streaming;
      t.streaming = (cur != null && !cur.thinking && cur.inReplyTo == t.chunkReplyTo)
          ? cur.appendDelta(delta)
          : StreamingMessage(inReplyTo: t.chunkReplyTo, buffer: delta);
    }
    final text = t.streaming?.buffer ?? '';
    if (text.isNotEmpty && _isActive(t)) {
      final id = 'agent_${uuid7()}';
      // ignore: discarded_futures
      _upsert(
        MsgRole.assistant,
        id,
        (seq, _) => MessageRecord(
          id: id,
          seq: seq,
          role: MsgRole.assistant,
          text: text,
          ts: DateTime.now(),
          model: _activeRoomModel,
        ),
      );
    }
    t.chunkReplyTo = '';
    _emitStreaming(t, null);
    return text;
  }

  /// Persist the accumulated reasoning as its own [MsgRole.thinking] row.
  /// Same lifecycle as [_finalizeTextSegment]: closed by text/tool/turn
  /// boundaries, no-op when no reasoning block is open. Returns the finalized
  /// reasoning text (empty if none).
  String _finalizeThinkingSegment(_RoomTurn t) {
    final live =
        t.thinkingBuffer.isNotEmpty || (t.streaming?.thinking ?? false);
    if (!live) return '';
    t.flushTimer?.cancel();
    t.flushTimer = null;
    if (t.thinkingBuffer.isNotEmpty) {
      final delta = t.thinkingBuffer.toString();
      t.thinkingBuffer.clear();
      final cur = t.streaming;
      t.streaming = (cur != null && cur.thinking && cur.inReplyTo == t.thinkingReplyTo)
          ? cur.appendDelta(delta)
          : StreamingMessage(
              inReplyTo: t.thinkingReplyTo,
              buffer: delta,
              thinking: true,
              startedAt: t.thinkingStartedAt,
            );
    }
    final text = t.streaming?.buffer ?? '';
    // The block is over: freeze how long it took. Measured here (not in the UI)
    // so the persisted row and the live counter are the same number.
    final startedAt = t.thinkingStartedAt;
    final elapsed =
        startedAt == null ? null : DateTime.now().difference(startedAt);
    if (text.isNotEmpty && _isActive(t)) {
      final id = 'thinking_${uuid7()}';
      // ignore: discarded_futures
      _upsert(
        MsgRole.thinking,
        id,
        (seq, _) => MessageRecord(
          id: id,
          seq: seq,
          role: MsgRole.thinking,
          text: text,
          ts: DateTime.now(),
          model: _activeRoomModel,
          thinkingMs: elapsed?.inMilliseconds,
        ),
      );
    }
    t.thinkingReplyTo = '';
    t.thinkingStartedAt = null;
    _emitStreaming(t, null);
    return text;
  }

  void _discardStreamingState(_RoomTurn t) {
    t.flushTimer?.cancel();
    t.flushTimer = null;
    t.chunkBuffer.clear();
    t.chunkReplyTo = '';
    t.thinkingBuffer.clear();
    t.thinkingReplyTo = '';
    t.thinkingStartedAt = null;
    _emitStreaming(t, null);
  }

  /// Set the room's live slot. UI streams only observe the ACTIVE room's slot
  /// — a background room's slot updates silently until the user returns to
  /// it (the chat VM re-seeds from [streaming] on its activate).
  void _emitStreaming(_RoomTurn t, StreamingMessage? s) {
    t.streaming = s;
    if (_isActive(t) && !_streamingController.isClosed) {
      _streamingController.add(s);
    }
  }

  // ---------------------------------------------------------------------------

  Future<void> _enqueue(Future<void> Function() op) {
    final next = _writeChain.then((_) => op());
    _writeChain = next.catchError((Object _, StackTrace _) {});
    return next;
  }

  static Map<String, dynamic> _coerce(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return raw.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  /// Echo/history wire shape → the persisted+rendered shape (the content stays
  /// on the Pi; only the names and the landed paths come back).
  static List<MessageFile> _messageFiles(List<WireFile> files) => files
      .map((f) => MessageFile(name: f.name, path: f.path))
      .toList();

  static List<MessageImage> _messageImages(List<WireImage> images) => images
      .map((i) => MessageImage(data: i.data, mime: i.mime))
      .toList();

  /// A user message's text as it should read on the phone.
  ///
  /// pi appends its own model-facing notes to the text of any message that
  /// carried pictures — the resize hint (`[Image: original 1080x2400, displayed
  /// at 900x2000. Multiply coordinates by 1.20 to map to original image.]`), a
  /// format conversion, an omission. Those notes address the model, not the
  /// user, and only a `session_history` replay carries them (a phone-sent
  /// message echoes back the text that was typed); replayed verbatim they turn
  /// into a bubble above the picture.
  static String _userText(String text) {
    if (!text.contains('[Image')) return text;
    final lines = text.split('\n');
    final kept = [
      for (final line in lines)
        if (!_imageNote.hasMatch(line.trim())) line,
    ];
    if (kept.length == lines.length) return text;
    // The note is its own paragraph: pi separates it with a blank line, which
    // would otherwise leave the caption card with a trailing gap.
    while (kept.isNotEmpty && kept.last.trim().isEmpty) {
      kept.removeLast();
    }
    while (kept.isNotEmpty && kept.first.trim().isEmpty) {
      kept.removeAt(0);
    }
    return kept.join('\n');
  }

  /// One line of pi's image notes
  /// (`packages/coding-agent/src/utils/image-process.ts`).
  static final RegExp _imageNote = RegExp(
    r'^\[Image(: original \d+x\d+, displayed at \d+x\d+\. Multiply '
    r'coordinates by \d+(?:\.\d+)? to map to original image\.'
    r'| converted from [^\]]+'
    r'| omitted: [^\]]*)\]$',
  );

  static String _preview(String text, List<MessageImage> images, List<MessageFile> files) {
    if (text.isEmpty && images.isNotEmpty) return '📷 Image';
    if (text.isEmpty && files.isNotEmpty) return '📄 ${files.first.name}';
    return text.length <= 80 ? text : '${text.substring(0, 80)}…';
  }

  static String _newId() => 'cli_${uuid7()}';

  @override
  void dispose() {
    for (final t in _turns.values) {
      t.flushTimer?.cancel();
    }
    _syncDebounce?.cancel();
    _cancelAllSendTimers();
    _connSub?.cancel();
    _msgSub?.cancel();
    _roomMsgSub?.cancel();
    _roomsSub?.cancel();
    _presenceSub?.cancel();
    _streamingController.close();
    _eventController.close();
    _extensionUiController.close();
    _workingController.close();
    _queuedController.close();
    _todoController.close();
    _fileReceiveController.close();
    for (final id in _incomingCards.keys.toList()) {
      // ignore: discarded_futures
      _incomingFiles?.abort(id);
    }
    _incomingCards.clear();
    _fileReceive.clear();
  }
}

/// Metadata of one incoming chunked transfer, kept while it runs so a failure
/// can rewrite the card it created with the reason it stopped.
class _IncomingCard {
  const _IncomingCard({
    required this.name,
    required this.path,
    required this.mime,
    required this.size,
    this.note,
  });

  final String name;
  final String path;
  final String mime;
  final int size;
  final String? note;
}
