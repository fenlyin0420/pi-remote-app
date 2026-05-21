import 'package:app/data/transport/channel.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';

/// Out-of-band signals that don't fit the conversational SessionState but
/// drive UI affordances (banners, redirects).
sealed class SessionEvent {
  const SessionEvent();
}

/// The Mac has dropped this device from its `peers.json` — the chat is
/// effectively dead and the user must re-pair.
class PairingRevoked extends SessionEvent {
  const PairingRevoked();
}

/// The Pi sent a `bye` and closed the channel gracefully. The retry loop
/// is stopped; the user must reconnect manually. `rawReason` is the wire
/// value (e.g. `peer_stop`, `session_replaced`, `shutdown`).
class PeerWentOffline extends SessionEvent {
  final String rawReason;
  const PeerWentOffline(this.rawReason);
}

/// Abstract session repository — injectable for tests.
abstract class ISessionRepository {
  SessionState get current;
  Stream<SessionState> get sessionStream;

  /// One-shot signals (revoke detected, etc) for the UI to react to.
  Stream<SessionEvent> get eventStream;

  Future<void> boot();
  Future<void> connectTo(PeerRecord peer);
  Future<void> sendMessage(String text);
  Future<void> cancel(String targetId);
  Future<void> approveTool(String toolCallId, ApproveDecision decision);
  void dispose();

  /// Transfer a live channel established by the pairing flow so the
  /// ConnectionManager can adopt it without going through the factory again.
  void adoptChannel(IChannel channel, PeerRecord peer);

  /// Close the active connection (if any). Used before re-pairing so the
  /// new pairing handshake does not collide in the relay's peer registry.
  Future<void> disconnect();

  /// Tell the repo which peer is now driving the session — loads its local
  /// history cache and emits it immediately. Called automatically when the
  /// underlying [ConnectionManager] transitions to `StatusOnline` with a new
  /// peer, but also exposed for tests.
  Future<void> setActivePeer(PeerRecord peer);

  /// Send a `session_sync` over the active channel asking the Pi to
  /// backfill anything newer than the locally-cached high-water mark.
  /// No-op when offline / no active peer.
  void requestSync();

  /// Idempotent: if already online to [peer], no-op; otherwise disconnects
  /// the current peer (if any) and connects to this one. Used by
  /// [ChatViewModel] on mount so the connection lifecycle follows the
  /// chat screen, not the home tap.
  Future<void> openSession(PeerRecord peer);

  /// Per-peer presence snapshot stream (forwarded from ConnectionManager).
  Stream<Map<String, PresenceState>> get presenceStream;

  /// Current presence for [epk] (defaults to [PresenceUnknown]).
  PresenceState presenceFor(String epk);

  /// Peer currently being driven by the connection layer, or null. Used
  /// by `ChatViewModel._bootstrap` to fast-path when the WS already
  /// matches the requested peer (plano 13).
  PeerRecord? get activePeer;
}
