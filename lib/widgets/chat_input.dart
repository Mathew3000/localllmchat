import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ── Attached image data class ─────────────────────────────────────────────────

class AttachedImage {
  final Uint8List bytes;
  final String mime; // e.g. "image/jpeg"
  const AttachedImage({required this.bytes, required this.mime});

  /// Converts to a data URL for the API and storage.
  String toDataUrl() =>
      'data:$mime;base64,${base64Encode(bytes)}';
}

// ── Public widget ─────────────────────────────────────────────────────────────

class ChatInput extends StatefulWidget {
  final bool isStreaming;
  final VoidCallback? onCancel;
  final void Function(String text, List<String> images) onSend;

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
  final List<AttachedImage> _images = [];

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

  // ── Image helpers ──────────────────────────────────────────────────────────

  Future<void> _pickImages() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    final picked = <AttachedImage>[];
    for (final f in result.files) {
      if (f.bytes == null) continue;
      final ext = (f.extension ?? 'jpg').toLowerCase();
      final mime = _mimeFromExt(ext);
      picked.add(AttachedImage(bytes: f.bytes!, mime: mime));
    }
    if (picked.isNotEmpty) {
      setState(() => _images.addAll(picked));
    }
  }

  void _addImageBytes(Uint8List bytes, String mime) {
    setState(() => _images.add(AttachedImage(bytes: bytes, mime: mime)));
  }

  void _removeImage(int index) {
    setState(() => _images.removeAt(index));
  }

  static String _mimeFromExt(String ext) {
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      default:
        return 'image/jpeg';
    }
  }

  // ── Send ───────────────────────────────────────────────────────────────────

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty && _images.isEmpty) return;
    final dataUrls = _images.map((img) => img.toDataUrl()).toList();
    widget.onSend(text, dataUrls);
    _controller.clear();
    setState(() => _images.clear());
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasQueue = widget.messageQueue.isNotEmpty;
    final hasImages = _images.isNotEmpty;
    final canSend = _hasText || hasImages;

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
          // ── Queue chip strip ───────────────────────────────────────────────
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

          // ── Image thumbnail strip ──────────────────────────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            child: hasImages
                ? _ImageStrip(
                    images: _images,
                    onRemove: _removeImage,
                  )
                : const SizedBox.shrink(),
          ),

          // ── Text field + buttons ───────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Image attach button
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Tooltip(
                  message: 'Attach image',
                  child: IconButton(
                    onPressed: _pickImages,
                    icon: Icon(
                      Icons.image_outlined,
                      color: hasImages
                          ? cs.primary
                          : cs.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
              // Text field
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
                    textCapitalization: TextCapitalization.sentences,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    style: TextStyle(color: cs.onSurface, fontSize: 15),
                    // Allow Android keyboards (e.g. GBoard) to insert images.
                    contentInsertionConfiguration:
                        ContentInsertionConfiguration(
                      onContentInserted: (KeyboardInsertedContent data) {
                        final bytes = data.data;
                        if (bytes != null) {
                          _addImageBytes(bytes, data.mimeType);
                        }
                      },
                      allowedMimeTypes: const [
                        'image/png',
                        'image/jpeg',
                        'image/gif',
                        'image/webp',
                      ],
                    ),
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
                canSend: canSend,
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

// ── Image thumbnail strip ─────────────────────────────────────────────────────

class _ImageStrip extends StatelessWidget {
  final List<AttachedImage> images;
  final void Function(int) onRemove;

  const _ImageStrip({required this.images, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: images.asMap().entries.map((e) {
            final idx = e.key;
            final img = e.value;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Stack(
                alignment: Alignment.topRight,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      img.bytes,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => onRemove(idx),
                    child: Container(
                      margin: const EdgeInsets.all(3),
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close_rounded,
                          size: 12, color: Colors.white),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
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
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback? onCancel;

  const _ActionButton({
    required this.isStreaming,
    required this.canSend,
    required this.onSend,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Streaming + can send → queue button
    if (isStreaming && canSend) {
      return _CircleButton(
        onTap: onSend,
        color: cs.secondary,
        icon: const Icon(Icons.playlist_add_rounded,
            color: Colors.white, size: 22),
        tooltip: 'Add to queue',
      );
    }

    // Streaming + nothing to send → stop button
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
      onTap: canSend ? onSend : null,
      color: canSend ? cs.primary : cs.surfaceContainerHighest,
      icon: Icon(
        Icons.arrow_upward_rounded,
        color: canSend ? cs.onPrimary : cs.onSurfaceVariant,
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
          child: Center(child: icon),
        ),
      ),
    );
  }
}
