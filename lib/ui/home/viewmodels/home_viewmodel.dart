import 'dart:async';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/home/states/home_state.dart';

/// HomeViewModel — passive list of paired peers + live presence dots.
///
/// The WS connection is owned by [ConnectionManager] from app boot (plano
/// 12). Home only:
///   - reads the peer list from storage
///   - watches `presenceStream` to render dots in real time
///   - writes [Preferences.selectedPeerEpk] when the user taps a tile so
///     `/chat` knows which peer to address
class HomeViewModel extends ViewModel<HomeState> {
  final PairingStorage _storage;
  final Preferences _prefs;
  final ConnectionManager _conn;
  StreamSubscription<Map<String, PresenceState>>? _presenceSub;
  bool _disposed = false;

  HomeViewModel(this._storage, this._prefs, this._conn)
      : super(const HomeLoading()) {
    _load();
    _presenceSub = _conn.presenceStream.listen(_onPresence);
  }

  Future<void> _load() async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    if (peers.isEmpty) {
      emit(const HomeNoPeer());
      return;
    }
    // Make sure the relay is pushing updates for everyone we know about;
    // the call is idempotent so this is safe even mid-session.
    _conn.subscribeToPeers(peers.map((p) => p.remoteEpk).toList());
    emit(HomeList(
      peers: peers,
      statusByEpk: _conn.presenceSnapshot,
    ));
  }

  void _onPresence(Map<String, PresenceState> snapshot) {
    final s = state;
    if (s is! HomeList) return;
    emit(s.copyWith(statusByEpk: snapshot));
  }

  /// Remember which peer the user picked so `/chat` knows what to use.
  /// The connection itself is shared and already running — `ChatViewModel`
  /// fast-paths when ConnectionManager already drives this peer, otherwise
  /// fires the switchTo itself.
  ///
  /// NOTE (plano `app-state-normalization`): an earlier iteration (plano
  /// 13 step 3) also called `_conn.switchTo` here. That created a race
  /// with `_BootState`'s fire-and-forget `conn.boot(preferredEpk: …)` —
  /// two concurrent `_connect` calls for the same peer, doubled
  /// `StatusConnecting` emits, and a transient presence resubscribe
  /// storm the user perceived as "presence oscillating". Single source
  /// of truth: boot decides, Home just updates the pointer, Chat reacts.
  Future<void> openSession(String epk) async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    if (!peers.any((p) => p.remoteEpk == epk)) return;
    await _prefs.setSelectedPeerEpk(epk);
  }

  @override
  void dispose() {
    _disposed = true;
    _presenceSub?.cancel();
    super.dispose();
  }
}
