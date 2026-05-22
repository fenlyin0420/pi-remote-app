import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter/foundation.dart' show listEquals, mapEquals;

sealed class HomeState {
  const HomeState();
}

class HomeLoading extends HomeState {
  const HomeLoading();
}

class HomeNoPeer extends HomeState {
  const HomeNoPeer();
}

/// Plan 17 — single row on Home: a Pi room (per-cwd session) bound to
/// a paired Mac. Multiple HomeItems per peer when the Mac runs more
/// than one Pi session. When `roomId == 'main'` (the only room from a
/// legacy/single-cwd Pi), the UI may collapse the cwd subtitle.
class HomeItem {
  final PeerRecord peer;
  final RoomInfo room;

  const HomeItem({required this.peer, required this.room});

  /// Display name preference: explicit room.name → cwd basename →
  /// `<peer-nickname>` → fallback session_name.
  String get displayName {
    if (room.name != null && room.name!.isNotEmpty) return room.name!;
    final cwd = room.cwd;
    if (cwd != null && cwd.isNotEmpty) {
      final last = cwd.split('/').where((s) => s.isNotEmpty).toList();
      if (last.isNotEmpty) return last.last;
    }
    if (peer.nickname != null && peer.nickname!.isNotEmpty) {
      return peer.nickname!;
    }
    return peer.sessionName;
  }

  @override
  bool operator ==(Object other) =>
      other is HomeItem &&
      other.peer.remoteEpk == peer.remoteEpk &&
      other.room == room;

  @override
  int get hashCode => Object.hash(peer.remoteEpk, room);
}

/// Paired peers + their live rooms + presence. Items are derived from
/// `roomsByPeer`: a peer with no announced rooms yet still gets one
/// synthetic item (`roomId='main'`) so the user can enter chat — that
/// covers legacy Pis and the pre-room-announce window after reconnect.
class HomeList extends HomeState {
  final List<PeerRecord> peers;
  final Map<String, PresenceState> statusByEpk;
  final Map<String, List<RoomInfo>> roomsByPeer;

  const HomeList({
    required this.peers,
    this.statusByEpk = const {},
    this.roomsByPeer = const {},
  });

  HomeList copyWith({
    List<PeerRecord>? peers,
    Map<String, PresenceState>? statusByEpk,
    Map<String, List<RoomInfo>>? roomsByPeer,
  }) =>
      HomeList(
        peers: peers ?? this.peers,
        statusByEpk: statusByEpk ?? this.statusByEpk,
        roomsByPeer: roomsByPeer ?? this.roomsByPeer,
      );

  /// Flatten to a single ordered list of items: one row per (peer, room).
  /// **Plan-17 follow-up**: peers without any currently-announced rooms
  /// produce ZERO items. Earlier behaviour created a synthetic 'main'
  /// tile for legacy compatibility, but that tile pointed at a (peer,
  /// 'main') destination the Pi was no longer listening on — sending
  /// there got dropped by the relay AND the row felt like a ghost. The
  /// user only wants live rooms in the list.
  List<HomeItem> items({String Function(String)? normalizeEpk}) {
    final out = <HomeItem>[];
    for (final p in peers) {
      final key = normalizeEpk != null
          ? normalizeEpk(p.remoteEpk)
          : p.remoteEpk;
      final rooms = roomsByPeer[key];
      if (rooms == null || rooms.isEmpty) continue;
      for (final r in rooms) {
        out.add(HomeItem(peer: p, room: r));
      }
    }
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is HomeList &&
      listEquals(other.peers, peers) &&
      mapEquals(other.statusByEpk, statusByEpk) &&
      mapEquals(other.roomsByPeer, roomsByPeer);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(peers),
        Object.hashAllUnordered(
          statusByEpk.entries.map((e) => '${e.key}:${e.value.runtimeType}'),
        ),
        Object.hashAllUnordered(
          roomsByPeer.entries.map((e) => '${e.key}:${e.value.length}'),
        ),
      );
}
