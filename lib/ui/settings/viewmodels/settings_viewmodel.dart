import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/settings/states/settings_state.dart';

/// Settings is config-only (nickname + revoke). The peer switcher moved
/// to Home; the connection itself is shared and owned by
/// [ConnectionManager] from app boot (plano 12). Revoke side-effect:
/// re-subscribe the relay's presence push so the removed epk is dropped.
class SettingsViewModel extends ViewModel<SettingsState> {
  final PairingStorage _storage;
  final Preferences _prefs;
  final ConnectionManager _conn;
  bool _disposed = false;

  SettingsViewModel(this._storage, this._prefs, this._conn)
      : super(const SettingsLoading()) {
    _load();
  }

  Future<void> _load() async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    if (peers.isEmpty) {
      emit(const SettingsNoPeer());
      return;
    }
    emit(SettingsList(peers: peers));
  }

  /// Set or clear the local nickname for the peer at [epk].
  Future<void> setNickname(String epk, String? nickname) async {
    final s = state;
    if (s is! SettingsList) return;
    PeerRecord? target;
    for (final p in s.peers) {
      if (p.remoteEpk == epk) { target = p; break; }
    }
    if (target == null) return;
    final trimmed = nickname?.trim();
    final normalized =
        (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    final updated = target.copyWith(nickname: normalized);
    await _storage.savePeer(updated);
    await _load();
  }

  /// Revoke pairing locally. Drops the peer from the relay's presence
  /// subscription too so we stop receiving updates about a peer that no
  /// longer exists on this device. Clears the selected pointer when it
  /// matches.
  Future<void> revoke(String epk) async {
    if (_prefs.selectedPeerEpk == epk) {
      await _prefs.setSelectedPeerEpk(null);
    }
    await _storage.deletePeer(epk);
    final remaining = await _storage.listPeers();
    _conn.subscribeToPeers(remaining.map((p) => p.remoteEpk).toList());
    await _load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
