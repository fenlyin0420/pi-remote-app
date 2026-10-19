import 'dart:typed_data';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/file_bubble.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// ---------------------------------------------------------------------------
// UserBubble — right-aligned dark card
// ---------------------------------------------------------------------------

class UserBubble extends StatelessWidget {
  final UserMsg message;

  /// Reads a picture's bytes from the phone's archive (see [ImageBubble]);
  /// null where there is no archive to read (tests, a row with inline bytes).
  final Future<Uint8List?> Function(String blob)? loadImageBytes;

  const UserBubble(this.message, {super.key, this.loadImageBytes});

  /// The layout of everything a user message carries: a caption card first
  /// (when the message has text), then one bubble per image and per file, each
  /// 6px below the previous one. A picture is never drawn inside the card that
  /// holds the text — they are separate bubbles.
  static List<Widget> _attachmentKids(
    List<MessageImage> images,
    List<MessageFile> files,
    bool hasCaption,
    String text,
    AppColors colors,
    AppTypography typo,
    bool isFailed,
    Future<Uint8List?> Function(String blob)? loadImageBytes,
  ) {
    final kids = <Widget>[];
    var placed = 0;
    Widget wrap(int i, Widget w) => i > 0
        ? Padding(padding: const EdgeInsets.only(top: 6), child: w)
        : w;
    if (hasCaption) {
      kids.add(
        Container(
          decoration: BoxDecoration(
            color: colors.userBubble,
            borderRadius: BorderRadius.circular(12),
            border:
                isFailed ? Border.all(color: colors.error, width: 1) : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          // Selectable so the user can copy their own message (the agent
          // reply is already selectable via AgentMarkdown).
          child: SelectableText(
            text,
            style: typo.sansBody.copyWith(color: colors.text),
          ),
        ),
      );
      placed++;
    }
    for (final image in images) {
      kids.add(
        wrap(
          placed,
          ImageBubble(
            image: image,
            isFailed: isFailed,
            loadBytes: loadImageBytes,
          ),
        ),
      );
      placed++;
    }
    for (final file in files) {
      kids.add(wrap(placed, FileBubble(file: file, isFailed: isFailed)));
      placed++;
    }
    return kids;
  }

  @override
  Widget build(BuildContext context) {
    // Plan/24-fix-app-source-of-truth: render the lifecycle stage of
    // the bubble. `pending` (sent over WS, Pi hasn't echoed yet) gets
    // reduced opacity + a small spinner; `failed` (no echo in 15s) gets
    // a red exclamation badge so the user knows to retry.
    final isPending = message.status == UserMsgStatus.pending;
    final isFailed = message.status == UserMsgStatus.failed;
    final isSteering = message.steering;
    // Plan/30/63 — attachments render as bubbles: one ImageBubble per image
    // and one FileBubble per file, with the text (when there is any) in its own
    // card above them. A single file keeps the legacy look (the caption reads
    // inside that card).
    final images = message.images;
    final files = message.files;
    final hasCaption = message.text.trim().isNotEmpty;
    final colors = context.colors;
    final typo = context.typo;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Opacity(
              opacity: isPending ? 0.6 : 1.0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: files.length == 1 && images.isEmpty
                    ? [
                        FileBubble(
                          file: files.first,
                          caption: message.text,
                          isFailed: isFailed,
                        ),
                      ]
                    : _attachmentKids(
                        images,
                        files,
                        hasCaption,
                        message.text,
                        colors,
                        typo,
                        isFailed,
                        loadImageBytes,
                      ),
              ),
            ),
            if (isPending || isSteering || isFailed)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isPending || isSteering) ...[
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          color: colors.muted,
                          strokeWidth: 1.2,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isSteering ? 'steering…' : 'sending…',
                        style: typo.sansBody.copyWith(
                          color: colors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ] else ...[
                      Icon(
                        LucideIcons.circleAlert,
                        size: 12,
                        color: colors.error,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'not delivered',
                        style: typo.sansBody.copyWith(
                          color: colors.error,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CompactionBubble — centered system card (plan/32)
// ---------------------------------------------------------------------------

/// A system message distinct from user/assistant: shows that the Pi compacted
/// the context, with the recap summary and the reclaimed token count. Mirrors
/// the TUI's CompactionSummaryMessageComponent.
///
/// LOCAL (fenlyin): the summary is a COLLAPSIBLE block — collapsed by default,
/// the same pattern as [ThinkingBlock]: the recap is context about the
/// conversation, not conversation content, so the header stands alone until
/// the user taps it.
class CompactionBubble extends StatefulWidget {
  final CompactionMsg message;
  const CompactionBubble(this.message, {super.key});

  @override
  State<CompactionBubble> createState() => _CompactionBubbleState();
}

class _CompactionBubbleState extends State<CompactionBubble> {
  bool _expanded = false;
  bool _restored = false;

  /// Content-addressed expansion state, kept in the route's [PageStorage] —
  /// the same trick as [ThinkingBlock]: the widget's State does not survive
  /// scrolling out of view or a re-sync rewriting the row under a new id, but
  /// the summary text does.
  Object get _storageId =>
      'compaction-expanded:${widget.message.summary.hashCode}:${widget.message.summary.length}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    final stored = PageStorage.maybeOf(context)
        ?.readState(context, identifier: _storageId);
    // Only the user ever writes this, so anything unreadable means collapsed.
    if (stored is bool) _expanded = stored;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)
        ?.writeState(context, _expanded, identifier: _storageId);
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final tokens = message.tokensBefore;
    final summary = message.summary;
    final hasSummary = summary.isNotEmpty;
    final colors = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                key: const Key('compaction-header'),
                behavior: HitTestBehavior.opaque,
                onTap: hasSummary ? _toggle : null,
                child: Row(
                  children: [
                    Icon(LucideIcons.check, size: 13, color: colors.success),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Context compacted',
                        style: TextStyle(
                          fontFamily: kMonoFamily,
                          fontSize: 12,
                          color: colors.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (tokens != null)
                      Text(
                        '~$tokens tokens',
                        style: TextStyle(
                          fontFamily: kMonoFamily,
                          fontSize: 11,
                          color: colors.muted,
                        ),
                      ),
                    if (hasSummary)
                      Icon(
                        _expanded
                            ? LucideIcons.chevronDown
                            : LucideIcons.chevronRight,
                        size: 14,
                        color: colors.muted,
                      ),
                  ],
                ),
              ),
              if (_expanded && hasSummary) ...[
                const SizedBox(height: 6),
                SelectableText(
                  summary,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 12,
                    color: colors.muted2,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AssistantBubble — left-aligned monospace text
// ---------------------------------------------------------------------------

class AssistantBubble extends StatelessWidget {
  final AssistantMsg message;
  const AssistantBubble(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    // Plan/32b — agent output is rendered as Markdown (GFM + code blocks),
    // spanning the FULL content width (the message list already pads 16px on
    // each side) — unlike the user's right-aligned chat bubble, which stays
    // capped. Selectable so prose/code can be copied.
    return SizedBox(
      width: double.infinity,
      child: AgentMarkdown(message.text, selectable: true),
    );
  }
}
