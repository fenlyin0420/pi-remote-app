import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/app_theme.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/home/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HomeViewModel>();
    final state = vm.state;

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text('Remote Pi'),
        actions: [
          IconButton(
            tooltip: 'Add pairing',
            icon: const Icon(Icons.add_rounded, color: kAccent),
            onPressed: () => context.push('/pair'),
          ),
          PopupMenuButton<_HomeMenu>(
            tooltip: 'Menu',
            color: kSurface,
            icon: const Icon(Icons.more_vert, color: kText),
            onSelected: (item) {
              switch (item) {
                case _HomeMenu.settings:
                  context.push('/settings');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _HomeMenu.settings,
                child: Text('Settings', style: TextStyle(color: kText)),
              ),
            ],
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(color: kBorder, height: 1),
        ),
      ),
      body: switch (state) {
        HomeLoading() => const Center(
          child: CircularProgressIndicator(color: kAccent),
        ),
        HomeNoPeer() => const _EmptyState(),
        HomeList(:final peers, :final statusByEpk) => ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: peers.length,
          separatorBuilder: (_, _) => const Divider(color: kBorder, height: 1),
          itemBuilder: (ctx, i) {
            final peer = peers[i];
            // statusByEpk is keyed in base64 STANDARD (relay registry format);
            // PeerRecord.remoteEpk is base64url from QR/storage. Coerce on
            // lookup. See lib/data/transport/epk_encoding.dart.
            final presence =
                statusByEpk[toStandardB64(peer.remoteEpk)] ??
                const PresenceUnknown();
            return SessionTile(
              peer: peer,
              presence: presence,
              onOpen: () => _open(context, vm, peer.remoteEpk),
            );
          },
        ),
      },
    );
  }

  // Kick off the peer switch in the background and navigate immediately.
  // ChatPage already shows ChatConnecting → ChatReady through the
  // SessionRepository stream, so awaiting here would only block the tap.
  // Awaiting also broke `context.mounted` because the ListView item element
  // gets recycled when the HomeViewModel re-emits during switchTo.
  static void _open(BuildContext context, HomeViewModel vm, String epk) {
    // ignore: unawaited_futures
    vm.openSession(epk);
    context.push('/chat');
  }
}

enum _HomeMenu { settings }

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.qr_code_scanner, color: kMuted, size: 48),
            const SizedBox(height: 16),
            const Text(
              'No pairings yet',
              style: TextStyle(color: kMuted2, fontSize: 14),
            ),
            const SizedBox(height: 6),
            const Text(
              'Scan a QR from your Mac to start.',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => context.push('/pair'),
              style: FilledButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: Colors.black,
              ),
              icon: const Icon(Icons.qr_code_scanner, size: 18),
              label: const Text('Scan QR'),
            ),
          ],
        ),
      ),
    );
  }
}
