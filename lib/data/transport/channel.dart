import 'dart:typed_data';

import 'package:app/protocol/protocol.dart';

/// Abstract channel — testable interface over [PlainPeerChannel].
abstract class IChannel {
  Stream<ServerMessage> get serverMessages;
  Future<void> send(ClientMessage msg);
  Future<void> close();
}

/// Optional capability mixed into a channel that also speaks raw relay
/// control frames (subscribe_presence, peer_online, etc — see plano 12).
/// ConnectionManager does an `is IControlLink` cast to drive presence;
/// channels that don't implement it simply skip the subsystem.
abstract class IControlLink {
  Stream<ControlInbound> get controlFrames;
  void sendControl(Map<String, dynamic> json);
}

/// Optional capability: send one inner message addressed to an explicit Pi
/// room instead of the connection's current active room.
///
/// The active room is a single mutable field ([ConnectionManager.switchRoom],
/// driven by chat pages, notification taps and session rides), and more than
/// one chat page can re-assert it, so it OSCILLATES. A frame sent to the room
/// the destination Pi is not registered under is dropped by the relay —
/// `dest (peer, room) not found` — with no error to the sender and no log on
/// the Pi, which is indistinguishable from a dead transport. Multi-second
/// transfers (chunked uploads) must therefore pin the room they started in.
abstract class IRoomScopedLink {
  Future<void> sendInRoom(String room, ClientMessage msg);
}

/// One inbound frame tagged with the Pi-side room that produced it.
///
/// The relay stamps every delivered envelope with the **sender's** room id, so
/// a frame arriving on this device always says which Pi session it came from.
/// Frames addressed to a room the app is not currently driving are not part of
/// the open chat and must never reach the session writer — but they are the
/// raw material for background notifications, which is why they are surfaced
/// instead of dropped.
class RoomFrame {
  final String roomId;
  final Uint8List payload;

  const RoomFrame({required this.roomId, required this.payload});
}

/// A decoded inbound message plus the session it belongs to. Emitted by
/// [ConnectionManager.roomMessages] for every room.
///
/// The **session writer** reads this stream and picks the target by the frame's
/// own [roomId]: frames of the (peer, room) it is bound to become the chat
/// transcript, every other room's frames only feed that room's in-memory state
/// and the **background notifier**, which decides whether a banner is warranted.
/// The room attribution has to come from the frame — the connection's addressed
/// room is one mutable field that several screens re-assert, so it drifts, and
/// a writer that trusted it wrote a stranger's frames into the open chat while
/// dropping the open chat's own.
///
/// [IChannel.serverMessages] remains the fallback for channels that cannot tag
/// frames (in-memory transports, test fakes); there everything necessarily
/// belongs to the bound room.
class RoomMessage {
  final String epk;
  final String roomId;
  final ServerMessage message;

  /// When this device received the frame (local clock). The Pi's own ordering
  /// is the arrival order at the relay; this is only for the receiver's own
  /// bookkeeping, e.g. recognising a burst from one room.
  final DateTime receivedAt;

  const RoomMessage({
    required this.epk,
    required this.roomId,
    required this.message,
    required this.receivedAt,
  });
}

/// Optional capability: a channel whose inbound frames can be observed together
/// with their originating room, including rooms the app is not addressing.
///
/// ConnectionManager casts to it and falls back to "no background traffic" for
/// channels that don't implement it (test fakes, in-memory transports).
abstract class IRoomFrameLink {
  Stream<RoomFrame> get roomFrames;
}
