import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatInput extends StatefulWidget {
  final bool isStreaming;
  final VoidCallback? onCancel;
  final void Function(String) onSend;

  /// Current contents of the message queue — shown as chips above the field.
  final List<String> messageQueue;
  final void Function(int index) onRemoveFromQueue;
  final VoidCallback onClearQueue;

  const ChatInput({
    super.key,
    required this.isStreaming,
    required this.onSend,
    this.onCancel,
    this.messageQueue = const [],
    required this.onRemoveFromQueue,
    required this.onClearQueue,
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });

    // Desktop: Enter sends / queues, Shift+Enter inserts a newline.
    _focusNode.onKeyEvent = (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _submit();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasQueue = widget.messageQueue.isNotEmpty;

    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 8, 12, MediaQuery.paddingOf(context).bottom + 8),
      decoration: BoxDecoration(
        color: cs.surface,
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Queue chip strip ─────────────────────────────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            child: hasQueue
                ? _QueueStrip(
                    queue: widget.messageQueue,
                    onRemove: widget.onRemoveFromQueue,
                    onClear: widget.onClearQueue,
                  )
                : const SizedBox.shrink(),
          ),

          // ── Text field + action button ───────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    maxLines: 6,
                    minLines: 1,
                    // Always editable — typing while streaming queues the message.
                    textCapitalization: TextCapitalization.sentences,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    style: TextStyle(color: cs.onSurface, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: widget.isStreaming
                          ? (hasQueue
                              ? 'Add another to queue…'
                              : 'Queue a message…')
                          : 'Message',
                      hintStyle: TextStyle(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _ActionButton(
                isStreaming: widget.isStreaming,
                hasText: _hasText,
                onSend: _submit,
                onCancel: widget.onCancel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Queue chip strip ──────────────────────────────────────────────────────────

class _QueueStrip extends StatelessWidget {
  final List<String> queue;
  final void Function(int) onRemove;
  final VoidCallback onClear;

  const _QueueStrip({
    required this.queue,
    required this.onRemove,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(Icons.playlist_play_rounded,
                  size: 14, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                '${queue.length} queued',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              const Spacer(),
              if (queue.length > 1)
                InkWell(
                  onTap: onClear,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    child: Text(
                      'Clear all',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: cs.error),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: queue.asMap().entries.map((e) {
                final idx = e.key;
                final text = e.value;
                final label = text.length > 35
                    ? '${text.substring(0, 35)}…'
                    : text;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _QueueChip(
                    index: idx,
                    label: label,
                    cs: cs,
                    theme: theme,
                    onRemove: () => onRemove(idx),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueChip extends StatelessWidget {
  final int index;
  final String label;
  final ColorScheme cs;
  final ThemeData theme;
  final VoidCallback onRemove;

  const _QueueChip({
    required this.index,
    required this.label,
    required this.cs,
    required this.theme,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: cs.secondary.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Queue position badge
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: cs.secondary.withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              '${index + 1}',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: cs.onSecondaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onRemove,
            child: Icon(
              Icons.close_rounded,
              size: 13,
              color: cs.onSecondaryContainer.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Action button ─────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final bool isStreaming;
  final bool hasText;
  final VoidCallback onSend;
  final VoidCallback? onCancel;

  const _ActionButton({
    required this.isStreaming,
    required this.hasText,
    required this.onSend,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Streaming + text typed → queue button
    if (isStreaming && hasText) {
      return _CircleButton(
        onTap: onSend,
        color: cs.secondary,
        icon: const Icon(Icons.playlist_add_rounded,
            color: Colors.white, size: 22),
        tooltip: 'Add to queue',
      );
    }

    // Streaming + no text → stop button
    if (isStreaming) {
      return _CircleButton(
        onTap: onCancel,
        color: cs.error,
        icon: const Icon(Icons.stop_rounded, color: Colors.white, size: 22),
        tooltip: 'Stop',
      );
    }

    // Not streaming
    return _CircleButton(
      onTap: hasText ? onSend : null,
      color: hasText ? cs.primary : cs.surfaceContainerHighest,
      icon: Icon(
        Icons.arrow_upward_rounded,
        color: hasText ? cs.onPrimary : cs.onSurfaceVariant,
        size: 22,
      ),
      tooltip: 'Send',
    );
  }
}

class _CircleButton extends StatelessWidget {
  final VoidCallback? onTap;
  final Color color;
  final Widget icon;
  final String tooltip;

  const _CircleButton({
    required this.onTap,
    required this.color,
    required this.icon,
    this.tooltip = '',
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
          child: icon,
        ),
      ),
    );
  }
}
