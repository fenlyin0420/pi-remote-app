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

/// Paired peers + their live presence (plano 12). `statusByEpk` is a
/// snapshot from [ConnectionManager.presenceStream]; missing entries mean
/// the relay hasn't reported on that peer yet ([PresenceUnknown]).
class HomeList extends HomeState {
  final List<PeerRecord> peers;
  final Map<String, PresenceState> statusByEpk;

  const HomeList({
    required this.peers,
    this.statusByEpk = const {},
  });

  HomeList copyWith({
    List<PeerRecord>? peers,
    Map<String, PresenceState>? statusByEpk,
  }) =>
      HomeList(
        peers: peers ?? this.peers,
        statusByEpk: statusByEpk ?? this.statusByEpk,
      );

  @override
  bool operator ==(Object other) =>
      other is HomeList &&
      listEquals(other.peers, peers) &&
      mapEquals(other.statusByEpk, statusByEpk);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(peers),
        Object.hashAllUnordered(statusByEpk.entries.map((e) => '${e.key}:${e.value.runtimeType}')),
      );
}
