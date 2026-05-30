import 'package:app/ui/app_theme.dart';
import 'package:flutter/material.dart';

// InputBar — bottom message composer.
// - Disabled (grayed) when offline or streaming.
// - Send button turns to Cancel icon during streaming.
// - Plan/28 — quick actions (⚙) icon sits to the left of the attach
//   button and is visible only while the field is empty (so it never
//   competes with the send affordance).

class InputBar extends StatefulWidget {
  final bool disabled; // offline or no peer
  final bool streaming; // show cancel instead of send
  final void Function(String text) onSend;
  final VoidCallback? onCancel;
  final VoidCallback? onOpenQuickActions;

  const InputBar({
    super.key,
    required this.onSend,
    this.onCancel,
    this.onOpenQuickActions,
    this.disabled = false,
    this.streaming = false,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final _controller = TextEditingController();
  bool _empty = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChange);
  }

  void _onTextChange() {
    final next = _controller.text.isEmpty;
    if (next == _empty) return;
    setState(() {
      _empty = next;
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChange);
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    widget.onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    final canInteract = !widget.disabled;
    final showQuickActions = _empty &&
        canInteract &&
        !widget.streaming &&
        widget.onOpenQuickActions != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 22),
      decoration: const BoxDecoration(
        color: kBg,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          if (showQuickActions) ...[
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                key: const Key('input-bar-quick-actions'),
                padding: EdgeInsets.zero,
                iconSize: 18,
                splashRadius: 18,
                tooltip: 'Quick actions',
                icon: const Icon(Icons.tune_rounded, color: kMuted),
                onPressed: widget.onOpenQuickActions,
              ),
            ),
            const SizedBox(width: 6),
          ],
          // Attachment placeholder
          const SizedBox(
            width: 32,
            height: 32,
            child: Icon(Icons.attach_file_rounded, color: kMuted, size: 18),
          ),
          const SizedBox(width: 10),
          // Text field
          Expanded(
            child: TextField(
              controller: _controller,
              enabled: canInteract && !widget.streaming,
              onSubmitted: canInteract && !widget.streaming ? (_) => _submit() : null,
              style: const TextStyle(
                fontFamily: kMono,
                fontSize: 13,
                color: kText,
              ),
              cursorColor: kAccent,
              decoration: InputDecoration(
                hintText: widget.disabled
                    ? 'Offline…'
                    : widget.streaming
                    ? 'Waiting for response…'
                    : 'Send a message…',
                hintStyle: const TextStyle(color: kMuted, fontFamily: kMono),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                filled: true,
                fillColor: const Color(0xFF0E0E0E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(19),
                  borderSide: const BorderSide(color: kBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(19),
                  borderSide: const BorderSide(color: kBorder),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(19),
                  borderSide: BorderSide(color: kBorder.withValues(alpha: 0.5)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(19),
                  borderSide: const BorderSide(color: kAccent, width: 1.2),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Send / Cancel button
          GestureDetector(
            onTap: widget.streaming
                ? widget.onCancel
                : canInteract
                ? _submit
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: canInteract ? kAccent : kMuted.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(19),
                boxShadow: canInteract
                    ? [
                        BoxShadow(
                          color: kAccent.withValues(alpha: 0.33),
                          blurRadius: 16,
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                widget.streaming ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                color: canInteract ? Colors.black : kMuted,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
