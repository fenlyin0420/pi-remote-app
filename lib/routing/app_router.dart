import 'package:app/config/dependencies.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/home/home_page.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/pairing/pairing_page.dart';
import 'package:app/ui/pairing/viewmodels/pairing_viewmodel.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

// Boot decision is async — _BootState is a ChangeNotifier used as
// refreshListenable so the router redirects once the storage check finishes.
class _BootState extends ChangeNotifier {
  bool _ready = false;
  bool _hasPeer = false;

  bool get ready => _ready;
  bool get hasPeer => _hasPeer;

  Future<void> load(
    PairingStorage storage,
    ConnectionManager conn,
    Preferences prefs,
  ) async {
    final peers = await storage.listPeers();
    _hasPeer = peers.isNotEmpty;
    _ready = true;
    notifyListeners();
    // Plano 13: `Preferences.selectedPeerEpk` is the authoritative
    // pointer to the peer the user wants connected. On a fresh install
    // it's null — default to `peers.first` so subsequent boot()s have a
    // stable target and the user lands on a deterministic chat.
    if (_hasPeer) {
      await prefs.load();
      var selected = prefs.selectedPeerEpk;
      if (selected == null) {
        selected = peers.first.remoteEpk;
        await prefs.setSelectedPeerEpk(selected);
      } else if (!peers.any((p) => p.remoteEpk == selected)) {
        // Selected peer was revoked / no longer in storage — fall back.
        selected = peers.first.remoteEpk;
        await prefs.setSelectedPeerEpk(selected);
      }
      // ignore: unawaited_futures
      conn.boot(preferredEpk: selected);
    }
  }
}

GoRouter buildRouter(
  PairingStorage storage,
  ConnectionManager conn,
  Preferences prefs,
) {
  final boot = _BootState();
  boot.load(storage, conn, prefs);

  return GoRouter(
    initialLocation: '/boot',
    refreshListenable: boot,
    redirect: (context, state) {
      if (!boot.ready) return '/boot';
      if (state.uri.path == '/boot') {
        return boot.hasPeer ? '/home' : '/pair';
      }
      return null;
    },
    routes: [
      // Splash while boot.load() is in flight
      GoRoute(
        path: '/boot',
        builder: (ctx, st) => const _BootSplash(),
      ),

      // Home — list of paired sessions, entry point post-boot
      GoRoute(
        path: '/home',
        builder: (ctx, st) => MultiProvider(
          providers: [ViewmodelProvider<HomeViewModel>()],
          child: const HomePage(),
        ),
      ),

      // QR pairing flow
      GoRoute(
        path: '/pair',
        builder: (ctx, st) => MultiProvider(
          providers: [ViewmodelProvider<PairingViewModel>()],
          child: const PairingPage(),
        ),
      ),

      // Chat screen (entered by tapping a session in /home)
      GoRoute(
        path: '/chat',
        builder: (ctx, st) => MultiProvider(
          providers: [ViewmodelProvider<ChatViewModel>()],
          child: const ChatPage(),
        ),
      ),

      // Settings (entered from /home menu)
      GoRoute(
        path: '/settings',
        builder: (ctx, st) => MultiProvider(
          providers: [ViewmodelProvider<SettingsViewModel>()],
          child: const SettingsPage(),
        ),
      ),
    ],
  );
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF000000),
      body: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            color: Color(0xFF00D4FF),
            strokeWidth: 2,
          ),
        ),
      ),
    );
  }
}
