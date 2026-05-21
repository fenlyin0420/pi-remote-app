import 'dart:async';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/i_session_repository.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// ChatViewModel — owns the chat connection lifecycle.
///
/// Connection rule (after plano 12): the WS is opened by the
/// ConnectionManager at app boot and stays alive across navigation. Chat
/// observes the existing connection and asks the manager to switch the
/// "active peer" when it mounts. Presence (relay-driven) drives the
/// banner / input state independently of the WS-to-relay status.
class ChatViewModel extends ViewModel<ChatState> {
  final ISessionRepository _repo;
  final Preferences _prefs;
  final PairingStorage _storage;
  StreamSubscription? _sub;
  StreamSubscription? _eventSub;
  StreamSubscription<Map<String, PresenceState>>? _presenceSub;
  bool _pairingRevoked = false;
  String? _peerOfflineReason;
  PeerRecord? _activePeer;
  PresenceState _peerPresence = const PresenceUnknown();
  bool _bootstrapping = true;
  bool _disposed = false;

  ChatViewModel(this._repo, this._prefs, this._storage)
    : super(const ChatConnecting()) {
    _sub = _repo.sessionStream.listen(_onSession);
    _eventSub = _repo.eventStream.listen(_onEvent);
    _presenceSub = _repo.presenceStream.listen(_onPresence);
    // ignore: unawaited_futures
    _bootstrap();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _bootstrap() async {
    final epk = _prefs.selectedPeerEpk;
    if (epk == null) {
      debugPrint('[chat-state] bootstrap: no selectedPeerEpk → ChatNoPeer');
      _bootstrapping = false;
      emit(const ChatNoPeer());
      return;
    }
    final peer = await _storage.loadPeer(epk);
    if (_disposed) return;
    if (peer == null) {
      debugPrint('[chat-state] bootstrap: selectedPeerEpk=$epk not in storage');
      _bootstrapping = false;
      emit(const ChatNoPeer());
      return;
    }
    _activePeer = peer;
    _peerPresence = _repo.presenceFor(peer.remoteEpk);
    debugPrint(
      '[chat-state] bootstrap: peer=${peer.remoteEpk} '
      'presence=${_peerPresence.runtimeType}',
    );

    // Always load the per-peer history cache (plano 11) so the chat
    // surface has content even if the WS hasn't authenticated yet.
    await _repo.setActivePeer(peer);
    if (_disposed) return;

    // Plano 13 fast path: if the connection layer already settled on
    // this exact peer (boot opened it OR Home triggered switchTo before
    // navigating), don't ask for another openSession — that would just
    // be a no-op AND skip the event chain we'd otherwise rely on. Seed
    // the chat state synchronously from `_repo.current` and we're done.
    final cur = _repo.activePeer;
    final alreadyDriving = cur?.remoteEpk == peer.remoteEpk;
    if (!alreadyDriving) {
      debugPrint('[chat-state] bootstrap: openSession (peer switch needed)');
      await _repo.openSession(peer);
      if (_disposed) return;
    } else {
      debugPrint('[chat-state] bootstrap: already driving target peer');
    }

    // Seed from the repo's current snapshot so the view leaves
    // `ChatConnecting` immediately — even when `openSession` was a
    // no-op (no stream events to wait for).
    _onSession(_repo.current);

    // Plano 11 normally fires session_sync from `_onlineActivated` on
    // a StatusOnline transition. With no transition (fast-path or
    // idempotent openSession), there is none — kick a one-shot sync.
    _repo.requestSync();
  }

  // ---------------------------------------------------------------------------
  // Actions — called from UI
  // ---------------------------------------------------------------------------

  Future<void> sendMessage(String text) {
    debugPrint(
      '[chat-state] ChatViewModel.sendMessage text.len=${text.length}',
    );
    return _repo.sendMessage(text);
  }

  Future<void> cancel(String targetId) => _repo.cancel(targetId);

  Future<void> approveTool(String toolCallId, ApproveDecision decision) =>
      _repo.approveTool(toolCallId, decision);

  /// Called from the offline (bye) banner. Clears the sticky `bye` flag
  /// and asks the repo to open the session again.
  Future<void> reconnect() async {
    final peer = _activePeer;
    if (peer == null) return;
    debugPrint('[chat-state] manual reconnect epk=${peer.remoteEpk}');
    _peerOfflineReason = null;
    _bootstrapping = true;
    emit(const ChatConnecting());
    await _repo.openSession(peer);
  }

  // ---------------------------------------------------------------------------
  // Session → ChatState translation
  // ---------------------------------------------------------------------------

  void _onSession(SessionState s) {
    final cur = state;
    final wasStreaming =
        cur is ChatReady && cur.streaming != null;
    final isStreaming = s.streaming != null;
    if (wasStreaming != isStreaming) {
      debugPrint(
        '[chat-state] ChatViewModel streaming transition: '
        '$wasStreaming → $isStreaming '
        '(in_reply_to=${s.streaming?.inReplyTo ?? "—"})',
      );
    }
    if (_bootstrapping && s.connection is! StatusNoPeer) {
      _bootstrapping = false;
    }
    final next = _toChat(
      s,
      _pairingRevoked,
      _peerOfflineReason,
      _peerPresence,
      _bootstrapping,
    );
    debugPrint(
      '[chat-state] _onSession emit: '
      '${next.runtimeType} (conn=${s.connection.runtimeType} '
      'msgs=${s.messages.length} streaming=${s.streaming != null} '
      'bootstrapping=$_bootstrapping)',
    );
    emit(next);
  }

  void _onEvent(SessionEvent e) {
    if (e is PairingRevoked) {
      _pairingRevoked = true;
      emit(_toChat(
        _repo.current,
        true,
        _peerOfflineReason,
        _peerPresence,
        _bootstrapping,
      ));
    } else if (e is PeerWentOffline) {
      _peerOfflineReason = e.rawReason;
      emit(_toChat(
        _repo.current,
        _pairingRevoked,
        e.rawReason,
        _peerPresence,
        _bootstrapping,
      ));
    }
  }

  void _onPresence(Map<String, PresenceState> _) {
    final epk = _activePeer?.remoteEpk;
    if (epk == null) return;
    // `_repo.presenceFor` already normalises the epk to match the
    // relay-registry encoding (standard base64) — don't index the
    // snapshot directly with the url-safe storage key.
    final next = _repo.presenceFor(epk);
    if (next.runtimeType == _peerPresence.runtimeType) return;
    final prev = _peerPresence;
    debugPrint(
      '[chat-state] presence for active peer: '
      '${prev.runtimeType} → ${next.runtimeType}',
    );
    _peerPresence = next;

    // Auto-recovery: if Pi just came back from an offline state
    // (whether marked via Bye `peer_offline` banner or via relay
    // presence flipping), clear the sticky banner AND pull any new
    // history that may have accumulated while we couldn't reach it.
    // This is what the user expected when they said: "quando o Pi
    // voltar, tem que enviar o evento pra saber se tem novas
    // mensagens tb".
    final cameBackOnline = next is PresenceOnline &&
        (prev is PresenceOffline || _peerOfflineReason != null);
    if (cameBackOnline) {
      if (_peerOfflineReason != null) {
        debugPrint(
          '[chat-state] Pi back online → clearing offlineReason banner',
        );
        _peerOfflineReason = null;
      }
      debugPrint('[chat-state] Pi back online → triggering requestSync');
      _repo.requestSync();
    }

    emit(_toChat(
      _repo.current,
      _pairingRevoked,
      _peerOfflineReason,
      next,
      _bootstrapping,
    ));
  }

  static ChatState _toChat(
    SessionState s,
    bool revoked,
    String? offlineReason,
    PresenceState peerPresence,
    bool bootstrapping,
  ) {
    final conn = s.connection;

    // Fingerprint mismatch / non-recoverable offline — short-circuit
    // before any content-based fallback so the user sees the re-pair
    // affordance even if there's stale cache lying around.
    if (conn is StatusOffline && !conn.canRetry) {
      return ChatFatalError(conn.reason);
    }

    // Content-first: if we have history (cached or live) OR are mid-
    // stream, always render the chat surface. The connection state only
    // drives the AppBar status line + input disable, never blocks the
    // history from being visible.
    final hasContent = s.messages.isNotEmpty || s.streaming != null;
    if (hasContent) {
      return ChatReady(
        messages: s.messages,
        streaming: s.streaming,
        isOffline: conn is! StatusOnline,
        pairingRevoked: revoked,
        peerOfflineReason: offlineReason,
        peerPresence: peerPresence,
      );
    }

    // No content yet — surface the lifecycle state as before.
    return switch (conn) {
      StatusNoPeer() when bootstrapping => const ChatConnecting(),
      StatusNoPeer() when offlineReason != null => ChatReady(
        messages: const [],
        pairingRevoked: revoked,
        peerOfflineReason: offlineReason,
        peerPresence: peerPresence,
      ),
      StatusNoPeer() => const ChatNoPeer(),
      StatusConnecting() => const ChatConnecting(),
      StatusOnline() => ChatReady(
        messages: const [],
        pairingRevoked: revoked,
        peerOfflineReason: offlineReason,
        peerPresence: peerPresence,
      ),
      StatusRetrying() => ChatReady(
        messages: const [],
        isOffline: true,
        pairingRevoked: revoked,
        peerOfflineReason: offlineReason,
        peerPresence: peerPresence,
      ),
      // Recoverable offline — show the chat surface with the
      // reconnecting banner instead of swallowing into ChatConnecting.
      StatusOffline() => ChatReady(
        messages: const [],
        isOffline: true,
        pairingRevoked: revoked,
        peerOfflineReason: offlineReason,
        peerPresence: peerPresence,
      ),
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _eventSub?.cancel();
    _presenceSub?.cancel();
    // Connection persists from boot (plano 12). Chat is passive.
    super.dispose();
  }
}
