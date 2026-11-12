import 'dart:convert';
import 'dart:io' show File;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;

// ── Attached image data class ─────────────────────────────────────────────────

class AttachedImage {
  final Uint8List bytes;
  final String mime; // e.g. "image/jpeg"
  const AttachedImage({required this.bytes, required this.mime});

  /// Converts to a data URL for the API and storage.
  String toDataUrl() => 'data:$mime;base64,${base64Encode(bytes)}';
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

  /// When non-null, a circular context-usage ring is shown beside the send
  /// button. [promptTokens] is the current usage; [contextWindowTokens] is
  /// the configured maximum.
  final int? promptTokens;
  final int? contextWindowTokens;

  // ── Built-in file MCP ────────────────────────────────────────────────────
  /// When true a folder-picker button is shown next to the image button.
  final bool fileMcpEnabled;

  /// Currently selected folder path (null = no folder selected).
  final String? fileMcpFolder;

  /// Called when the user picks a folder; receives the absolute path.
  final ValueChanged<String>? onPickFolder;

  /// Called when the user taps the ✕ on the folder chip to clear the selection.
  final VoidCallback? onClearFolder;

  const ChatInput({
    super.key,
    required this.isStreaming,
    required this.onSend,
    this.onCancel,
    this.messageQueue = const [],
    required this.onRemoveFromQueue,
    required this.onClearQueue,
    this.promptTokens,
    this.contextWindowTokens,
    this.fileMcpEnabled = false,
    this.fileMcpFolder,
    this.onPickFolder,
    this.onClearFolder,
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

  // ── Folder helpers ─────────────────────────────────────────────────────────

  Future<void> _pickFolder() async {
    // On Android, getDirectoryPath() returns a SAF URI string. On desktop it
    // returns a real path. Either way we pass it through unchanged — Dart's
    // Directory API handles both on their respective platforms.
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select folder for AI file access',
    );
    if (path != null && path.isNotEmpty) {
      widget.onPickFolder?.call(path);
    }
  }

  // ── Image helpers ──────────────────────────────────────────────────────────

  /// True on platforms where taking a photo with the camera is supported.
  bool get _hasCameraSupport =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// Entry point for the image button.  Shows a source sheet on mobile;
  /// falls through to the file picker on desktop.
  Future<void> _onImageButtonPressed() async {
    if (_hasCameraSupport) {
      await _showImageSourceSheet();
    } else {
      await _pickImages();
    }
  }

  /// Bottom sheet that lets the user choose between camera and gallery.
  Future<void> _showImageSourceSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take photo'),
              onTap: () {
                Navigator.pop(ctx);
                _capturePhoto();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImages();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Opens the device camera and appends the captured photo.
  Future<void> _capturePhoto() async {
    final photo = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      maxWidth: 1920,
      maxHeight: 1920,
    );
    if (photo == null) return;
    final bytes = await photo.readAsBytes();
    final ext = photo.path.split('.').last.toLowerCase();
    _addImageBytes(bytes, _mimeFromExt(ext));
  }

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

  // ── Clipboard paste (Ctrl+V) ───────────────────────────────────────────────

  static const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

  /// Ctrl+V: attach a copied image (or copied image files) if the clipboard
  /// holds one, otherwise paste text as usual.
  Future<void> _handlePaste() async {
    try {
      // Image files copied in the file explorer.
      final files = await Pasteboard.files();
      final imageFiles = files
          .where((f) => _imageExts
              .contains(p.extension(f).replaceFirst('.', '').toLowerCase()))
          .toList();
      if (imageFiles.isNotEmpty) {
        for (final path in imageFiles) {
          final bytes = await File(path).readAsBytes();
          await _addPastedImage(bytes);
        }
        return;
      }
      // A screenshot or an image copied from a browser / other app.
      final image = await Pasteboard.image;
      if (image != null && image.isNotEmpty) {
        await _addPastedImage(image);
        return;
      }
    } catch (_) {
      // Fall through to a normal text paste.
    }
    await _pasteText();
  }

  /// Keeps PNG/JPEG/GIF/WebP as they are; converts anything else (Windows
  /// gives a BMP) to PNG, which every AI server understands.
  Future<void> _addPastedImage(Uint8List bytes) async {
    final mime = _sniffMime(bytes);
    if (mime != null) {
      _addImageBytes(bytes, mime);
      return;
    }
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      if (data != null) {
        _addImageBytes(data.buffer.asUint8List(), 'image/png');
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That picture couldn't be pasted.")),
      );
    }
  }

  static String? _sniffMime(Uint8List b) {
    if (b.length < 12) return null;
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return 'image/png';
    }
    if (b[0] == 0xFF && b[1] == 0xD8) return 'image/jpeg';
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'image/gif';
    if (b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }

  Future<void> _pasteText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final v = _controller.value;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    _controller.value = TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, text),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
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
    final hasFolder = widget.fileMcpFolder != null;
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

          // ── Folder chip (file MCP) ─────────────────────────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            child: hasFolder
                ? _FolderChip(
                    path: widget.fileMcpFolder!,
                    cs: cs,
                    theme: theme,
                    onClear: widget.onClearFolder,
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
                  message: _hasCameraSupport
                      ? 'Add a picture or take a photo'
                      : 'Add a picture (or paste one with Ctrl+V)',
                  child: IconButton(
                    onPressed: _onImageButtonPressed,
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
              // Folder picker button (file MCP)
              if (widget.fileMcpEnabled)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Tooltip(
                    message: hasFolder
                        ? 'Choose a different folder'
                        : 'Let the AI look at a folder',
                    child: IconButton(
                      onPressed: _pickFolder,
                      icon: Icon(
                        Icons.folder_open_outlined,
                        color: hasFolder
                            ? cs.tertiary
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
                  // Override the paste shortcut so copied pictures are attached.
                  child: Actions(
                    actions: {
                      PasteTextIntent: CallbackAction<PasteTextIntent>(
                        onInvoke: (_) {
                          _handlePaste();
                          return null;
                        },
                      ),
                    },
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
                            : 'Ask anything…',
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
              ),
              const SizedBox(width: 8),
              // Only show once the chat has started using memory.
              if (widget.contextWindowTokens != null &&
                  (widget.promptTokens ?? 0) > 0)
                _ContextRing(
                  promptTokens: widget.promptTokens!,
                  contextWindowTokens: widget.contextWindowTokens!,
                ),
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

// ── Folder chip ───────────────────────────────────────────────────────────────

class _FolderChip extends StatelessWidget {
  final String path;
  final ColorScheme cs;
  final ThemeData theme;
  final VoidCallback? onClear;

  const _FolderChip({
    required this.path,
    required this.cs,
    required this.theme,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    // Show only the last path component so the chip stays compact.
    final label = p.basename(path).isEmpty ? path : p.basename(path);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(Icons.folder_rounded, size: 14, color: cs.tertiary),
          const SizedBox(width: 4),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: cs.tertiaryContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cs.tertiary.withValues(alpha: 0.35)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onTertiaryContainer,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: onClear,
                    child: Icon(
                      Icons.close_rounded,
                      size: 13,
                      color: cs.onTertiaryContainer.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            'the AI can read this folder',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: cs.onSurfaceVariant),
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
      child: Align(
        alignment: Alignment.centerLeft,
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      'Clear all',
                      style:
                          theme.textTheme.labelSmall?.copyWith(color: cs.error),
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
                final label =
                    text.length > 35 ? '${text.substring(0, 35)}…' : text;
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

// ── Context usage ring ────────────────────────────────────────────────────────
//
// A small ring that fills up as the chat gets longer. Numbers are only shown
// on tap, in plain words.

class _ContextRing extends StatelessWidget {
  final int promptTokens;
  final int contextWindowTokens;

  const _ContextRing({
    required this.promptTokens,
    required this.contextWindowTokens,
  });

  String _fmt(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ratio = (promptTokens / contextWindowTokens).clamp(0.0, 1.0);
    final pct = (ratio * 100).round();
    final color = ratio < 0.7
        ? cs.primary
        : ratio < 0.9
            ? cs.tertiary
            : cs.error;

    final message = ratio < 0.7
        ? 'The AI can remember this whole chat ($pct% of its memory used).'
        : ratio < 0.9
            ? 'This chat is getting long ($pct% of the AI\'s memory used). '
                'Consider starting a new chat soon.'
            : 'This chat is almost too long for the AI to remember ($pct%). '
                'Start a new chat for best results.';

    return Tooltip(
      message: 'Chat memory: $pct% used',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '$message\n(${_fmt(promptTokens)} of ${_fmt(contextWindowTokens)} tokens)'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              value: ratio == 0 ? 0.001 : ratio,
              strokeWidth: 3,
              backgroundColor: cs.surfaceContainerHighest,
              color: color,
            ),
          ),
        ),
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
