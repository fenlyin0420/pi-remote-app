import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Plan/63 — the agent's todo list (pi-todo), floated over the transcript.
///
/// Collapsed it is a small pill carrying `done/total`; tapping it expands the
/// rows in a card sitting just above the composer, and tapping it again
/// collapses them. Nothing renders when the Pi has no list — a chat with a Pi
/// that never ran `todo` looks exactly as it did before this existed.
///
/// Collapsed by default: the transcript is the subject of the screen, and the
/// plan is something you consult, not something that permanently occupies the
/// bottom of the chat. The pill still answers "how far along is it?" without a
/// tap, which is the part worth having at a glance.
///
/// Rows are ordered by urgency — in progress, then pending, then done — which is
/// the reverse of pi-todo's desktop panel (it keeps finished rows at the top
/// because they drop off at the next turn). Reading a phone list, the useful
/// question is "what is happening now", so that row comes first.
class TodoPanel extends StatefulWidget {
  const TodoPanel({
    super.key,
    required this.todos,
    this.maxCardHeight = 280,
  });

  /// The room's list, already filtered by the Pi (no tombstones).
  final TodoState todos;

  /// Ceiling for the expanded card. The host passes the transcript height it
  /// can actually give away — a fixed ceiling would clip the header on a short
  /// viewport (landscape, or a phone with the keyboard up), silently, because a
  /// `Positioned` child has no height bound to overflow against.
  final double maxCardHeight;

  @override
  State<TodoPanel> createState() => _TodoPanelState();
}

class _TodoPanelState extends State<TodoPanel> {
  bool _open = false;

  @override
  void didUpdateWidget(covariant TodoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The list can empty out (agent cleared it, the session was replaced) while
    // the card is open — collapse rather than leave an empty card hanging that
    // the user has to dismiss by hand.
    if (widget.todos.isEmpty && _open) _open = false;
  }

  void _toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext context) {
    final todos = widget.todos;
    if (todos.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_open) ...[
          _TodoCard(todos: todos, maxHeight: widget.maxCardHeight),
          const SizedBox(height: 10),
        ],
        _TodoPill(todos: todos, open: _open, onTap: _toggle),
      ],
    );
  }
}

/// The floating affordance: a stadium-shaped pill with the icon and the
/// `done/total` counter. Accent-tinted while something is in progress, so the
/// one-glance answer is also "is the agent working on the list right now?".
class _TodoPill extends StatelessWidget {
  const _TodoPill({required this.todos, required this.open, required this.onTap});

  final TodoState todos;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final busy = todos.inProgress != null;
    final tint = busy ? colors.accent : colors.muted;
    return Tooltip(
      message: open ? 'Hide the todo list' : 'Show the todo list',
      child: Material(
        key: const Key('todo-pill'),
        color: colors.surface,
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.3),
        shape: StadiumBorder(
          side: BorderSide(
            color: busy ? colors.accent.withValues(alpha: 0.7) : colors.border,
          ),
        ),
        child: InkWell(
          key: const Key('todo-pill-tap'),
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            // Material's minimum touch target, which a 15px icon plus 8px of
            // padding does not reach on its own.
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.listChecks, size: 15, color: tint),
                  const SizedBox(width: 8),
                  Text(
                    '${todos.doneCount}/${todos.total}',
                    key: const Key('todo-pill-count'),
                    style: context.typo.mono.copyWith(
                      color: colors.text,
                      fontSize: 12,
                      height: 1,
                    ),
                  ),
                  const SizedBox(width: 6),
                  // A collapsed pill only counts rows; without a chevron there
                  // is nothing on screen saying it opens (the tooltip needs a
                  // long press on a phone).
                  Icon(
                    open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                    size: 14,
                    color: colors.muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The expanded list: header with the counter, then one row per task.
class _TodoCard extends StatelessWidget {
  const _TodoCard({required this.todos, required this.maxHeight});

  final TodoState todos;

  /// Upper bound on the card, so a long list cannot swallow the transcript;
  /// past it the rows scroll — the same policy as the TUI panel's row budget.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final rows = _ordered(todos.tasks);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 420, maxHeight: maxHeight),
      child: Container(
        key: const Key('todo-card'),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.32),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(todos: todos),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final task in rows) _TodoRow(task: task),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// In progress → pending → done, each by id. See the class comment.
  static List<TodoTask> _ordered(List<TodoTask> tasks) {
    int rank(TodoTask t) => switch (t.status) {
      TodoTaskStatus.inProgress => 0,
      TodoTaskStatus.pending => 1,
      TodoTaskStatus.completed => 2,
      TodoTaskStatus.unknown => 1,
    };
    final sorted = [...tasks]..sort((a, b) {
      final byRank = rank(a) - rank(b);
      return byRank != 0 ? byRank : a.id - b.id;
    });
    return sorted;
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.todos});

  final TodoState todos;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      children: [
        Icon(LucideIcons.listChecks, size: 11, color: colors.accent),
        const SizedBox(width: 7),
        Text(
          'TODOS',
          style: context.typo.monoSmall.copyWith(
            color: colors.accent,
            fontSize: 10,
            letterSpacing: 1.1,
          ),
        ),
        const Spacer(),
        Text(
          '${todos.doneCount}/${todos.total}',
          style: context.typo.monoSmall.copyWith(color: colors.muted),
        ),
      ],
    );
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.task});

  final TodoTask task;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final done = task.isDone;
    final (IconData glyph, Color tint) = switch (task.status) {
      TodoTaskStatus.completed => (LucideIcons.circleCheck, colors.success),
      TodoTaskStatus.inProgress => (LucideIcons.circleDot, colors.accent),
      TodoTaskStatus.pending => (LucideIcons.circle, colors.muted2),
      TodoTaskStatus.unknown => (LucideIcons.circle, colors.muted2),
    };
    final activeForm = task.activeForm;
    final blockedBy = task.blockedBy;
    final status = switch (task.status) {
      TodoTaskStatus.completed => 'completed',
      TodoTaskStatus.inProgress => 'in progress',
      TodoTaskStatus.pending => 'pending',
      TodoTaskStatus.unknown => 'pending',
    };
    // The glyph, colour and strikethrough are the whole status here, so a
    // screen reader would otherwise read a bare list of task names. The label
    // carries the state instead.
    return Semantics(
      container: true,
      label: '${task.subject}, $status',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                // Optically centres the glyph on the first text line.
                padding: const EdgeInsets.only(top: 1),
                child: Icon(glyph, size: 14, color: tint),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      task.subject,
                      style: typo.monoSmall.copyWith(
                        color: done ? colors.muted : colors.text,
                        decoration: done ? TextDecoration.lineThrough : null,
                        decorationColor: colors.muted,
                      ),
                    ),
                    // The present-continuous label is the point of `activeForm`:
                    // it says what the agent is doing on that row, not just which
                    // row it is.
                    if (!done &&
                        task.status == TodoTaskStatus.inProgress &&
                        activeForm != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          activeForm,
                          style: typo.monoSmall.copyWith(color: colors.accent),
                        ),
                      ),
                    if (!done && blockedBy.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          'blocked by #${blockedBy.join(', #')}',
                          style: typo.monoSmall.copyWith(color: colors.muted),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
