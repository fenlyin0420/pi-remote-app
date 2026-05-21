import 'package:app/config/dependencies.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/app_theme.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:app/ui/chat/widgets/streaming_bubble.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

class ChatPage extends StatelessWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ChatViewModel>();
    final state = vm.state;

    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context, state),
            // Pairing revocation is the only banner kept — it's a hard
            // failure (can't proceed without re-pairing), red, with an
            // explicit action. Plain offline / Pi-gone / presence-off
            // banners were removed: the AppBar status line already
            // surfaces those, and stacking duplicates noise the surface.
            if (state is ChatReady && state.pairingRevoked)
              _RevokedBanner(onRePair: () => context.go('/pair')),
            Expanded(child: _buildBody(context, state, vm)),
            _buildInput(state, vm),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, ChatState state) {
    // Title prefers the local nickname; falls back to the Pi's session
    // name. The subtitle is `sessionName · ● <status>` (or just
    // `● <status>` when the title is already the sessionName).
    final peer = injector.get<ConnectionManager>().activePeer;
    final nickname = peer?.nickname;
    final sessionName = peer?.sessionName;
    final hasNickname = nickname != null && nickname.isNotEmpty;
    final primary = hasNickname
        ? _truncate(nickname, 24)
        : sessionName != null && sessionName.isNotEmpty
        ? _truncate(sessionName, 24)
        : state is ChatReady && state.messages.isNotEmpty
        ? _inferSessionName(state.messages)
        : 'Remote Pi';
    final subtitleSession =
        hasNickname && sessionName != null && sessionName.isNotEmpty
        ? _truncate(sessionName, 24)
        : null;

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: const BoxDecoration(
        color: kBg,
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: kText),
            tooltip: 'Back',
            onPressed: () =>
                context.canPop() ? context.pop() : context.go('/home'),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  primary,
                  style: const TextStyle(
                    fontFamily: kMono,
                    fontSize: 13,
                    color: kText,
                    letterSpacing: -0.2,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                _ChatStatusLine(state: state, sessionLabel: subtitleSession),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 1)}…';

  Widget _buildBody(BuildContext context, ChatState state, ChatViewModel vm) {
    final hideToolCalls = context.watch<Preferences>().hideToolCalls;
    return switch (state) {
      // Edge case: opened /chat without a peer (e.g. peer revoked while
      // user was here). The chat is not the place to pair — render
      // a minimal empty state without an action. User navigates back
      // and uses Home / Settings → pairing.
      ChatNoPeer() => const _EmptyState(
        icon: Icons.chat_bubble_outline,
        message: 'No active device',
      ),
      ChatConnecting() => const _EmptyState(
        icon: Icons.sync_rounded,
        message: 'Connecting…',
      ),
      ChatFatalError(:final message) => _EmptyState(
        icon: Icons.error_outline_rounded,
        message: message,
        actionLabel: 'Re-pair',
        onAction: () => context.go('/pair'),
      ),
      ChatReady(:final messages, :final streaming) => _MessageList(
        messages: hideToolCalls
            ? messages.where((m) => m is! ToolEvent).toList()
            : messages,
        streaming: streaming,
        onDecide: (id, decision) => vm.approveTool(id, decision),
      ),
    };
  }

  Widget _buildInput(ChatState state, ChatViewModel vm) {
    final isReady = state is ChatReady;
    final isOffline = isReady && state.isOffline;
    final isRevoked = isReady && state.pairingRevoked;
    final isPeerOffline = isReady && state.peerOfflineReason != null;
    // Live relay-reported offline (no `bye`): Pi is just not reachable.
    final isPresenceOffline = isReady && state.peerPresence is PresenceOffline;
    final isStreaming = isReady && state.streaming != null;
    final streamingId = isReady ? state.streaming?.inReplyTo : null;

    return InputBar(
      disabled: !isReady
          || isOffline
          || isRevoked
          || isPeerOffline
          || isPresenceOffline,
      streaming: isStreaming,
      onSend: (text) => vm.sendMessage(text),
      onCancel: streamingId != null ? () => vm.cancel(streamingId) : null,
    );
  }

  static String _inferSessionName(List<ChatMessage> msgs) {
    for (final m in msgs) {
      if (m is UserMsg) return m.text.substring(0, m.text.length.clamp(0, 32));
    }
    return 'Remote Pi';
  }
}

// ---------------------------------------------------------------------------

class _MessageList extends StatefulWidget {
  final List<ChatMessage> messages;
  final StreamingMessage? streaming;
  final void Function(String, ApproveDecision) onDecide;

  const _MessageList({
    required this.messages,
    required this.streaming,
    required this.onDecide,
  });

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  final _scroll = ScrollController();
  bool _userScrolled = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.userScrollDirection.name == 'reverse') {
        _userScrolled = true;
      }
      if (_scroll.position.pixels < 20) _userScrolled = false;
    });
  }

  @override
  void didUpdateWidget(_MessageList old) {
    super.didUpdateWidget(old);
    if (!_userScrolled) _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final itemCount =
        widget.messages.length + (widget.streaming != null ? 1 : 0);

    return ListView.separated(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
      itemCount: itemCount,
      separatorBuilder: (context, idx) => const SizedBox(height: 14),
      itemBuilder: (_, i) {
        // Index 0 = bottom = newest
        if (widget.streaming != null && i == 0) {
          return StreamingBubble(widget.streaming!);
        }
        final msgIdx =
            widget.messages.length -
            1 -
            (i - (widget.streaming != null ? 1 : 0));
        final msg = widget.messages[msgIdx];
        return switch (msg) {
          UserMsg() => UserBubble(msg),
          AssistantMsg() => AssistantBubble(msg),
          ToolEvent() => ToolRequestCard(tool: msg, onDecide: widget.onDecide),
        };
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _EmptyState({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: kMuted, size: 48),
          const SizedBox(height: 16),
          Text(message, style: const TextStyle(color: kMuted, fontSize: 14)),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: Colors.black,
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

/// Inline AppBar subtitle. Only renders WHEN ABNORMAL — connecting,
/// offline, revoked, etc. When everything is healthy (ChatReady + online
/// + no Pi-offline reason + presence online or unknown), this widget
/// shrinks to nothing so the title sits alone, idle.
class _ChatStatusLine extends StatelessWidget {
  final ChatState state;
  final String? sessionLabel;
  const _ChatStatusLine({required this.state, required this.sessionLabel});

  /// Returns `(label, color)` if a status indicator should render, or
  /// `null` if the state is idle/healthy and should display nothing.
  static (String, Color)? _statusFor(ChatState state) {
    return switch (state) {
      ChatNoPeer() => null,                                  // chat is not the place for pairing
      ChatConnecting() => ('connecting…', kAccent),
      ChatFatalError() => ('offline', Colors.red.shade400),
      ChatReady(:final isOffline,
                :final pairingRevoked,
                :final peerOfflineReason,
                :final peerPresence) =>
        pairingRevoked
            ? ('revoked', Colors.red.shade400)
            : peerOfflineReason != null
                ? ('Pi offline', Colors.amber.shade600)
                : peerPresence is PresenceOffline
                    ? ('Pi offline', Colors.amber.shade600)
                    : isOffline
                        ? ('reconnecting…', Colors.amber.shade600)
                        : null, // online + clean → idle, render nothing
    };
  }

  @override
  Widget build(BuildContext context) {
    final indicator = _statusFor(state);
    if (indicator == null) return const SizedBox.shrink();
    final (label, color) = indicator;

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          if (sessionLabel != null) ...[
            Flexible(
              child: Text(
                sessionLabel!,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: kMono,
                  fontSize: 10,
                  color: kMuted,
                ),
              ),
            ),
            const Text(
              '  ·  ',
              style: TextStyle(fontFamily: kMono, fontSize: 10, color: kMuted),
            ),
          ],
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(fontFamily: kMono, fontSize: 10, color: color),
          ),
        ],
      ),
    );
  }
}

class _RevokedBanner extends StatelessWidget {
  final VoidCallback onRePair;
  const _RevokedBanner({required this.onRePair});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.red.shade900.withValues(alpha: 0.85),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.link_off_rounded, color: Colors.white, size: 15),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Pairing revoked by Mac — re-pair to continue',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          GestureDetector(
            onTap: onRePair,
            child: const Text(
              'Re-pair',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
