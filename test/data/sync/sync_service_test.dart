// Plan/31 — SyncService is the single DB writer. Drives it through a fake
// channel adopted into a real ConnectionManager and asserts box contents.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _FakeChannel implements IChannel, IControlLink {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final _control = StreamController<ControlInbound>.broadcast();
  final List<ClientMessage> sent = [];
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Stream<ControlInbound> get controlFrames => _control.stream;
  @override
  Future<void> send(ClientMessage msg) async => sent.add(msg);
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> close() async {
    await _ctrl.close();
    await _control.close();
  }

  void push(ServerMessage m) => _ctrl.add(m);
  void pushControl(ControlInbound m) => _control.add(m);
}

/// [_FakeChannel] plus the room-tagged side channel (`IRoomFrameLink`) the
/// real WsTransport carries: EVERY inbound envelope with its sender room,
/// including rooms the app is not addressing. Lets a test simulate a
/// background room keeping a turn in flight while the user views another.
class _FakeRoomChannel extends _FakeChannel implements IRoomFrameLink {
  final _frames = StreamController<RoomFrame>.broadcast();

  @override
  Stream<RoomFrame> get roomFrames => _frames.stream;

  @override
  Future<void> close() async {
    await super.close();
    await _frames.close();
  }

  void pushRoomFrame(String roomId, Map<String, dynamic> json) => _frames.add(
    RoomFrame(
      roomId: roomId,
      payload: Uint8List.fromList(utf8.encode(jsonEncode(json))),
    ),
  );
}

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

// A real 200×200 PNG (1-bit), so `probeImageSize` can read its header.
const _squarePng =
    'iVBORw0KGgoAAAANSUhEUgAAAMgAAADIAQAAAACFI5MzAAAAKElEQVR42u3JoQEAAAgDoOn/'
    'P2u1+AFUavLoGGOMMcYYY4wxxhhjzLUvnQKPTWDWfAAAAABJRU5ErkJggg==';

int _counter = 0;

late Directory _dir;

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  setUpAll(() async {
    _dir = Directory.systemTemp.createTempSync('rp_v2_sync_');
    await LocalBoxes.initForTest(_dir.path);
  });
  tearDownAll(() async {
    await Hive.close();
    await _dir.delete(recursive: true);
  });

  Future<
    ({ConnectionManager conn, _FakeChannel ch, SyncService sync, String epk})
  >
  setup({Duration pendingSendTimeout = const Duration(seconds: 20)}) async {
    final ch = _FakeChannel();
    final conn = ConnectionManager(
      factory: (_, _) async => ch,
      storage: _FakeStorage(),
      emitDebounce: Duration.zero,
    );
    final boxes = LocalBoxes();
    final sync = SyncService(
      conn,
      boxes,
      pendingSendTimeout: pendingSendTimeout,
    );
    final epk = 'epk_sync_${++_counter}';
    conn.adopt(
      ch,
      PeerRecord(
        remoteEpk: epk,
        sessionName: 'Pi',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-01T00:00:00Z',
      ),
    );
    await _settle(); // _onlineActivated → activate(epk) settles
    return (conn: conn, ch: ch, sync: sync, epk: epk);
  }

  /// Like [setup], but with the room-tagged side channel so background-room
  /// frames can be pushed via `ch.pushRoomFrame`.
  Future<
    ({ConnectionManager conn, _FakeRoomChannel ch, SyncService sync, String epk})
  >
  setupWithRooms() async {
    final ch = _FakeRoomChannel();
    final conn = ConnectionManager(
      factory: (_, _) async => ch,
      storage: _FakeStorage(),
      emitDebounce: Duration.zero,
    );
    final boxes = LocalBoxes();
    final sync = SyncService(conn, boxes);
    final epk = 'epk_sync_${++_counter}';
    conn.adopt(
      ch,
      PeerRecord(
        remoteEpk: epk,
        sessionName: 'Pi',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-01T00:00:00Z',
      ),
    );
    await _settle();
    return (conn: conn, ch: ch, sync: sync, epk: epk);
  }

  List<MessageRecord> messages(String epk, [String room = 'main']) {
    final box = LocalBoxes().openMsgsBox(epk, room);
    final out = [
      for (final v in box.values)
        MessageRecord.fromJson((v as Map).cast<String, dynamic>()),
    ];
    out.sort((a, b) => a.seq.compareTo(b.seq));
    return out;
  }

  SessionIndexRecord? index(String epk) {
    final raw = LocalBoxes().sessionsIndexBox().get('$epk:main');
    return raw is Map
        ? SessionIndexRecord.fromJson(raw.cast<String, dynamic>())
        : null;
  }

  test(
    'todo_state fills the active room\'s list and survives the stream',
    () async {
      final s = await setup();
      final seen = <TodoState>[];
      final sub = s.sync.todosStream.listen(seen.add);

      s.ch.push(
        TodoState(
          tasks: const [
            TodoTask(id: 1, subject: 'Adapt the app', status: TodoTaskStatus.inProgress),
            TodoTask(id: 2, subject: 'Run the tests', status: TodoTaskStatus.pending),
          ],
        ),
      );
      await _settle();

      expect(s.sync.todos.total, 2);
      expect(s.sync.todos.doneCount, 0);
      expect(seen.map((t) => t.total), [2]);

      // The plugin's empty list is the "no more todos" signal, not an error.
      s.ch.push(TodoState());
      await _settle();
      expect(s.sync.todos.isEmpty, isTrue);
      expect(seen.map((t) => t.total), [2, 0]);

      await sub.cancel();
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'a background room keeps its own todo list, and the switch re-aims it',
    () async {
      final s = await setupWithRooms();
      // The room being viewed has a list...
      s.ch.pushRoomFrame(
        'main',
        {
          'type': 'todo_state',
          'tasks': [{'id': 1, 'subject': 'Main room row', 'status': 'pending'}],
        },
      );
      await _settle();
      expect(s.sync.todos.tasks.single.subject, 'Main room row');

      // ...while a room the user is NOT viewing publishes its own.
      s.ch.pushRoomFrame(
        'room2',
        {
          'type': 'todo_state',
          'tasks': [
            {'id': 1, 'subject': 'Room2 row A', 'status': 'pending'},
            {'id': 2, 'subject': 'Room2 row B', 'status': 'completed'},
          ],
        },
      );
      await _settle();
      expect(
        s.sync.todos.tasks.single.subject,
        'Main room row',
        reason: 'a background frame must not rewrite the visible list',
      );

      // Switching re-aims the ball at the new room's list, and back again.
      await s.sync.activate(s.epk, 'room2');
      await _settle();
      expect(s.sync.todos.total, 2);
      expect(s.sync.todos.doneCount, 1);

      await s.sync.activate(s.epk, 'main');
      await _settle();
      expect(s.sync.todos.tasks.single.subject, 'Main room row');

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'user_message echo writes one MessageRecord + updates the index',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'hi'));
      await _settle();

      final m = messages(s.epk);
      expect(m, hasLength(1));
      expect(m.first.role, MsgRole.user);
      expect(m.first.text, 'hi');
      expect(m.first.pending, isFalse);
      expect(index(s.epk)?.status, SessionActivity.working);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('a text file rides the wire as {name,text}, and the pending row shows the name', () async {
    final s = await setup();
    await s.sync.sendMessage(
      'summarise',
      files: [OutgoingFile(name: 'notes.md', text: '# hi')],
    );
    await _settle();

    final frame = s.ch.sent.whereType<UserMessage>().single;
    expect(frame.images, isNull);
    expect(frame.files, hasLength(1));
    expect(frame.files!.single.name, 'notes.md');
    expect(frame.files!.single.text, '# hi');
    expect(frame.files!.single.path, isNull, reason: 'the Pi decides the path');

    final row = messages(s.epk).single;
    expect(row.files.single.name, 'notes.md');
    expect(row.files.single.path, isNull);
    expect(row.pending, isTrue);
    s.conn.dispose();
    s.sync.dispose();
  });

  test('the echo of an upload lands the Pi path on the same row (no duplicate)', () async {
    final s = await setup();
    await s.sync.sendMessage(
      'summarise',
      files: [OutgoingFile(name: 'notes.md', text: '# hi')],
    );
    await _settle();

    final id = s.ch.sent.whereType<UserMessage>().last.id;
    s.ch.push(
      UserInput(
        id: id,
        text: 'summarise',
        files: const [
          WireFile(
            name: 'notes.md',
            path: '/home/p/.pi/remote/uploads/main/notes.md',
          ),
        ],
      ),
    );
    await _settle();

    final m = messages(s.epk);
    expect(m, hasLength(1), reason: 'echo dedupes by id');
    expect(m.single.pending, isFalse);
    expect(
      m.single.files.single.path,
      '/home/p/.pi/remote/uploads/main/notes.md',
      reason: 'the bubble can show where the file went',
    );
    s.conn.dispose();
    s.sync.dispose();
  });

  test('session_history replays an upload as a name+path row', () async {
    final s = await setup();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: const [
          UserInputEvt(
            ts: 10,
            id: 'u1',
            text: 'summarise',
            files: [
              WireFile(
                name: 'report.csv',
                path: '/home/p/.pi/remote/uploads/main/report.csv',
              ),
            ],
          ),
          AgentMessageEvt(ts: 11, inReplyTo: 'u1', text: 'done'),
        ],
        eos: true,
      ),
    );
    await _settle();

    final user = messages(s.epk).firstWhere((m) => m.role == MsgRole.user);
    expect(user.text, 'summarise');
    expect(user.files.single.name, 'report.csv');
    expect(user.files.single.path, '/home/p/.pi/remote/uploads/main/report.csv');
    s.conn.dispose();
    s.sync.dispose();
  });

  test('optimistic send + echo dedupe → exactly one record', () async {
    final s = await setup();
    await s.sync.sendMessage('hello');
    await _settle();
    expect(messages(s.epk), hasLength(1));
    expect(messages(s.epk).first.pending, isTrue);

    final id = (s.ch.sent.whereType<UserMessage>().last).id;
    s.ch.push(UserInput(id: id, text: 'hello'));
    await _settle();

    final m = messages(s.epk);
    expect(m, hasLength(1), reason: 'echo dedupes by id — no duplicate');
    expect(m.first.pending, isFalse);
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'steer send keeps active working target and sets streaming behavior on wire',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'primary'));
      await _settle();

      await s.sync.sendMessage(
        'refine this',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      );
      await _settle();

      final sent = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'refine this',
      );
      expect(sent.streamingBehavior, UserMessageStreamingBehavior.steer);
      final steerRow = messages(s.epk).singleWhere((r) => r.id == sent.id);
      expect(steerRow.pending, isTrue);
      expect(steerRow.steering, isTrue);
      expect((steerRow.toChatMessage() as UserMsg).steering, isTrue);
      expect(s.sync.workingReplyTo, 'u1');
      expect(s.sync.streaming, isNotNull);
      expect(s.sync.streaming!.inReplyTo, 'u1');
      expect(s.sync.isWorking, isTrue);

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('steer echo confirms row without replacing working turn', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'u1', text: 'primary'));
    await _settle();
    expect(s.sync.workingReplyTo, 'u1');

    await s.sync.sendMessage(
      'refine this',
      streamingBehavior: UserMessageStreamingBehavior.steer,
    );
    await _settle();
    final sent = s.ch.sent.whereType<UserMessage>().lastWhere(
      (m) => m.text == 'refine this',
    );

    s.ch.push(
      UserInput(
        id: sent.id,
        text: 'refine this',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      ),
    );
    await _settle();

    expect(s.sync.workingReplyTo, 'u1');
    expect(s.sync.streaming, isNotNull);
    expect(s.sync.streaming!.inReplyTo, 'u1');
    expect(s.sync.isWorking, isTrue);
    final rows = messages(s.epk);
    expect(rows, hasLength(2));
    var steerRow = rows.where((r) => r.id == sent.id).single;
    expect(steerRow.pending, isFalse);
    expect(steerRow.steering, isTrue, reason: 'echo only means accepted');
    expect((steerRow.toChatMessage() as UserMsg).steering, isTrue);
    expect(index(s.epk)?.status, SessionActivity.working);
    expect(index(s.epk)?.lastMessagePreview, 'refine this');

    s.ch.push(SteerConsumed(id: sent.id));
    await _settle();

    steerRow = messages(s.epk).where((r) => r.id == sent.id).single;
    expect(steerRow.pending, isFalse);
    expect(
      steerRow.steering,
      isFalse,
      reason: 'actual queue delivery clears label',
    );
    expect((steerRow.toChatMessage() as UserMsg).steering, isFalse);

    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'steer_consumed clears one steering label, not every queued steer',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'primary'));
      await _settle();

      await s.sync.sendMessage(
        'first steer',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      );
      await s.sync.sendMessage(
        'second steer',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      );
      await _settle();
      final first = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'first steer',
      );
      final second = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'second steer',
      );
      for (final sent in [first, second]) {
        s.ch.push(
          UserInput(
            id: sent.id,
            text: sent.text,
            streamingBehavior: UserMessageStreamingBehavior.steer,
          ),
        );
      }
      await _settle();
      expect(
        messages(s.epk).where((r) => r.id == first.id).single.steering,
        isTrue,
      );
      expect(
        messages(s.epk).where((r) => r.id == second.id).single.steering,
        isTrue,
      );

      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'working'));
      await _settle();
      expect(
        messages(s.epk).where((r) => r.id == first.id).single.steering,
        isTrue,
      );
      expect(
        messages(s.epk).where((r) => r.id == second.id).single.steering,
        isTrue,
      );

      s.ch.push(SteerConsumed(id: first.id));
      await _settle();

      expect(
        messages(s.epk).where((r) => r.id == first.id).single.steering,
        isFalse,
      );
      expect(
        messages(s.epk).where((r) => r.id == second.id).single.steering,
        isTrue,
      );
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('agent_done clears only its steering label as a fallback', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'u1', text: 'primary'));
    await _settle();

    await s.sync.sendMessage(
      'first steer',
      streamingBehavior: UserMessageStreamingBehavior.steer,
    );
    await s.sync.sendMessage(
      'second steer',
      streamingBehavior: UserMessageStreamingBehavior.steer,
    );
    await _settle();
    final first = s.ch.sent.whereType<UserMessage>().lastWhere(
      (m) => m.text == 'first steer',
    );
    final second = s.ch.sent.whereType<UserMessage>().lastWhere(
      (m) => m.text == 'second steer',
    );
    for (final sent in [first, second]) {
      s.ch.push(
        UserInput(
          id: sent.id,
          text: sent.text,
          streamingBehavior: UserMessageStreamingBehavior.steer,
        ),
      );
    }
    await _settle();
    expect(
      messages(s.epk).where((r) => r.id == first.id).single.steering,
      isTrue,
    );
    expect(
      messages(s.epk).where((r) => r.id == second.id).single.steering,
      isTrue,
    );

    s.ch.push(AgentDone(inReplyTo: first.id));
    await _settle();

    expect(
      messages(s.epk).where((r) => r.id == first.id).single.steering,
      isFalse,
    );
    expect(
      messages(s.epk).where((r) => r.id == second.id).single.steering,
      isTrue,
    );
    s.conn.dispose();
    s.sync.dispose();
  });

  test('streaming delta does NOT write to the DB (#7)', () async {
    final s = await setup();
    final before = messages(s.epk).length;
    s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'partial...'));
    await _settle();
    expect(messages(s.epk).length, before, reason: 'no row for a delta');
    expect(s.sync.streaming, isNotNull);
    expect(s.sync.streaming!.buffer, 'partial...');
    s.conn.dispose();
    s.sync.dispose();
  });

  test('agent_done finalizes the streamed message + flips to idle', () async {
    final s = await setup();
    s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'done text'));
    await _settle();
    s.ch.push(AgentDone(inReplyTo: 'r1'));
    await _settle();

    final assistant = messages(
      s.epk,
    ).where((m) => m.role == MsgRole.assistant).toList();
    expect(assistant, hasLength(1));
    expect(assistant.first.text, 'done text');
    expect(s.sync.streaming, isNull);
    expect(index(s.epk)?.status, SessionActivity.idle);
    s.conn.dispose();
    s.sync.dispose();
  });

  // ---------------------------------------------------------------------
  // Model reasoning (`agent_thinking`) — same live slot as text, own row.
  // ---------------------------------------------------------------------

  test(
    'reasoning streams in its own slot and is not written live (#7)',
    () async {
      final s = await setup();
      s.ch.push(AgentThinking(inReplyTo: 'r1', delta: 'weighing options'));
      await _settle();

      expect(messages(s.epk), isEmpty, reason: 'a delta is not a row');
      expect(s.sync.streaming, isNotNull);
      expect(s.sync.streaming!.thinking, isTrue);
      expect(s.sync.streaming!.buffer, 'weighing options');
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('reasoning closes into its own row before the answer text', () async {
    final s = await setup();
    s.ch.push(AgentThinking(inReplyTo: 'r1', delta: 'weighing options'));
    await _settle();
    s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'the answer'));
    await _settle();

    // The reasoning row lands the moment the answer starts streaming — the
    // live slot switches kind and nothing is lost.
    var rows = messages(s.epk);
    expect(rows.map((m) => m.role), [MsgRole.thinking]);
    expect(rows.single.text, 'weighing options');
    expect(rows.single.toChatMessage(), isA<ThinkingMsg>());
    expect(
      rows.single.thinkingMs,
      isNotNull,
      reason: 'the block was timed while it streamed',
    );
    expect(s.sync.streaming!.thinking, isFalse, reason: 'slot is text now');

    s.ch.push(AgentDone(inReplyTo: 'r1'));
    await _settle();
    rows = messages(s.epk);
    expect(rows.map((m) => m.role), [MsgRole.thinking, MsgRole.assistant]);
    expect(rows.map((m) => m.text), ['weighing options', 'the answer']);
    expect(s.sync.streaming, isNull);
    s.conn.dispose();
    s.sync.dispose();
  });

  test('text → reasoning → text keeps chronological order', () async {
    final s = await setup();
    s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'first'));
    await _settle();
    s.ch.push(AgentThinking(inReplyTo: 'r1', delta: 'because'));
    await _settle();
    s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'second'));
    await _settle();
    s.ch.push(AgentDone(inReplyTo: 'r1'));
    await _settle();

    final rows = messages(s.epk);
    expect(rows.map((m) => m.role), [
      MsgRole.assistant,
      MsgRole.thinking,
      MsgRole.assistant,
    ]);
    expect(rows.map((m) => m.text), ['first', 'because', 'second']);
    s.conn.dispose();
    s.sync.dispose();
  });

  test('a reasoning-only turn persists just the reasoning row', () async {
    final s = await setup();
    s.ch.push(AgentThinking(inReplyTo: 'r1', delta: 'just thinking'));
    await _settle();
    s.ch.push(AgentDone(inReplyTo: 'r1'));
    await _settle();

    final rows = messages(s.epk);
    expect(rows, hasLength(1));
    expect(rows.single.role, MsgRole.thinking);
    expect(rows.single.text, 'just thinking');
    expect(index(s.epk)?.status, SessionActivity.idle);
    s.conn.dispose();
    s.sync.dispose();
  });

  test('a tool boundary closes reasoning before the tool row', () async {
    final s = await setup();
    s.ch.push(AgentThinking(inReplyTo: 'r1', delta: 'need to list files'));
    await _settle();
    s.ch.push(
      ToolRequest(toolCallId: 'c1', tool: 'bash', args: {'command': 'ls'}),
    );
    await _settle();

    expect(messages(s.epk).map((m) => m.role), [
      MsgRole.thinking,
      MsgRole.tool,
    ]);
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'switching rooms keeps a half-streamed thought in ITS room — no '
    'cross-room bleed, and it survives the switch',
    () async {
      final s = await setup();
      // Session 1 is mid-reasoning when the user switches rooms.
      s.ch.push(AgentThinking(inReplyTo: 'r1', delta: 'half a thought'));
      await _settle();
      expect(s.sync.streaming, isNotNull);

      // Another ROOM of the same peer (frames stay attributable, so this is
      // the switch path that would actually leak).
      await s.sync.activate(s.epk, 'room2');
      await _settle();
      expect(s.sync.streaming, isNull, reason: 'room2 has no live turn');

      // Room2 starts reasoning: room1's stale buffer must not be finalized
      // into it.
      s.ch.push(AgentThinking(inReplyTo: 'r2', delta: 'fresh thought'));
      await _settle();
      s.ch.push(AgentDone(inReplyTo: 'r2'));
      await _settle();
      final written = [
        for (final v in LocalBoxes().openMsgsBox(s.epk, 'room2').values)
          MessageRecord.fromJson((v as Map).cast<String, dynamic>()),
      ];
      expect(written.map((m) => m.text), ['fresh thought']);

      // Back in room1: its half-streamed thought is STILL LIVE — same
      // content, same reasoning clock — instead of being discarded.
      await s.sync.activate(s.epk, 'main');
      await _settle();
      final live = s.sync.streaming;
      expect(live, isNotNull, reason: 'room1 turn survived the switch');
      expect(live!.buffer, 'half a thought');
      expect(live.thinking, isTrue);
      expect(live.startedAt, isNotNull);
      expect(
        messages(s.epk),
        isEmpty,
        reason: 'still streaming — nothing persisted yet',
      );
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'room switch away-and-back keeps a streaming answer: content accumulates '
    'while away and the bubble restores on return',
    () async {
      final s = await setupWithRooms();
      // Every frame says which room produced it; the app must pick the writer
      // from that tag alone.
      s.ch.pushRoomFrame(
        'main',
        {'type': 'user_input', 'id': 'u1', 'text': 'hi'},
      );
      await _settle();
      s.ch.pushRoomFrame(
        'main',
        {'type': 'agent_chunk', 'in_reply_to': 'u1', 'delta': 'Hel'},
      );
      await _settle();
      s.ch.pushRoomFrame(
        'main',
        {'type': 'agent_chunk', 'in_reply_to': 'u1', 'delta': 'lo'},
      );
      await _settle();
      expect(s.sync.streaming!.buffer, 'Hello');

      // The user moves to another room of the same peer.
      await s.sync.activate(s.epk, 'roomB');
      await _settle();
      expect(s.sync.streaming, isNull, reason: 'roomB is idle');

      // While viewing roomB, room main keeps streaming. Those frames arrive
      // room-tagged on the side channel (the session writer only sees
      // roomB's frames) and must keep filling MAIN's in-memory slot.
      s.ch.pushRoomFrame(
        'main',
        {'type': 'agent_chunk', 'in_reply_to': 'u1', 'delta': ' wor'},
      );
      await _settle();
      s.ch.pushRoomFrame(
        'main',
        {'type': 'agent_chunk', 'in_reply_to': 'u1', 'delta': 'ld'},
      );
      await _settle();
      expect(
        s.sync.streaming,
        isNull,
        reason: 'background room never paints the visible chat',
      );
      expect(
        messages(s.epk).where((m) => m.role == MsgRole.assistant),
        isEmpty,
        reason: 'streaming content is in-memory only until finalized',
      );

      // Returning to main restores the FULL accumulated bubble.
      await s.sync.activate(s.epk, 'main');
      await _settle();
      final live = s.sync.streaming;
      expect(live, isNotNull, reason: 'in-flight answer restored on return');
      expect(live!.buffer, 'Hello world');
      expect(live.inReplyTo, 'u1');

      // The turn finishes in main: the finalized row carries ALL the text.
      s.ch.pushRoomFrame('main', {'type': 'agent_done', 'in_reply_to': 'u1'});
      await _settle();
      final rows = messages(s.epk);
      final assistant = rows.singleWhere((m) => m.role == MsgRole.assistant);
      expect(assistant.text, 'Hello world');
      expect(s.sync.streaming, isNull);
      expect(s.sync.isWorking, isFalse);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'a drifted addressed room never mixes transcripts: the FRAME\'s room '
    'picks the writer, not the room the connection happens to address',
    () async {
      final s = await setupWithRooms();
      // The user is reading roomB. Then the connection gets re-addressed to
      // `main` by somebody else — a room ride, a notification tap, or a stale
      // chat page re-asserting its own room on a reconnect edge. `switchRoom`
      // is one mutable field, so this drift is normal and must never reach the
      // transcript: it used to send main's frames into roomB's rows/slot and
      // drop roomB's own frames as if they were background traffic.
      await s.sync.activate(s.epk, 'roomB');
      await _settle();
      s.conn.switchRoom('main');
      await _settle();

      s.ch.pushRoomFrame(
        'main',
        {'type': 'agent_thinking', 'in_reply_to': 'r1', 'delta': 'stranger'},
      );
      await _settle();
      expect(
        s.sync.streaming,
        isNull,
        reason: "another room's reasoning must not paint the open chat",
      );
      expect(s.sync.isWorking, isFalse);
      expect(messages(s.epk, 'roomB'), isEmpty);

      // RoomB's OWN frames still land in its transcript.
      s.ch.pushRoomFrame(
        'roomB',
        {'type': 'user_input', 'id': 'u2', 'text': 'hello'},
      );
      await _settle();
      expect(messages(s.epk, 'roomB').single.text, 'hello');
      expect(
        messages(s.epk),
        isEmpty,
        reason: 'the drifted room keeps its own traffic',
      );
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'the thinking counter does NOT reset to zero on a room switch: the '
    'reasoning start time survives away-and-back',
    () async {
      final s = await setupWithRooms();
      s.ch.pushRoomFrame(
        'main',
        {'type': 'agent_thinking', 'in_reply_to': 'r1', 'delta': 'mulling'},
      );
      await _settle();
      final started = s.sync.streaming!.startedAt;
      expect(started, isNotNull, reason: 'reasoning block is clocked');

      await s.sync.activate(s.epk, 'roomB');
      await _settle();

      // Time passes while the user is in roomB; the reasoning segment stays
      // open in main's slot.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      s.ch.pushRoomFrame(
        'main',
        {'type': 'agent_thinking', 'in_reply_to': 'r1', 'delta': ' more'},
      );
      await _settle();

      await s.sync.activate(s.epk, 'main');
      await _settle();

      final live = s.sync.streaming!;
      expect(live.thinking, isTrue);
      expect(live.buffer, 'mulling more');
      expect(
        live.startedAt,
        started,
        reason: 'the clock must not restart when the user comes back',
      );
      expect(
        DateTime.now().difference(live.startedAt!).inMilliseconds,
        greaterThanOrEqualTo(100),
        reason: 'elapsed time keeps counting through the switch',
      );
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('cancelling a turn drops the live reasoning buffer', () async {
    final s = await setup();
    s.ch.push(AgentThinking(inReplyTo: 'r1', delta: 'half a thought'));
    await _settle();
    s.ch.push(Cancelled(inReplyTo: 'r1', targetId: 'r1'));
    await _settle();

    expect(s.sync.streaming, isNull);
    expect(
      messages(s.epk),
      isEmpty,
      reason: 'an interrupted thought is not history',
    );
    s.conn.dispose();
    s.sync.dispose();
  });

  // LOCAL (fenlyin): the per-message model rides the history events onto the
  // rows (the per-row caption shows it next to the timestamp).
  test('session_history events carry their model onto the rows', () async {
    final s = await setup();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'u1',
        sessionStartedAt: 0,
        events: const [
          UserInputEvt(ts: 10, id: 'u1', text: 'why', model: 'Qwen3.8-27B'),
          AgentMessageEvt(
            ts: 11,
            inReplyTo: 'u1',
            text: 'the answer',
            model: 'Qwen3.8-27B',
          ),
        ],
        eos: true,
      ),
    );
    await _settle();
    final rows = messages(s.epk);
    expect(rows.map((m) => m.role), [MsgRole.user, MsgRole.assistant]);
    expect(rows.every((m) => m.model == 'Qwen3.8-27B'), isTrue);
    s.conn.dispose();
    s.sync.dispose();
  });

  // LOCAL (fenlyin): a room whose cached model went stale (the relay only
  // re-announces a room when its FIRST conn registers) is corrected from
  // the last assistant row of the history the Pi just replayed.
  test('session_history self-heals the active room\'s stale cached model', () async {
    final s = await setup();
    s.ch.pushControl(
      RoomAnnounced(
        peer: s.epk,
        roomId: 'main',
        startedAt: 0,
        model: 'Claude Opus 4.7', // the stale cached value
      ),
    );
    await _settle();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'u1',
        sessionStartedAt: 0,
        events: const [
          UserInputEvt(ts: 10, id: 'u1', text: 'why'),
          AgentMessageEvt(
            ts: 11,
            inReplyTo: 'u1',
            text: 'the answer',
            model: 'Qwen3.8-27B',
          ),
        ],
        eos: true,
      ),
    );
    await _settle();
    expect(s.conn.roomsFor(s.epk).single.model, 'Qwen3.8-27B');
    s.conn.dispose();
    s.sync.dispose();
  });

  // LOCAL (fenlyin): `ts` 0 is the mapper's "unknown timestamp" sentinel —
  // the row must not render a "1970-01-01" caption.
  test('history events with ts 0 get no timestamp on the row', () async {
    final s = await setup();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'u1',
        sessionStartedAt: 0,
        events: const [
          UserInputEvt(ts: 0, id: 'u1', text: 'no time'),
        ],
        eos: true,
      ),
    );
    await _settle();
    final rows = messages(s.epk);
    expect(rows, hasLength(1));
    expect(rows.single.ts, isNull);
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'session_history replays reasoning rows, and an identical re-apply '
    'writes nothing',
    () async {
      final s = await setup();
      final read = SessionReadRepository(LocalBoxes());
      var emits = 0;
      final sub = read.watchMessages(s.epk, 'main').listen((_) => emits++);
      await _settle();

      SessionHistory hist(String inReplyTo) => SessionHistory(
        inReplyTo: inReplyTo,
        sessionStartedAt: 0,
        events: const [
          UserInputEvt(ts: 10, id: 'u1', text: 'why'),
          AgentThinkingEvt(
            ts: 11,
            inReplyTo: 'u1',
            text: 'because reasons',
            durationMs: 4200,
          ),
          AgentMessageEvt(ts: 12, inReplyTo: 'u1', text: 'the answer'),
        ],
        eos: true,
      );

      s.ch.push(hist('sync1'));
      await _settle();
      final afterFirst = emits;
      expect(messages(s.epk).map((m) => m.role), [
        MsgRole.user,
        MsgRole.thinking,
        MsgRole.assistant,
      ]);
      expect(messages(s.epk)[1].text, 'because reasons');

      s.ch.push(hist('sync2'));
      await _settle();
      expect(
        emits,
        afterFirst,
        reason: 'identical re-apply must not rewrite the reasoning row',
      );

      await sub.cancel();
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('cancel sends a Cancel frame for the active turn target', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'u1', text: 'hi'));
    await _settle();

    await s.sync.cancel('u1');
    await _settle();

    final cancel = s.ch.sent.whereType<Cancel>().single;
    expect(cancel.targetId, 'u1');
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'cancelled stops the turn but preserves confirmed user history',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'keep this'));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'partial'));
      s.ch.push(Cancelled(inReplyTo: 'cancel-1', targetId: 'u1'));
      await _settle();

      final rows = messages(s.epk);
      expect(
        rows.where((m) => m.id == 'u1' && m.role == MsgRole.user),
        hasLength(1),
      );
      expect(rows.singleWhere((m) => m.id == 'u1').pending, isFalse);
      expect(s.sync.streaming, isNull);
      expect(s.sync.isWorking, isFalse);
      expect(index(s.epk)?.status, SessionActivity.idle);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('cancelled removes a still-pending optimistic user row', () async {
    final s = await setup();
    await s.sync.sendMessage('stop before echo');
    await _settle();
    final id = (s.ch.sent.whereType<UserMessage>().last).id;
    expect(messages(s.epk).single.pending, isTrue);

    s.ch.push(Cancelled(inReplyTo: 'cancel-1', targetId: id));
    await _settle();

    expect(messages(s.epk), isEmpty);
    expect(s.sync.streaming, isNull);
    expect(s.sync.isWorking, isFalse);
    expect(index(s.epk)?.status, SessionActivity.idle);
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'server error clears pending chunk flush so chat does not stay working',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'hi'));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'partial'));
      s.ch.push(
        ErrorMessage(
          inReplyTo: 'cancel-1',
          code: 'internal_error',
          message: 'No active Pi context to abort',
        ),
      );
      await _settle();

      expect(s.sync.streaming, isNull);
      expect(s.sync.isWorking, isFalse);
      expect(index(s.epk)?.status, SessionActivity.idle);
      final errorTexts = messages(
        s.epk,
      ).where((m) => m.role == MsgRole.assistant).map((m) => m.text);
      expect(errorTexts, contains(startsWith('⚠ internal_error:')));
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('isWorking spans the whole turn (echo → agent_done)', () async {
    final s = await setup();
    expect(s.sync.isWorking, isFalse);
    final flags = <bool>[];
    final sub = s.sync.workingStream.listen(flags.add);

    s.ch.push(UserInput(id: 'u1', text: 'hi'));
    await _settle();
    expect(s.sync.isWorking, isTrue, reason: 'working from the echo');

    s.ch.push(AgentDone(inReplyTo: 'u1'));
    await _settle();
    expect(s.sync.isWorking, isFalse, reason: 'idle after agent_done');
    expect(flags, [true, false]);

    await sub.cancel();
    s.conn.dispose();
    s.sync.dispose();
  });

  test('switching sessions resets the in-memory turn state — working/streaming '
      'do NOT leak into the next chat (plan/32)', () async {
    final s = await setup();

    // Session 1 is mid-turn: working flag + streaming buffer populated.
    s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'thinking...'));
    await _settle();
    expect(s.sync.isWorking, isTrue);
    expect(s.sync.streaming, isNotNull);
    expect(s.sync.workingReplyTo, 'r1');

    final flags = <bool>[];
    final sub = s.sync.workingStream.listen(flags.add);

    // Switch the writer to a DIFFERENT session (what the chat does on a
    // tablet session switch). Must clear the in-memory signals.
    await s.sync.activate('epk_other_session', 'main');
    await _settle();

    expect(
      s.sync.isWorking,
      isFalse,
      reason: 'chat 2 must not inherit chat 1 working',
    );
    expect(
      s.sync.streaming,
      isNull,
      reason: 'chat 1 streaming buffer must not show in chat 2',
    );
    expect(s.sync.workingReplyTo, isNull);
    expect(
      flags,
      contains(false),
      reason: 'listeners are notified the flag cleared',
    );

    // The previous session's DURABLE index must stay "working" — the Pi
    // may still be mid-turn and Home reflects it (relay broadcast + DB).
    // Clearing the in-memory signals must NOT idle the box row.
    expect(
      index(s.epk)?.status,
      SessionActivity.working,
      reason: 'switching away must not idle chat 1 in the DB',
    );

    await sub.cancel();
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'cursor: streaming is seeded EMPTY at turn start, before any chunk',
    () async {
      final s = await setup();
      expect(s.sync.streaming, isNull);

      // Optimistic send seeds the thinking cursor (online).
      await s.sync.sendMessage('hi');
      await _settle();
      expect(s.sync.streaming, isNotNull, reason: 'cursor during thinking');
      expect(s.sync.streaming!.buffer, isEmpty);

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'cursor: foreign echo seeds it; a text-less turn clears it on done',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u9', text: 'from terminal'));
      await _settle();
      expect(s.sync.streaming, isNotNull, reason: 'cursor before any chunk');
      expect(s.sync.streaming!.buffer, isEmpty);

      // Turn produces no text (e.g. only tool calls) → done still clears it.
      s.ch.push(AgentDone(inReplyTo: 'u9'));
      await _settle();
      expect(s.sync.streaming, isNull, reason: 'done clears the cursor');
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('cursor: a chunk appends onto the seeded empty buffer', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'u1', text: 'hi'));
    await _settle();
    s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'tok'));
    await _settle();
    expect(s.sync.streaming!.buffer, 'tok', reason: 'appended, not replaced');
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'sequential: text → tool → text renders in chronological order',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'go'));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'let me check'));
      await _settle(); // 16ms flush settles into the streaming buffer
      s.ch.push(ToolRequest(toolCallId: 'tc1', tool: 'Read', args: {}));
      await _settle();
      s.ch.push(ToolResult(toolCallId: 'tc1', result: {'ok': true}));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'all done'));
      await _settle();
      s.ch.push(AgentDone(inReplyTo: 'u1'));
      await _settle();

      final m = messages(s.epk);
      expect(
        m.map((r) => r.role),
        [MsgRole.user, MsgRole.assistant, MsgRole.tool, MsgRole.assistant],
        reason: 'pre-tool text, then tool, then post-tool text — in order',
      );
      expect(m[1].text, 'let me check');
      expect(m[2].tool?.tool, 'Read');
      expect(m[3].text, 'all done');
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'a tool\'s own diff is stored live, and replayed by a re-sync',
    () async {
      final s = await setup();
      const diff = "- 13 const b = 2;\n+ 13 const b = 3;";
      s.ch.push(ToolRequest(toolCallId: 'tc1', tool: 'edit', args: {}));
      await _settle();
      s.ch.push(ToolResult(toolCallId: 'tc1', result: 'done', diff: diff));
      await _settle();

      expect(messages(s.epk).single.tool?.diff, diff);
      // The chat row the card renders carries it too.
      final evt = messages(s.epk).single.toChatMessage() as ToolEvent;
      expect(evt.diff, diff);

      // A tool that reports no diff stays null — nothing is invented.
      s.ch.push(ToolRequest(toolCallId: 'tc2', tool: 'Read', args: {}));
      await _settle();
      s.ch.push(ToolResult(toolCallId: 'tc2', result: 'file'));
      await _settle();
      expect(
        messages(
          s.epk,
        ).firstWhere((r) => r.tool?.toolCallId == 'tc2').tool?.diff,
        isNull,
      );

      // Re-synced history: the args preview is never replayed, so this is the
      // only diff a reopened room gets.
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 0,
          events: const [
            ToolRequestEvt(ts: 1, toolCallId: 'h1', tool: 'edit', args: null),
            ToolResultEvt(ts: 2, toolCallId: 'h1', result: 'done', diff: diff),
          ],
          eos: true,
        ),
      );
      await _settle();
      expect(
        messages(
          s.epk,
        ).firstWhere((r) => r.tool?.toolCallId == 'h1').tool?.diff,
        diff,
      );

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('re-applying an IDENTICAL SessionHistory is idempotent — no box churn, '
      'so the relay re-sending history on every reconnect no longer tears the '
      'list down and rebuilds it (plan/32 flicker fix)', () async {
    final s = await setup();
    final read = SessionReadRepository(LocalBoxes());
    var emits = 0;
    final sub = read.watchMessages(s.epk, 'main').listen((_) => emits++);
    await _settle();

    SessionHistory hist(String inReplyTo) => SessionHistory(
      inReplyTo: inReplyTo,
      sessionStartedAt: 0,
      events: const [
        UserInputEvt(ts: 1, id: 'u1', text: 'hi'),
        AgentMessageEvt(ts: 2, inReplyTo: 'a1', text: 'hello'),
        ToolRequestEvt(ts: 3, toolCallId: 'c1', tool: 'Read', args: null),
      ],
      eos: true,
    );

    s.ch.push(hist('sync1'));
    await _settle();
    final afterFirst = emits;
    expect(afterFirst, greaterThan(1), reason: 'first apply populates rows');
    expect(messages(s.epk).map((r) => r.role), [
      MsgRole.user,
      MsgRole.assistant,
      MsgRole.tool,
    ]);

    // Relay re-delivers the SAME history (different in_reply_to, identical
    // events) — the reconcile must write nothing → no watch event → no emit.
    s.ch.push(hist('sync2'));
    await _settle();
    expect(
      emits,
      afterFirst,
      reason: 'identical re-apply must not emit (no list rebuild/flicker)',
    );

    await sub.cancel();
    s.conn.dispose();
    s.sync.dispose();
  });

  test('a replay that rewrites many rows publishes ONE list update for the '
      'whole reply — not one rebuild per written row', () async {
    final s = await setup();
    final read = SessionReadRepository(LocalBoxes());
    final seen = <int>[];
    final sub = read
        .watchMessages(s.epk, 'main')
        .listen((rows) => seen.add(rows.length));
    await _settle();
    expect(seen, [0], reason: 'the empty projection on listen');

    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: [
          for (var i = 0; i < 8; i++) ...[
            UserInputEvt(ts: 10 + i * 2, id: 'u$i', text: 'q$i'),
            AgentMessageEvt(ts: 11 + i * 2, inReplyTo: 'u$i', text: 'a$i'),
          ],
        ],
        eos: true,
      ),
    );
    await _settle();

    expect(messages(s.epk), hasLength(16));
    expect(
      seen,
      [0, 16],
      reason: 'the box took 16 writes, the transcript is rebuilt once',
    );

    await sub.cancel();
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'switching the writer to a new session: a late frame from the OLD '
    "connection is dropped — it neither writes the new box nor appears in the "
    "new session's read projection (plan/32f session-switch bleed)",
    () async {
      final s = await setup(); // bound to s.epk (peer A)
      s.ch.push(UserInput(id: 'a1', text: 'from chat1'));
      await _settle();
      expect(messages(s.epk), hasLength(1));

      // Switch the writer to chat 2 (epkB) WITHOUT a new channel — simulates
      // the window where the chat calls activate(epkB) before switchTo tears
      // the old peer's channel down. _activeEpk moves; the old channel (origin
      // = peer A) is still draining.
      const epkB = 'epk_chat2_zzz';
      final read = SessionReadRepository(LocalBoxes());
      final seenLens = <int>[];
      final sub = read
          .watchMessages(epkB, 'main')
          .listen((rows) => seenLens.add(rows.length));
      await s.sync.activate(epkB, 'main');
      await _settle();

      // Straggler frame on the OLD (peer A) channel.
      s.ch.push(UserInput(id: 'late', text: 'late chat1'));
      await _settle();

      expect(
        messages(epkB),
        isEmpty,
        reason: 'old-connection frame must not bleed into the new box',
      );
      expect(
        seenLens.every((n) => n == 0),
        isTrue,
        reason: "chat 2's projection never shows chat 1 rows",
      );
      expect(
        messages(s.epk),
        hasLength(1),
        reason: 'chat 1 box keeps exactly its own row (late frame dropped)',
      );

      await sub.cancel();
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('compaction ServerMessage writes a system row that projects to a '
      'CompactionMsg system bubble (plan/32)', () async {
    final s = await setup();
    s.ch.push(
      Compaction(
        summary: 'recapped the thread',
        tokensBefore: 12000,
        ts: 1700000000000,
      ),
    );
    await _settle();

    final m = messages(s.epk);
    expect(m, hasLength(1));
    expect(m.first.role, MsgRole.compaction);
    expect(m.first.text, 'recapped the thread');
    expect(m.first.tokensBefore, 12000);
    // Projects to the domain system-bubble message.
    expect(m.first.toChatMessage(), isA<CompactionMsg>());

    s.conn.dispose();
    s.sync.dispose();
  });

  test('compaction event in session_history reconstructs the system row on '
      're-sync (plan/32)', () async {
    final s = await setup();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: const [
          UserInputEvt(ts: 1, id: 'u1', text: 'hi'),
          AgentMessageEvt(ts: 2, inReplyTo: 'a1', text: 'hello'),
          CompactionEvt(ts: 3, summary: 'compacted', tokensBefore: 5000),
        ],
        eos: true,
      ),
    );
    await _settle();

    final m = messages(s.epk);
    expect(m.map((r) => r.role), [
      MsgRole.user,
      MsgRole.assistant,
      MsgRole.compaction,
    ]);
    expect(m.last.text, 'compacted');
    expect(m.last.tokensBefore, 5000);
    expect(m.last.toChatMessage(), isA<CompactionMsg>());

    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'clearActiveSession wipes rows, index, and in-memory turn state',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'hi'));
      await _settle();
      expect(messages(s.epk), hasLength(1));
      expect(s.sync.isWorking, isTrue);
      expect(s.sync.streaming, isNotNull);

      await s.sync.clearActiveSession();
      await _settle();
      expect(messages(s.epk), isEmpty);
      expect(index(s.epk), isNull);
      expect(s.sync.isWorking, isFalse);
      expect(s.sync.streaming, isNull);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'relay working=false clears stale active-chat local working state',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'hi'));
      await _settle();
      expect(s.sync.isWorking, isTrue);

      s.ch.pushControl(
        RoomAnnounced(peer: s.epk, roomId: 'main', startedAt: 1),
      );
      s.ch.pushControl(
        RoomMetaUpdated(
          peer: s.epk,
          roomId: 'main',
          working: true,
          hasModel: false,
          hasThinking: false,
        ),
      );
      await _settle();
      expect(s.sync.isWorking, isTrue);

      s.ch.pushControl(
        RoomMetaUpdated(
          peer: s.epk,
          roomId: 'main',
          working: false,
          hasModel: false,
          hasThinking: false,
        ),
      );
      await _settle();
      expect(s.conn.isRoomWorking(s.epk, 'main'), isFalse);
      expect(s.sync.isWorking, isFalse);
      expect(s.sync.streaming, isNull);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'relay working=false racing agent_done does not eat the streamed reply',
    () async {
      final s = await setup();
      await s.sync.sendMessage('hi');
      await _settle();
      final target = s.ch.sent.whereType<UserMessage>().single.id;

      s.ch.push(AgentChunk(inReplyTo: target, delta: 'Hello'));
      await _settle();
      expect(s.sync.streaming?.buffer, 'Hello');

      // The relay's `turn_end` → `working:false` room meta reaches the app over
      // the control channel while `agent_done` rides the chat channel. When the
      // meta loses the race (or simply wins by a frame), the discarded buffer
      // must not take the un-finalized reply with it.
      s.ch.pushControl(
        RoomAnnounced(peer: s.epk, roomId: 'main', startedAt: 1),
      );
      s.ch.pushControl(
        RoomMetaUpdated(
          peer: s.epk,
          roomId: 'main',
          working: true,
          hasModel: false,
          hasThinking: false,
        ),
      );
      await _settle();
      s.ch.pushControl(
        RoomMetaUpdated(
          peer: s.epk,
          roomId: 'main',
          working: false,
          hasModel: false,
          hasThinking: false,
        ),
      );
      await _settle();

      s.ch.push(AgentDone(inReplyTo: target));
      await _settle();

      expect(
        messages(s.epk).map((m) => m.text),
        contains('Hello'),
        reason: 'the reply must be in the box, not only in the next re-sync',
      );
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  // Plan/32 safety net — a sent message whose echo never comes back must not
  // spin forever; the optimistic bubble is removed SILENTLY after the timeout.
  group('no-echo send timeout', () {
    const short = Duration(milliseconds: 60);

    test(
      '(a) pending bubble is removed silently when no echo arrives',
      () async {
        final s = await setup(pendingSendTimeout: short);
        await s.sync.sendMessage('hello');
        await _settle();
        expect(messages(s.epk), hasLength(1), reason: 'optimistic pending row');
        expect(messages(s.epk).first.pending, isTrue);
        expect(s.sync.isWorking, isTrue);
        expect(s.sync.streaming, isNotNull, reason: 'thinking cursor seeded');

        // No echo — wait past the timeout window.
        await Future<void>.delayed(const Duration(milliseconds: 140));
        await _settle();

        expect(
          messages(s.epk),
          isEmpty,
          reason: 'bubble removed, no failed state',
        );
        expect(
          s.sync.isWorking,
          isFalse,
          reason: 'working cleared for this id',
        );
        expect(s.sync.streaming, isNull, reason: 'thinking cursor cleared');
        expect(index(s.epk)?.status, SessionActivity.idle);
        expect(s.sync.debugPendingSendTimerCount, 0);
        s.conn.dispose();
        s.sync.dispose();
      },
    );

    test(
      '(b) echo within the window confirms the row and cancels the timer',
      () async {
        final s = await setup(pendingSendTimeout: short);
        await s.sync.sendMessage('hello');
        await _settle();
        expect(s.sync.debugPendingSendTimerCount, 1, reason: 'timer armed');
        final id = s.ch.sent.whereType<UserMessage>().last.id;

        // Echo arrives promptly → confirms + disarms.
        s.ch.push(UserInput(id: id, text: 'hello'));
        await _settle();
        expect(messages(s.epk), hasLength(1));
        expect(
          messages(s.epk).first.pending,
          isFalse,
          reason: 'confirmed by echo',
        );
        expect(
          s.sync.debugPendingSendTimerCount,
          0,
          reason: 'echo cancelled timer',
        );

        // Wait PAST the timeout — the cancelled timer must NOT remove the row.
        await Future<void>.delayed(const Duration(milliseconds: 140));
        await _settle();
        expect(
          messages(s.epk),
          hasLength(1),
          reason: 'row survives the window',
        );
        expect(messages(s.epk).first.pending, isFalse);
        s.conn.dispose();
        s.sync.dispose();
      },
    );

    test(
      '(c) timers are cancelled on session switch and on dispose (no leak)',
      () async {
        // Session switch path.
        final s = await setup(pendingSendTimeout: short);
        await s.sync.sendMessage('one');
        await _settle();
        expect(s.sync.debugPendingSendTimerCount, 1);

        await s.sync.activate('epk_switch_target', 'main');
        await _settle();
        expect(
          s.sync.debugPendingSendTimerCount,
          0,
          reason: 'session switch cancels + clears pending timers',
        );

        // dispose path (fresh service so the switch above doesn't mask it).
        final s2 = await setup(pendingSendTimeout: short);
        await s2.sync.sendMessage('two');
        await _settle();
        expect(s2.sync.debugPendingSendTimerCount, 1);
        s2.sync.dispose();
        expect(
          s2.sync.debugPendingSendTimerCount,
          0,
          reason: 'dispose cancels + clears pending timers',
        );

        s.conn.dispose();
        s.sync.dispose();
        s2.conn.dispose();
      },
    );

    test('(d) an offline (held-pending) send is reaped too', () async {
      // No channel ever adopted → sendMessage takes the offline path. Decision:
      // held-pending is reaped 20s after its ts as well (nothing spins forever).
      final conn = ConnectionManager(
        factory: (_, _) async => _FakeChannel(),
        storage: _FakeStorage(),
      );
      final sync = SyncService(conn, LocalBoxes(), pendingSendTimeout: short);
      final epk = 'epk_offline_${++_counter}';
      await sync.activate(epk, 'main');
      await _settle();

      await sync.sendMessage('typed while offline');
      await _settle();
      expect(messages(epk), hasLength(1), reason: 'held pending row written');
      expect(messages(epk).first.pending, isTrue);
      expect(
        sync.debugPendingSendTimerCount,
        1,
        reason: 'reaper armed offline',
      );

      await Future<void>.delayed(const Duration(milliseconds: 140));
      await _settle();
      expect(
        messages(epk),
        isEmpty,
        reason: 'offline bubble reaped (decision)',
      );
      conn.dispose();
      sync.dispose();
    });

    test(
      '(e) returning to a session reaps a bubble already past the window',
      () async {
        // Quick exit then return: the live timer is cancelled on switch-away,
        // but _loadIndex re-arms on return using the saved ts → an already-stale
        // row fires immediately. Covers app-restart + quick-switch orphans.
        final s = await setup(pendingSendTimeout: short);
        await s.sync.sendMessage('hi');
        await _settle();
        expect(messages(s.epk), hasLength(1));

        // Leave quickly → live timer cancelled; row stays pending in the box.
        await s.sync.activate('epk_away_${++_counter}', 'main');
        await _settle();
        expect(
          s.sync.debugPendingSendTimerCount,
          0,
          reason: 'timers cleared on switch',
        );
        expect(
          messages(s.epk),
          hasLength(1),
          reason: 'orphaned row still in box',
        );

        // Time passes beyond the window while away from the session.
        await Future<void>.delayed(const Duration(milliseconds: 140));
        expect(
          messages(s.epk),
          hasLength(1),
          reason: 'no live timer reaps it while away',
        );

        // Return → load re-arms by ts → already stale → reaped on arrival.
        await s.sync.activate(s.epk, 'main');
        await _settle();
        expect(
          messages(s.epk),
          isEmpty,
          reason: 'stale pending reaped on return',
        );
        s.conn.dispose();
        s.sync.dispose();
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Sent pictures: the phone's own archive
  // ---------------------------------------------------------------------------
  //
  // A sent picture used to live in the row itself, and `session_history` is a
  // WHOLESALE substitute for the room — so a Pi-side cleanup (or the replay's
  // byte budget dropping the payload) silently erased the picture from the
  // transcript. The bytes now live in `sent_images/`, content addressed, and the
  // row keeps only the name: a replay can rewrite the row and the picture stays.

  group('sent picture archive', () {
    Directory blobs() => Directory('${_dir.path}/sent_images');

    test('the row keeps only the archive name; the bytes go to disk', () async {
      final s = await setup();
      await s.sync.sendMessage(
        'look',
        images: [MessageImage(data: _squarePng, mime: 'image/png')],
      );
      await _settle();

      // The wire is unchanged: the Pi still receives the bytes inline.
      final frame = s.ch.sent.whereType<UserMessage>().single;
      expect(frame.images?.single.data, _squarePng);

      final image = messages(s.epk).single.images.single;
      expect(image.blob, isNotNull, reason: 'archived, not inline');
      expect(image.data, isEmpty, reason: 'a megabyte of base64 stays out of Hive');
      expect(image.width, 200, reason: 'the header size rides along for layout');
      expect(image.height, 200);

      final bytes = await s.sync.sentImageBytes(image.blob!);
      expect(bytes, isNotNull, reason: 'the phone can read its own copy');
      expect(bytes, base64Decode(_squarePng));
      s.conn.dispose();
      s.sync.dispose();
    });

    test('a replay that lost the picture keeps the phone copy', () async {
      final s = await setup();
      // First replay: the Pi still has the bytes (same id + text as any later
      // replay of the same session file — the id is `sync_<ts>` on the Pi).
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 0,
          events: const [
            UserInputEvt(
              ts: 10,
              id: 'sync_10',
              text: 'look',
              images: [WireImage(data: _squarePng, mime: 'image/png')],
            ),
          ],
          eos: true,
        ),
      );
      await _settle();
      final archived = messages(s.epk).single.images.single;
      expect(archived.blob, isNotNull);

      // The Pi's session file was cleaned: the row comes back, the bytes do not.
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync2',
          sessionStartedAt: 0,
          events: const [
            UserInputEvt(ts: 10, id: 'sync_10', text: 'look'),
          ],
          eos: true,
        ),
      );
      await _settle();

      final row = messages(s.epk).single;
      expect(row.images, hasLength(1), reason: 'the picture is not the Pi to take');
      expect(row.images.single.blob, archived.blob);
      s.conn.dispose();
      s.sync.dispose();
    });

    test('replays do not pile up copies of the same picture', () async {
      final s = await setup();
      Future<void> replay(String replyTo) async {
        s.ch.push(
          SessionHistory(
            inReplyTo: replyTo,
            sessionStartedAt: 0,
            events: const [
              UserInputEvt(
                ts: 20,
                id: 'sync_20',
                text: 'look',
                images: [WireImage(data: _squarePng, mime: 'image/png')],
              ),
            ],
            eos: true,
          ),
        );
        await _settle();
      }

      await replay('sync1');
      final afterFirst = blobs().listSync().length;
      await replay('sync2');
      expect(
        blobs().listSync().length,
        afterFirst,
        reason: 'content addressed: the same bytes are one file, forever',
      );
      s.conn.dispose();
      s.sync.dispose();
    });

    test('a row that never had a picture stays picture-less', () async {
      final s = await setup();
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 0,
          events: const [UserInputEvt(ts: 30, id: 'sync_30', text: 'hello')],
          eos: true,
        ),
      );
      await _settle();
      expect(messages(s.epk).single.images, isEmpty);
      s.conn.dispose();
      s.sync.dispose();
    });

    // pi answers a picture with a note addressed to the MODEL (how far the
    // inline copy was scaled down) and appends it to the user message's own
    // text. Only a replay carries it — the phone-sent echo has the typed text —
    // so entering the room again used to grow a bubble above the picture.
    const hint =
        '[Image: original 1080x2400, displayed at 900x2000. Multiply '
        'coordinates by 1.20 to map to original image.]';

    test('the model-facing image note never becomes a bubble', () async {
      final s = await setup();
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 0,
          events: const [
            UserInputEvt(
              ts: 40,
              id: 'sync_40',
              text: 'what is this?\n\n$hint',
              images: [WireImage(data: _squarePng, mime: 'image/png')],
            ),
          ],
          eos: true,
        ),
      );
      await _settle();
      final row = messages(s.epk).single;
      expect(row.text, 'what is this?', reason: 'the caption the user typed');
      expect(row.images, hasLength(1));
      s.conn.dispose();
      s.sync.dispose();
    });

    test('a note-only message keeps no text at all', () async {
      final s = await setup();
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 0,
          events: const [
            UserInputEvt(
              ts: 50,
              id: 'sync_50',
              text: hint,
              images: [WireImage(data: _squarePng, mime: 'image/png')],
            ),
          ],
          eos: true,
        ),
      );
      await _settle();
      final row = messages(s.epk).single;
      expect(row.text, isEmpty, reason: 'the picture carries the message');
      expect(row.images, hasLength(1));
      s.conn.dispose();
      s.sync.dispose();
    });

    test('text that merely mentions an image survives', () async {
      final s = await setup();
      s.ch.push(
        SessionHistory(
          inReplyTo: 'sync1',
          sessionStartedAt: 0,
          events: const [
            UserInputEvt(
              ts: 60,
              id: 'sync_60',
              text: 'the [Image: ...] note in the log is noise',
            ),
          ],
          eos: true,
        ),
      );
      await _settle();
      expect(
        messages(s.epk).single.text,
        'the [Image: ...] note in the log is noise',
      );
      s.conn.dispose();
      s.sync.dispose();
    });

    // A reconnect or a room re-entry used to replay the whole mirror: measured
    // over nine days, one room sent the same 526 KB ten times in ninety seconds,
    // and nine of those arrived at rows that already matched. The app now sends
    // the Pi's cursor back and gets only what came after it.
    group('incremental session_history', () {
      /// Ask for a sync and hand back the id of that request. A reply answers
      /// one of them, and the moment it left is how the store tells the rows the
      /// reply can contain from the ones written while it was in flight.
      String askForSync(_FakeChannel ch, SyncService sync) {
        ch.sent.clear();
        sync.requestSync();
        return ch.sent.whereType<SessionSync>().single.id;
      }

      /// Poll until [done] holds — the index write rides the same queue as the
      /// rows, so a fixed delay is a slow machine rather than a broken app.
      Future<void> waitUntil(bool Function() done) async {
        for (var i = 0; i < 200; i++) {
          if (done()) return;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(done(), isTrue, reason: 'the condition never held');
      }

      /// Wait for the box to reach a state instead of sleeping a fixed window:
      /// a replay goes through the write queue and a card also decodes + archives
      /// its bytes, so a fixed delay is a slow machine, not a failed assertion.
      Future<List<MessageRecord>> rowsWhen(
        String epk,
        bool Function(List<MessageRecord>) done,
      ) async {
        for (var i = 0; i < 200; i++) {
          if (done(messages(epk))) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return messages(epk);
      }

      test('a delta appends to the stored rows instead of replacing them',
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 10, id: 'sync_10', text: 'first'),
              AgentMessageEvt(ts: 11, inReplyTo: 'sync_10', text: 'answer'),
            ],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();
        expect(messages(s.epk).map((r) => r.text), ['first', 'answer']);

        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync2',
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 20, id: 'sync_20', text: 'second'),
              AgentMessageEvt(ts: 21, inReplyTo: 'sync_20', text: 'reply'),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        await _settle();
        expect(
          messages(s.epk).map((r) => r.text),
          ['first', 'answer', 'second', 'reply'],
          reason: 'the delta lands after what the device already had',
        );
        expect(index(s.epk)?.syncCursor, '100:bbbb');
        s.conn.dispose();
        s.sync.dispose();
      });

      test('the cursor is stored, so the next sync asks from it', () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'hi')],
            eos: true,
            cursor: '100:deadbeef',
          ),
        );
        await _settle();
        expect(index(s.epk)?.syncCursor, '100:deadbeef');

        s.ch.sent.clear();
        s.sync.requestSync();
        await _settle();
        final sync = s.ch.sent.whereType<SessionSync>().single;
        expect(sync.since, '100:deadbeef');
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a full replay still substitutes, and drops a stale delta base',
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'old')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        // The Pi could not place the cursor (session replaced, budget trimmed):
        // it replays everything, and the app must end up with exactly that.
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync2',
            sessionStartedAt: 200,
            events: const [UserInputEvt(ts: 30, id: 'sync_30', text: 'new')],
            eos: true,
            cursor: '200:cccc',
          ),
        );
        await _settle();
        expect(messages(s.epk).map((r) => r.text), ['new']);
        expect(index(s.epk)?.syncCursor, '200:cccc');
        s.conn.dispose();
        s.sync.dispose();
      });

      test('an empty delta is a no-op that still advances the cursor',
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'hi')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync2',
            sessionStartedAt: 100,
            events: const [],
            eos: true,
            isDelta: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();
        expect(messages(s.epk).map((r) => r.text), ['hi']);
        expect(index(s.epk)?.syncCursor, '100:aaaa');
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a delta cannot collide with an existing thinking row id', () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [
              AgentThinkingEvt(ts: 10, inReplyTo: 'sync_10', text: 'one'),
            ],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync2',
            sessionStartedAt: 100,
            events: const [
              AgentThinkingEvt(ts: 10, inReplyTo: 'sync_10', text: 'two'),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        await _settle();
        // Same ts and role: only the seq offset keeps the ids apart.
        expect(messages(s.epk).map((r) => r.text), ['one', 'two']);
        s.conn.dispose();
        s.sync.dispose();
      });

      // The delta answers "everything after your cursor" — and the rows the app
      // rendered from LIVE frames after that cursor are part of the answer too.
      // Concatenating them blindly puts one message on screen twice: two bubbles
      // for one message, two cards for one screenshot.
      test('a delta that re-delivers rows the app wrote live does not duplicate '
          'them', () async {
        final s = await setup();
        // Baseline replay, so the device holds a cursor to resume from.
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 10, id: 'sync_10', text: 'first'),
              AgentMessageEvt(ts: 11, inReplyTo: 'sync_10', text: 'answer'),
            ],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        // Live turn: the user sends, the Pi echoes, a tool reads an image.
        await s.sync.sendMessage('run it');
        final localId = s.ch.sent.whereType<UserMessage>().last.id;
        s.ch.push(UserInput(id: localId, text: 'run it'));
        s.ch.push(ToolRequest(toolCallId: 'tc1', tool: 'read', args: const {}));
        s.ch.push(
          FileOffer(
            id: 'att_tc1',
            name: 'shot.png',
            path: '/tmp/shot.png',
            mime: 'image/png',
            size: 3,
            data: _squarePng,
            toolCallId: 'tc1',
          ),
        );
        final live = await rowsWhen(
          s.epk,
          (rows) => rows.any((r) => r.role == MsgRole.attachment),
        );
        expect(live.map((r) => r.role), [
          MsgRole.user,
          MsgRole.assistant,
          MsgRole.user,
          MsgRole.tool,
          MsgRole.attachment,
        ]);

        // Reconnect: the Pi replays that same tail from its session file.
        final reply = askForSync(s.ch, s.sync);
        s.ch.push(
          SessionHistory(
            inReplyTo: reply,
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 20, id: 'sync_20', text: 'run it'),
              ToolRequestEvt(
                ts: 21,
                toolCallId: 'tc1',
                tool: 'read',
                args: null,
              ),
              ToolResultEvt(ts: 22, toolCallId: 'tc1', result: 'ok'),
              AttachmentEvt(
                ts: 23,
                id: 'att_tc1',
                name: 'shot.png',
                path: '/tmp/shot.png',
                mime: 'image/png',
                size: 3,
                toolCallId: 'tc1',
              ),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        final replayed = await rowsWhen(
          s.epk,
          (rows) => rows.any((r) => r.id == 'sync_20') && rows.length == 5,
        );
        expect(
          replayed.any((r) => r.id == localId),
          isFalse,
          reason: 'the live row is replaced, not kept next to its replay',
        );
        expect(replayed.map((r) => r.role), [
          MsgRole.user,
          MsgRole.assistant,
          MsgRole.user,
          MsgRole.tool,
          MsgRole.attachment,
        ], reason: 'the replay replaces the live rows it re-delivers');
        expect(
          replayed.where((r) => r.role == MsgRole.attachment),
          hasLength(1),
          reason: 'one card per image, not one per delivery',
        );
        expect(
          replayed.last.attachment!.blobName,
          isNotNull,
          reason: 'the replay is metadata-only: the card keeps the cached bytes',
        );
        s.conn.dispose();
        s.sync.dispose();
      });

      test(
        'a pending bubble the delta does not cover is still preserved',
        () async {
          final s = await setup();
          s.ch.push(
            SessionHistory(
              inReplyTo: 'sync1',
              sessionStartedAt: 100,
              events: const [
                UserInputEvt(ts: 10, id: 'sync_10', text: 'first'),
              ],
              eos: true,
              cursor: '100:aaaa',
            ),
          );
          await _settle();

          // Sent, but the Pi has not echoed it yet: the row is optimistic only.
          await s.sync.sendMessage('not echoed yet');
          await _settle();

          s.ch.push(
            SessionHistory(
              inReplyTo: 'sync2',
              sessionStartedAt: 100,
              events: const [
                AgentMessageEvt(ts: 11, inReplyTo: 'sync_10', text: 'ok'),
              ],
              eos: true,
              isDelta: true,
              cursor: '100:bbbb',
            ),
          );
          await _settle();
          expect(messages(s.epk).map((r) => r.text), [
            'first',
            'ok',
            'not echoed yet',
          ]);
          expect(messages(s.epk).last.pending, isTrue);
          s.conn.dispose();
          s.sync.dispose();
        },
      );

      test(
        'a cache from before the frontier existed asks for a full replay once',
        () async {
          final s = await setup();
          s.ch.push(
            SessionHistory(
              inReplyTo: 'sync1',
              sessionStartedAt: 100,
              events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'hi')],
              eos: true,
              cursor: '100:aaaa',
            ),
          );
          // The index write rides the same queue as the rows: wait for it to
          // land, or the patch below would be overwritten by it.
          await waitUntil(() => index(s.epk)?.syncCursor == '100:aaaa');
          // Simulate an index written by a build without `synced_rows`.
          final idx = LocalBoxes().sessionsIndexBox();
          final key = '${s.epk}:main';
          final stored = (idx.get(key) as Map).cast<String, dynamic>()
            ..remove('synced_rows');
          await idx.put(key, stored);

          // Re-entering the room re-reads the index: with no frontier the delta
          // cannot tell provisional rows apart, so it must ask for everything.
          await s.sync.activate(s.epk, 'other');
          await _settle();
          await s.sync.activate(s.epk, 'main');
          await _settle();
          s.ch.sent.clear();
          s.sync.requestSync();
          await _settle();
          expect(s.ch.sent.whereType<SessionSync>().single.since, isNull);
          s.conn.dispose();
          s.sync.dispose();
        },
      );

      test('the frontier is persisted, so re-entering the room keeps the cursor',
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 10, id: 'sync_10', text: 'first'),
              AgentMessageEvt(ts: 11, inReplyTo: 'sync_10', text: 'answer'),
            ],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await waitUntil(() => index(s.epk)?.syncedRows == 2);
        // Without this the app silently degrades to a full replay on every entry
        // and every cold start — the exact cost the delta was built to remove.
        expect(index(s.epk)?.syncedRows, 2);

        await s.sync.activate(s.epk, 'other');
        await _settle();
        await s.sync.activate(s.epk, 'main');
        await _settle();
        s.ch.sent.clear();
        s.sync.requestSync();
        await _settle();
        expect(s.ch.sent.whereType<SessionSync>().single.since, '100:aaaa');
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a delta that repeats events the device already applied is idempotent',
          () async {
        final s = await setup();
        // Two `session_sync` requests can be in flight at once (room entry +
        // online edge): the second reply repeats what the first one wrote.
        SessionHistory delta(String cursor) => SessionHistory(
          inReplyTo: 'sync-$cursor',
          sessionStartedAt: 100,
          events: const [
            UserInputEvt(ts: 20, id: 'sync_20', text: 'again'),
            AgentThinkingEvt(ts: 21, inReplyTo: 'sync_20', text: 'hmm'),
            ToolRequestEvt(ts: 22, toolCallId: 'tc1', tool: 'read', args: null),
            AttachmentEvt(
              ts: 23,
              id: 'att_tc1',
              name: 'shot.png',
              path: '/tmp/shot.png',
              mime: 'image/png',
              size: 3,
              toolCallId: 'tc1',
            ),
          ],
          eos: true,
          isDelta: true,
          cursor: cursor,
        );
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'first')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();
        s.ch.push(delta('100:bbbb'));
        await rowsWhen(s.epk, (rows) => rows.length == 5);
        s.ch.push(delta('100:cccc'));
        final rows = await rowsWhen(s.epk, (_) => false);
        expect(rows.map((r) => r.text), ['first', 'again', 'hmm', '', '']);
        expect(rows.map((r) => r.role), [
          MsgRole.user,
          MsgRole.user,
          MsgRole.thinking,
          MsgRole.tool,
          MsgRole.attachment,
        ]);
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a delta replay that arrives byte-less keeps the live row\'s picture',
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'first')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        // The phone sends a picture; the Pi echoes it (the row is confirmed,
        // live-written, and holds this device's only copy of the bytes).
        await s.sync.sendMessage(
          'look',
          images: const [
            MessageImage(data: _squarePng, mime: 'image/png'),
          ],
        );
        final localId = s.ch.sent.whereType<UserMessage>().last.id;
        s.ch.push(UserInput(id: localId, text: 'look'));
        final live = await rowsWhen(
          s.epk,
          (rows) => rows.any((r) => r.images.isNotEmpty),
        );
        expect(live.where((r) => r.text == 'look').single.images, hasLength(1));

        // The replay comes back without the payload (session file cleaned, or the
        // bytes fell out of the budget) and under the Pi's own id: the archived
        // picture must survive the replacement, not vanish with the live row.
        final reply = askForSync(s.ch, s.sync);
        s.ch.push(
          SessionHistory(
            inReplyTo: reply,
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 20, id: 'sync_20', text: 'look'),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        final after = await rowsWhen(
          s.epk,
          (rows) => rows.any((r) => r.id == 'sync_20'),
        );
        final text = after.where((r) => r.text == 'look').single;
        expect(after.where((r) => r.text == 'look'), hasLength(1));
        expect(text.images, hasLength(1));
        expect(text.images.single.blob, isNotNull);
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a reply that carries the same attachment event twice writes one card',
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [
              ToolRequestEvt(ts: 10, toolCallId: 'tc1', tool: 'read', args: null),
              AttachmentEvt(
                ts: 11,
                id: 'att_tc1',
                name: 'shot.png',
                path: '/tmp/shot.png',
                mime: 'image/png',
                size: 3,
                toolCallId: 'tc1',
              ),
              AttachmentEvt(
                ts: 11,
                id: 'att_tc1',
                name: 'shot.png',
                path: '/tmp/shot.png',
                mime: 'image/png',
                size: 3,
                toolCallId: 'tc1',
              ),
            ],
            eos: true,
          ),
        );
        final rows = await rowsWhen(
          s.epk,
          (rows) => rows.any((r) => r.role == MsgRole.attachment),
        );
        expect(rows.where((r) => r.role == MsgRole.attachment), hasLength(1));
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a reply keeps the live rows it could not have seen', () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'first')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        // A picture goes out while the room is idle; the Pi echoes it, so the
        // row is confirmed and holds this device's only copy of the bytes.
        await s.sync.sendMessage(
          'look',
          images: const [MessageImage(data: _squarePng, mime: 'image/png')],
        );
        final localId = s.ch.sent.whereType<UserMessage>().last.id;
        s.ch.push(UserInput(id: localId, text: 'look'));
        await rowsWhen(s.epk, (rows) => rows.any((r) => r.images.isNotEmpty));

        // A sync asked for BEFORE the send answers with nothing this device has
        // not already applied. The reply must not take the row with it: its own
        // cursor points past the picture, so nothing would ever re-deliver it.
        final reply = askForSync(s.ch, s.sync);
        s.ch.push(
          SessionHistory(
            inReplyTo: reply,
            sessionStartedAt: 100,
            events: const [],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        await waitUntil(() => index(s.epk)?.syncCursor == '100:bbbb');
        final rows = messages(s.epk);
        expect(rows.where((r) => r.text == 'look'), hasLength(1));
        expect(rows.where((r) => r.text == 'look').single.images, hasLength(1));
        expect(rows.where((r) => r.text == 'look').single.pending, isFalse);
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a replay pairs a repeated text with its own picture', () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'first')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        // Two messages with the same text, only the first carrying a picture.
        await s.sync.sendMessage(
          'shot',
          images: const [MessageImage(data: _squarePng, mime: 'image/png')],
        );
        final firstId = s.ch.sent.whereType<UserMessage>().last.id;
        s.ch.push(UserInput(id: firstId, text: 'shot'));
        await rowsWhen(s.epk, (rows) => rows.any((r) => r.images.isNotEmpty));
        await s.sync.sendMessage('shot');
        final secondId = s.ch.sent.whereType<UserMessage>().last.id;
        s.ch.push(UserInput(id: secondId, text: 'shot'));
        await rowsWhen(s.epk, (rows) => rows.where((r) => r.text == 'shot').length == 2);

        // Both come back byte-less; the picture belongs to the first one.
        final reply = askForSync(s.ch, s.sync);
        s.ch.push(
          SessionHistory(
            inReplyTo: reply,
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 20, id: 'sync_20', text: 'shot'),
              UserInputEvt(ts: 21, id: 'sync_21', text: 'shot'),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        final rows = await rowsWhen(
          s.epk,
          (rows) => rows.where((r) => r.text == 'shot').length == 2 &&
              rows.any((r) => r.id == 'sync_21'),
        );
        final shots = rows.where((r) => r.text == 'shot').toList();
        expect(shots.first.images, hasLength(1));
        expect(shots.first.images.single.blob, isNotNull);
        expect(shots.last.images, isEmpty);
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a reply that brings more of a text than the buffer held does not '
          'guess at a picture', () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'first')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        // One picture with the text, live.
        await s.sync.sendMessage(
          'shot',
          images: const [MessageImage(data: _squarePng, mime: 'image/png')],
        );
        final localId = s.ch.sent.whereType<UserMessage>().last.id;
        s.ch.push(UserInput(id: localId, text: 'shot'));
        await rowsWhen(s.epk, (rows) => rows.any((r) => r.images.isNotEmpty));

        // The reply brings TWO of that text (one was written while this device
        // was away) and neither carries bytes: there is no way to tell which
        // message the picture belongs to, so guessing would put it on the wrong
        // bubble — the picture is left off this round instead.
        final reply = askForSync(s.ch, s.sync);
        s.ch.push(
          SessionHistory(
            inReplyTo: reply,
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 20, id: 'sync_20', text: 'shot'),
              UserInputEvt(ts: 21, id: 'sync_21', text: 'shot'),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        final rows = await rowsWhen(
          s.epk,
          (rows) => rows.where((r) => r.text == 'shot').length == 2,
        );
        expect(rows.where((r) => r.text == 'shot'), hasLength(2));
        expect(
          rows.any((r) => r.images.isNotEmpty),
          isFalse,
          reason: 'a picture is never attached to a message it may not belong to',
        );
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a picture survives when the room already had a message with the '
          'same text', () async {
        final s = await setup();
        // The history already holds a message with this very text — the count of
        // that text is not "one" when this reply lands.
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 5, id: 'sync_5', text: 'look'),
              AgentMessageEvt(ts: 6, inReplyTo: 'sync_5', text: 'seen'),
            ],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        await s.sync.sendMessage(
          'look',
          images: const [MessageImage(data: _squarePng, mime: 'image/png')],
        );
        final localId = s.ch.sent.whereType<UserMessage>().last.id;
        s.ch.push(UserInput(id: localId, text: 'look'));
        await rowsWhen(s.epk, (rows) => rows.any((r) => r.images.isNotEmpty));

        final reply = askForSync(s.ch, s.sync);
        s.ch.push(
          SessionHistory(
            inReplyTo: reply,
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 20, id: 'sync_20', text: 'look')],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        final rows = await rowsWhen(
          s.epk,
          (rows) => rows.any((r) => r.id == 'sync_20'),
        );
        final replay = rows.firstWhere((r) => r.id == 'sync_20');
        expect(
          replay.images,
          hasLength(1),
          reason: 'the picture the phone archives is the only copy there is',
        );
        expect(replay.images.single.blob, isNotNull);
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a reply that answers a still-pending bubble leaves one bubble',
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'first')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        // Sent, but the echo never arrived (the connection blinked): the row
        // stays pending and the re-sync is what reports it instead.
        await s.sync.sendMessage('still pending');
        await _settle();

        final reply = askForSync(s.ch, s.sync);
        s.ch.push(
          SessionHistory(
            inReplyTo: reply,
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 20, id: 'sync_20', text: 'still pending'),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        final rows = await rowsWhen(
          s.epk,
          (rows) => rows.any((r) => r.id == 'sync_20'),
        );
        expect(
          rows.where((r) => r.text == 'still pending'),
          hasLength(1),
          reason: 'the answered bubble is replaced, not kept as a second copy',
        );
        expect(rows.where((r) => r.text == 'still pending').single.pending,
            isFalse);
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a row written while the reply was in flight is matched, not doubled',
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'first')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        // Ask first, then write: the row is younger than the request, yet the Pi
        // had already persisted it when it built the reply. (The gap keeps the
        // row's millisecond timestamp strictly after the request's.)
        final reply = askForSync(s.ch, s.sync);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await s.sync.sendMessage('written after the ask');
        final localId = s.ch.sent.whereType<UserMessage>().last.id;
        s.ch.push(UserInput(id: localId, text: 'written after the ask'));
        await _settle();

        s.ch.push(
          SessionHistory(
            inReplyTo: reply,
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 20, id: 'sync_20', text: 'written after the ask'),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        final rows = await rowsWhen(
          s.epk,
          (rows) => rows.any((r) => r.id == 'sync_20'),
        );
        expect(rows.where((r) => r.text == 'written after the ask'),
            hasLength(1));
        s.conn.dispose();
        s.sync.dispose();
      });

      test("a result replayed over a live card keeps the tool's name",
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'first')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        // The call is live (the echo is pending here), the result comes back
        // through a reply that carries no tool name.
        s.ch.push(ToolRequest(toolCallId: 'tc1', tool: 'bash', args: const {}));
        await rowsWhen(s.epk, (rows) => rows.any((r) => r.role == MsgRole.tool));
        final reply = askForSync(s.ch, s.sync);
        s.ch.push(
          SessionHistory(
            inReplyTo: reply,
            sessionStartedAt: 100,
            events: const [
              ToolResultEvt(ts: 11, toolCallId: 'tc1', result: 'a.txt'),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        final rows = await rowsWhen(
          s.epk,
          (rows) =>
              rows.where((r) => r.role == MsgRole.tool).length == 1 &&
              rows.last.tool?.status == ToolEventStatus.completed,
        );
        expect(rows.where((r) => r.role == MsgRole.tool), hasLength(1));
        expect(rows.last.tool!.tool, 'bash');
        expect(rows.last.tool!.result, 'a.txt');
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a full replay keeps a bubble the Pi has not answered yet', () async {
        final s = await setup();
        // Sent while offline: nothing on the Pi knows about it yet.
        await s.sync.sendMessage('still mine');
        await _settle();
        expect(messages(s.epk).single.pending, isTrue);

        // A cold start (or a cursor the Pi could not place) answers with a full
        // replay, which substitutes everything it knows — and it knows nothing
        // about that bubble.
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'first')],
            eos: true,
          ),
        );
        await waitUntil(() => messages(s.epk).length == 2);
        final rows = messages(s.epk);
        expect(rows.map((r) => r.text), ['first', 'still mine']);
        expect(rows.last.pending, isTrue);
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a reasoning block the reply brings back is not shown twice',
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'first')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        // A live turn: the model reasons, then answers.
        s.ch.push(AgentThinking(inReplyTo: 'u1', delta: 'weighing it'));
        await _settle();
        s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'the answer'));
        await rowsWhen(s.epk, (rows) => rows.any((r) => r.role == MsgRole.thinking));

        final reply = askForSync(s.ch, s.sync);
        s.ch.push(
          SessionHistory(
            inReplyTo: reply,
            sessionStartedAt: 100,
            events: const [
              AgentThinkingEvt(ts: 20, inReplyTo: 'sync_20', text: 'weighing it'),
              AgentMessageEvt(ts: 21, inReplyTo: 'sync_20', text: 'the answer'),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        final rows = await rowsWhen(
          s.epk,
          (rows) => rows.any((r) => r.id == 'sync_20'),
        );
        expect(
          rows.where((r) => r.role == MsgRole.thinking),
          hasLength(1),
          reason: 'the replayed block stands in for the one on screen',
        );
        expect(rows.where((r) => r.text == 'the answer'), hasLength(1));
        s.conn.dispose();
        s.sync.dispose();
      });

      // The Pi caps a replayed reasoning block at 16 KiB and appends a marker,
      // so the copy it sends back is the live text's head FOLLOWED BY marker
      // text — never a prefix of what the app rendered. A plain prefix test
      // therefore never paired a long block, and the live row it left behind was
      // hung below the answer: the transcript ended on a thinking block.
      test('a reasoning block past the re-sync cap pairs with the live row',
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'first')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        final reasoning = 'x' * 20000;
        s.ch.push(AgentThinking(inReplyTo: 'u1', delta: reasoning));
        await _settle();
        s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'the answer'));
        s.ch.push(AgentDone(inReplyTo: 'u1'));
        await rowsWhen(
          s.epk,
          (rows) => rows.any((r) => r.role == MsgRole.assistant),
        );

        final reply = askForSync(s.ch, s.sync);
        s.ch.push(
          SessionHistory(
            inReplyTo: reply,
            sessionStartedAt: 100,
            events: [
              AgentThinkingEvt(
                ts: 20,
                inReplyTo: 'sync_20',
                text: '${reasoning.substring(0, 16384)}\n\n…[thinking truncated]',
              ),
              const AgentMessageEvt(
                ts: 21,
                inReplyTo: 'sync_20',
                text: 'the answer',
              ),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        await waitUntil(() => index(s.epk)?.syncCursor == '100:bbbb');
        final rows = messages(s.epk);
        expect(
          rows.where((r) => r.role == MsgRole.thinking),
          hasLength(1),
          reason: 'the capped copy stands in for the block on screen',
        );
        expect(
          rows.map((r) => r.role),
          [MsgRole.user, MsgRole.thinking, MsgRole.assistant],
          reason: 'reasoning still precedes the answer it produced',
        );
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a live row the reply does not bring back keeps its place',
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [UserInputEvt(ts: 10, id: 'sync_10', text: 'first')],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        s.ch.push(AgentThinking(inReplyTo: 'u1', delta: 'weighing it'));
        await _settle();
        s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'the answer'));
        s.ch.push(AgentDone(inReplyTo: 'u1'));
        await rowsWhen(
          s.epk,
          (rows) => rows.any((r) => r.role == MsgRole.assistant),
        );

        // The reply brings the answer but NOT the reasoning that preceded it
        // (the Pi had not written that event when it answered).
        final reply = askForSync(s.ch, s.sync);
        s.ch.push(
          SessionHistory(
            inReplyTo: reply,
            sessionStartedAt: 100,
            events: const [
              AgentMessageEvt(ts: 21, inReplyTo: 'sync_20', text: 'the answer'),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        await waitUntil(() => index(s.epk)?.syncCursor == '100:bbbb');
        final rows = messages(s.epk);
        expect(
          rows.map((r) => r.role),
          [MsgRole.user, MsgRole.thinking, MsgRole.assistant],
          reason: 'an unpaired row cannot jump over the row that followed it',
        );
        expect(rows.where((r) => r.text == 'the answer'), hasLength(1));
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a frontier the box cannot back up asks for a full replay', () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 10, id: 'sync_10', text: 'first'),
              AgentMessageEvt(ts: 11, inReplyTo: 'sync_10', text: 'answer'),
            ],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await waitUntil(() => index(s.epk)?.syncedRows == 2);
        // Rows are gone (a half-done wipe): the frontier no longer describes the
        // box, so a delta on top of it would leave holes.
        final idx = LocalBoxes().sessionsIndexBox();
        final key = '${s.epk}:main';
        final stored = (idx.get(key) as Map).cast<String, dynamic>()
          ..['synced_rows'] = 9;
        await idx.put(key, stored);

        await s.sync.activate(s.epk, 'other');
        await _settle();
        await s.sync.activate(s.epk, 'main');
        await _settle();
        s.ch.sent.clear();
        s.sync.requestSync();
        await _settle();
        expect(s.ch.sent.whereType<SessionSync>().single.since, isNull);
        s.conn.dispose();
        s.sync.dispose();
      });

      test('a sync that splits a tool call from its result keeps one card',
          () async {
        final s = await setup();
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync1',
            sessionStartedAt: 100,
            events: const [
              UserInputEvt(ts: 10, id: 'sync_10', text: 'list it'),
              ToolRequestEvt(
                ts: 11,
                toolCallId: 'tc1',
                tool: 'bash',
                args: null,
              ),
            ],
            eos: true,
            cursor: '100:aaaa',
          ),
        );
        await _settle();

        // The reconnect's cursor lands between the call and its result: the delta
        // only carries the result, which knows no tool name.
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync2',
            sessionStartedAt: 100,
            events: const [
              ToolResultEvt(ts: 12, toolCallId: 'tc1', result: 'a.txt'),
            ],
            eos: true,
            isDelta: true,
            cursor: '100:bbbb',
          ),
        );
        final rows = await rowsWhen(
          s.epk,
          (rows) => rows.where((r) => r.role == MsgRole.tool).length == 1 &&
              rows.last.tool?.status == ToolEventStatus.completed,
        );
        expect(rows.where((r) => r.role == MsgRole.tool), hasLength(1),
            reason: 'the result replaces the card instead of adding a second one');
        expect(rows.last.tool!.tool, 'bash', reason: 'the name the card showed');
        expect(rows.last.tool!.result, 'a.txt');
        s.conn.dispose();
        s.sync.dispose();
      });
    });
  });
}
