import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/storage.dart';

/// Points the app at a session: `(peer, room)`.
///
/// Opening a session in this app is not just navigation — it has three
/// side effects that must happen in this order, and skipping any of them leaves
/// the chat silently bound to the wrong place:
///
///  1. Persist the choice, room included (`/chat` reads it on mount).
///  2. Write the room onto the `PeerRecord`, otherwise the next cold start
///     falls back to room `main` and the Pi never sees the frame.
///  3. Retarget the live connection so outbound frames address that room.
///
/// Shared by the Home tap and by tapping a notification, so a session opened
/// from a banner is bound exactly like one opened by hand. A peer that is no
/// longer stored is a silent no-op — the caller cannot open what is gone.
Future<void> retargetSession({
  required PairingStorage storage,
  required Preferences prefs,
  required ConnectionManager conn,
  required String epk,
  String? roomId,
}) async {
  final peers = await storage.listPeers();
  // The handle in a notification payload comes off the wire, where the pairing
  // QR's base64url spelling is also in play; storage is keyed by base64
  // standard (see `epk_encoding.dart`). Compare canonically, then keep the
  // STORED handle as the selected peer — everything downstream loads the peer
  // by that spelling.
  final canonical = toStandardB64(epk);
  final match = peers
      .where((p) => toStandardB64(p.remoteEpk) == canonical)
      .cast<PeerRecord?>();
  if (match.isEmpty) return;
  final peer = match.first!;
  final storedEpk = peer.remoteEpk;
  // A payload without a room (older notification payloads, a session that
  // was never room-bound) must NOT fall back to the literal `main`: no Pi
  // daemon is registered under that room, so the relay drops every outbound
  // frame — `dest (peer, room) not found` — while the app still shows
  // "online". Persisting it is worse: `_connect` then re-binds the peer to
  // `main` on every reconnect and the session stays dead until the user
  // picks a room by hand. Keep whatever room the peer already knows; when it
  // knows none, leave the live selection alone and let room discovery bind
  // it (`ConnectionManager._maybeAdoptLegacyRoom`).
  final requested = (roomId == null || roomId.isEmpty) ? null : roomId;
  final effectiveRoom = requested ?? peer.roomId;
  if (effectiveRoom == null || effectiveRoom.isEmpty) {
    // No room to bind: still select the peer (that is what "open this
    // session" means here), but leave the routing room untouched — the peer
    // record keeps its own value and the live connection keeps addressing
    // whatever real room discovery already bound it to.
    await prefs.setSelectedRoom(epk: storedEpk);
    return;
  }
  await prefs.setSelectedRoom(epk: storedEpk, roomId: effectiveRoom);
  if (peer.roomId != effectiveRoom) {
    // ignore: unawaited_futures
    storage.savePeer(peer.copyWith(roomId: effectiveRoom));
  }
  // Safe to call even if the manager is mid-connect: the room is applied on the
  // next send and to any active StatusOnline channel.
  conn.switchRoom(effectiveRoom);
}
