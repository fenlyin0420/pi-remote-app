import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/storage.dart';
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
          // IconButton(
          //   tooltip: 'Add pairing',
          //   icon: const Icon(Icons.add_rounded, color: kAccent),
          //   onPressed: () => context.push('/pair'),
          // ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
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
        HomeList() => _buildItems(context, vm, state),
      },
    );
  }

  Widget _buildItems(BuildContext context, HomeViewModel vm, HomeList state) {
    final items = state.items(normalizeEpk: toStandardB64);
    // Plan-17 follow-up — paired peers but ZERO rooms announced (Pi
    // offline / nothing running). Show a soft "loneliness" empty
    // state instead of a blank ListView. HomeNoPeer (no peer at all)
    // still uses the louder empty state with Scan QR.
    if (items.isEmpty) {
      return const _LonelyEmptyState();
    }
    // When multiple Macs are paired, group by peer with a section
    // header. Single Mac → flat list (no extra chrome).
    final macCount = state.peers.length;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount:
          items.length + (macCount > 1 ? _headerOffsets(items).length : 0),
      itemBuilder: (ctx, i) {
        if (macCount <= 1) {
          return _buildItemRow(context, vm, state, items, i);
        }
        // Interleave per-peer headers when there are multiple Macs.
        return _buildGrouped(context, vm, state, items, i);
      },
    );
  }

  /// Positions in the OUTPUT list (with headers interleaved) where a
  /// new peer section starts. Used by `itemCount`.
  List<int> _headerOffsets(List<HomeItem> items) {
    final offsets = <int>[];
    String? lastEpk;
    var pos = 0;
    for (final it in items) {
      if (it.peer.remoteEpk != lastEpk) {
        offsets.add(pos);
        pos++; // header slot
        lastEpk = it.peer.remoteEpk;
      }
      pos++; // tile slot
    }
    return offsets;
  }

  /// Render a single (peer, room) row + the surrounding section header
  /// when groups span multiple peers.
  Widget _buildGrouped(
    BuildContext context,
    HomeViewModel vm,
    HomeList state,
    List<HomeItem> items,
    int outIdx,
  ) {
    // Walk the output index back through (header, tile, tile, …, header, tile)
    // to find the underlying HomeItem (or header).
    var pos = 0;
    String? lastEpk;
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it.peer.remoteEpk != lastEpk) {
        if (pos == outIdx) {
          return _PeerSectionHeader(peer: it.peer);
        }
        pos++;
        lastEpk = it.peer.remoteEpk;
      }
      if (pos == outIdx) {
        return _buildItemRowAt(context, vm, state, it);
      }
      pos++;
    }
    return const SizedBox.shrink();
  }

  Widget _buildItemRow(
    BuildContext context,
    HomeViewModel vm,
    HomeList state,
    List<HomeItem> items,
    int i,
  ) {
    final it = items[i];
    return _buildItemRowAt(context, vm, state, it);
  }

  Widget _buildItemRowAt(
    BuildContext context,
    HomeViewModel vm,
    HomeList state,
    HomeItem it,
  ) {
    // Plan-17 follow-up — presence is now per-(peer, room): green if
    // the relay currently announces this specific roomId, grey if it
    // was cached but is offline now. Plan-18 follow-up — when the
    // app's WS to the relay is down, propagate a "reconnecting"
    // signal so tiles don't lie about live state.
    final isLive = vm.isRoomLive(it.peer.remoteEpk, it.room.roomId);
    final isReconnecting = !vm.isRelayConnected;
    final isWorking = vm.isRoomWorking(it.peer.remoteEpk, it.room.roomId);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SessionTile(
          peer: it.peer,
          isLive: isLive,
          isReconnecting: isReconnecting,
          isWorking: isWorking,
          room: it.room,
          onOpen: () => _open(context, vm, it.peer.remoteEpk, it.room.roomId),
          onLongPress: () =>
              _showSessionMenu(context, vm, it, isLive: isLive),
        ),
        const Divider(color: kBorder, height: 1),
      ],
    );
  }

  void _showSessionMenu(
    BuildContext context,
    HomeViewModel vm,
    HomeItem it, {
    required bool isLive,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBg,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined, color: kAccent),
                title: const Text(
                  'Trocar nome da sessão',
                  style: TextStyle(color: kText),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _promptRename(context, vm, it);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: isLive ? kMuted : Colors.redAccent,
                ),
                enabled: !isLive,
                title: Text(
                  'Excluir sessão (apenas local)',
                  style: TextStyle(color: isLive ? kMuted : kText),
                ),
                subtitle: isLive
                    ? const Text(
                        'Só disponível quando a sala está offline',
                        style: TextStyle(color: kMuted, fontSize: 11),
                      )
                    : null,
                onTap: isLive
                    ? null
                    : () {
                        Navigator.of(sheetCtx).pop();
                        _confirmDelete(context, vm, it);
                      },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _promptRename(
      BuildContext context, HomeViewModel vm, HomeItem it) async {
    final controller = TextEditingController(
      text: it.room.name ?? '',
    );
    final result = await showDialog<String?>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: kBg,
        title: const Text('Trocar nome da sessão',
            style: TextStyle(color: kText)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: kText, fontFamily: kMono),
          decoration: InputDecoration(
            hintText: it.room.cwd ?? 'Sessão',
            hintStyle: const TextStyle(color: kMuted),
            enabledBorder:
                const OutlineInputBorder(borderSide: BorderSide(color: kBorder)),
            focusedBorder:
                const OutlineInputBorder(borderSide: BorderSide(color: kAccent)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(null),
            child: const Text('Cancelar', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(controller.text.trim()),
            child: const Text('Salvar', style: TextStyle(color: kAccent)),
          ),
        ],
      ),
    );
    if (result == null) return;
    await vm.renameRoom(it.peer.remoteEpk, it.room.roomId, result);
  }

  Future<void> _confirmDelete(
      BuildContext context, HomeViewModel vm, HomeItem it) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: kBg,
        title: const Text('Excluir sessão?', style: TextStyle(color: kText)),
        content: const Text(
          'Remove apenas localmente. Se a sessão voltar online no Pi, '
          'ela reaparece na lista.',
          style: TextStyle(color: kMuted, fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('Excluir', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await vm.deleteRoom(it.peer.remoteEpk, it.room.roomId);
  }

  // Plan-17 follow-up: AWAIT openSession before pushing /chat. This
  // closes the race where ChatViewModel.bootstrap would read
  // `Preferences.selectedRoomId` BEFORE `setSelectedRoom` had a chance
  // to land, picking up the previous chat's room and rendering its
  // cache. The earlier "fire-and-forget" comment was from before
  // openSession touched prefs; today the body is just Hive read +
  // Hive write + a sync ConnectionManager call (~ms), so awaiting is
  // imperceptible.
  static Future<void> _open(
    BuildContext context,
    HomeViewModel vm,
    String epk,
    String roomId,
  ) async {
    await vm.openSession(epk, roomId: roomId);
    if (!context.mounted) return;
    context.push('/chat');
  }
}

class _PeerSectionHeader extends StatelessWidget {
  final PeerRecord peer;
  const _PeerSectionHeader({required this.peer});

  @override
  Widget build(BuildContext context) {
    final label = (peer.nickname?.isNotEmpty ?? false)
        ? peer.nickname!
        : peer.sessionName.isNotEmpty
        ? peer.sessionName
        : peer.remoteEpk.substring(0, 8);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontFamily: kMono,
          fontSize: 10,
          color: kMuted,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Plan-17 follow-up — soft empty state for paired-but-no-rooms.
/// Different vibe from `_EmptyState` (which is loud + Scan QR CTA):
/// no actions, very low opacity, just acknowledges that nothing is
/// happening on any paired Pi right now.
class _LonelyEmptyState extends StatelessWidget {
  const _LonelyEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Opacity(
        opacity: 0.35,
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.bedtime_outlined,
                color: kMuted,
                size: 56,
              ),
              const SizedBox(height: 18),
              const Text(
                'Nada aqui…',
                style: TextStyle(
                  fontFamily: kMono,
                  color: kMuted2,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Quando algum Pi pareado abrir uma sessão, ela aparece aqui.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: kMono,
                  color: kMuted,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
