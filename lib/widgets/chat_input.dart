import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatInput extends StatefulWidget {
  final bool isStreaming;
  final VoidCallback? onCancel;
  final void Function(String) onSend;

  const ChatInput({
    super.key,
    required this.isStreaming,
    required this.onSend,
    this.onCancel,
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

    // Desktop: Enter sends, Shift+Enter inserts a newline.
    // On mobile the soft keyboard never fires physical key events here,
    // so this is effectively a no-op on Android/iOS.
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
    if (text.isEmpty || widget.isStreaming) return;
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

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
      child: Row(
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
                enabled: !widget.isStreaming,
                textCapitalization: TextCapitalization.sentences,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: TextStyle(color: cs.onSurface, fontSize: 15),
                decoration: InputDecoration(
                  hintText: widget.isStreaming ? 'Generating…' : 'Message',
                  hintStyle: TextStyle(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                ),
                // onSubmitted fires on mobile's keyboard "done" action.
                // On desktop this is superseded by the FocusNode key handler.
                onSubmitted: (_) => _submit(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _SendButton(
            isStreaming: widget.isStreaming,
            hasText: _hasText,
            onSend: _submit,
            onCancel: widget.onCancel,
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final bool isStreaming;
  final bool hasText;
  final VoidCallback onSend;
  final VoidCallback? onCancel;

  const _SendButton({
    required this.isStreaming,
    required this.hasText,
    required this.onSend,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (isStreaming) {
      return _CircleButton(
        onTap: onCancel,
        color: cs.error,
        icon: const Icon(Icons.stop_rounded, color: Colors.white, size: 22),
      );
    }

    return _CircleButton(
      onTap: hasText ? onSend : null,
      color: hasText ? cs.primary : cs.surfaceContainerHighest,
      icon: Icon(
        Icons.arrow_upward_rounded,
        color: hasText ? cs.onPrimary : cs.onSurfaceVariant,
        size: 22,
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  final VoidCallback? onTap;
  final Color color;
  final Widget icon;

  const _CircleButton({
    required this.onTap,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
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
    );
  }
}
