import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../models/message.dart';
import 'color_picker.dart' show onColor;

// ── Segment model ────────────────────────────────────────────────────────────

enum _SegmentKind { thinking, content }

class _Segment {
  final _SegmentKind kind;
  final String text;
  /// True when this thinking block has no closing </think> yet (still streaming).
  final bool open;
  const _Segment(this.kind, this.text, {this.open = false});
}

/// Splits [raw] into alternating content / thinking segments.
/// A `<think>` without a matching `</think>` is treated as an open (in-progress) block.
List<_Segment> _parseSegments(String raw) {
  final segments = <_Segment>[];
  int cursor = 0;

  while (cursor < raw.length) {
    final openIdx = raw.indexOf('<think>', cursor);
    if (openIdx == -1) {
      // Remaining text is plain content
      final tail = raw.substring(cursor);
      if (tail.isNotEmpty) segments.add(_Segment(_SegmentKind.content, tail));
      break;
    }

    // Content before <think>
    if (openIdx > cursor) {
      final before = raw.substring(cursor, openIdx);
      if (before.isNotEmpty) segments.add(_Segment(_SegmentKind.content, before));
    }

    final afterOpen = openIdx + '<think>'.length;
    final closeIdx = raw.indexOf('</think>', afterOpen);

    if (closeIdx == -1) {
      // Unclosed — still streaming inside think block
      final thinkText = raw.substring(afterOpen);
      segments.add(_Segment(_SegmentKind.thinking, thinkText, open: true));
      cursor = raw.length;
    } else {
      final thinkText = raw.substring(afterOpen, closeIdx);
      segments.add(_Segment(_SegmentKind.thinking, thinkText));
      cursor = closeIdx + '</think>'.length;
    }
  }

  return segments;
}

/// Returns the displayable text (think blocks stripped) for clipboard copy.
String _strippedContent(String raw) {
  return raw
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '')
      .replaceAll(RegExp(r'<think>[\s\S]*'), '')
      .trim();
}

// ── Public bubble widget ─────────────────────────────────────────────────────

class MessageBubble extends StatelessWidget {
  final Message message;
  /// Custom background colour for user bubbles. Null = theme default.
  final Color? userBubbleColor;
  /// Custom background colour for assistant bubbles. Null = theme default.
  final Color? assistantBubbleColor;
  /// Background colour for ==highlighted== / <mark> spans. Null = amber.
  final Color? highlightColor;

  const MessageBubble({
    super.key,
    required this.message,
    this.userBubbleColor,
    this.assistantBubbleColor,
    this.highlightColor,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == Role.user;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final bubbleBg = isUser
        ? (userBubbleColor ?? colorScheme.primary)
        : (assistantBubbleColor ?? colorScheme.surfaceContainerHigh);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment:
                isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isUser) ...[
                _Avatar(isUser: false, colorScheme: colorScheme),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: GestureDetector(
                  onLongPress: () => _copyToClipboard(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: bubbleBg,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(18),
                        topRight: const Radius.circular(18),
                        bottomLeft: Radius.circular(isUser ? 18 : 4),
                        bottomRight: Radius.circular(isUser ? 4 : 18),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: isUser
                        ? _buildUserContent(context, colorScheme)
                        : _buildAssistantContent(context, theme, highlightColor),
                  ),
                ),
              ),
              if (isUser) ...[
                const SizedBox(width: 8),
                _Avatar(isUser: true, colorScheme: colorScheme),
              ],
            ],
          ),
          // Copy button — indented to align with the bubble edge (past the avatar).
          Padding(
            padding: EdgeInsets.only(
              top: 2,
              left: isUser ? 0 : 36,  // 28 avatar + 8 gap
              right: isUser ? 36 : 0,
            ),
            child: _CopyButton(onTap: () => _copyToClipboard(context)),
          ),
        ],
      ),
    );
  }

  /// Wraps [_AssistantContent] in an adapted [Theme] when a custom bubble
  /// colour is set, so all descendant widgets (markdown, thinking block, etc.)
  /// automatically use legible foreground colours.
  Widget _buildAssistantContent(
      BuildContext context, ThemeData theme, Color? highlightColor) {
    if (assistantBubbleColor == null) {
      return _AssistantContent(
          message: message, highlightColor: highlightColor);
    }

    final bg = assistantBubbleColor!;
    final fg = onColor(bg);
    final fgVariant = fg.withValues(alpha: 0.7);
    final lum = bg.computeLuminance();
    final innerBg = Color.alphaBlend(
      lum > 0.45
          ? Colors.black.withValues(alpha: 0.07)
          : Colors.white.withValues(alpha: 0.10),
      bg,
    );

    return Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          onSurface: fg,
          onSurfaceVariant: fgVariant,
          outlineVariant: fgVariant.withValues(alpha: 0.35),
          surfaceContainerHigh: innerBg,
          surfaceContainerHighest: innerBg,
        ),
      ),
      child: _AssistantContent(
          message: message, highlightColor: highlightColor),
    );
  }

  Widget _buildUserContent(BuildContext context, ColorScheme cs) {
    final textColor =
        userBubbleColor != null ? onColor(userBubbleColor!) : cs.onPrimary;
    final textStyle = TextStyle(color: textColor, fontSize: 15, height: 1.4);
    final hasImages = message.images.isNotEmpty;
    final hasText = message.content.isNotEmpty;

    if (!hasImages) {
      return SelectableText(message.content, style: textStyle);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Images grid (max 2 per row)
        Wrap(
          spacing: 4,
          runSpacing: 4,
          alignment: WrapAlignment.end,
          children: message.images.map((dataUrl) {
            try {
              final base64Data = dataUrl.contains(',')
                  ? dataUrl.split(',').last
                  : dataUrl;
              final bytes = base64Decode(base64Data);
              return ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  bytes,
                  width: 160,
                  height: 160,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
                ),
              );
            } catch (_) {
              return const Icon(Icons.broken_image);
            }
          }).toList(),
        ),
        if (hasText) ...[
          const SizedBox(height: 6),
          SelectableText(message.content, style: textStyle),
        ],
      ],
    );
  }

  void _copyToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: _strippedContent(message.content)));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

// ── Assistant content (segments) ─────────────────────────────────────────────

class _AssistantContent extends StatelessWidget {
  final Message message;
  final Color? highlightColor;
  const _AssistantContent(
      {required this.message, this.highlightColor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Empty bubble before any token arrives
    if (message.content.isEmpty && message.isStreaming) {
      return _TypingIndicator(color: theme.colorScheme.onSurfaceVariant);
    }

    final segments = _parseSegments(message.content);

    // Determine whether the model is currently inside a think block
    final activelyThinking = message.isStreaming &&
        segments.isNotEmpty &&
        segments.last.kind == _SegmentKind.thinking &&
        segments.last.open;

    // Build visible (non-thinking) content segments
    final contentSegments = segments
        .where((s) => s.kind == _SegmentKind.content && s.text.isNotEmpty)
        .toList();

    final thinkingSegments = segments
        .where((s) => s.kind == _SegmentKind.thinking)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Thinking blocks first (they appear above the response)
        for (final seg in thinkingSegments)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ThinkingBlock(
              thinkText: seg.text,
              isStreaming: seg.open && message.isStreaming,
              key: ValueKey('think_${thinkingSegments.indexOf(seg)}'),
            ),
          ),

        // Actual response content
        if (contentSegments.isNotEmpty) ...[
          _MarkdownContent(
            text: contentSegments.map((s) => s.text).join(),
            theme: theme,
            highlightColor: highlightColor,
          ),
        ],

        // Typing dots — only when streaming *outside* a think block
        if (message.isStreaming && !activelyThinking) ...[
          const SizedBox(height: 4),
          _TypingIndicator(color: theme.colorScheme.onSurfaceVariant),
        ],
      ],
    );
  }
}

// ── Markdown highlight syntax: ==text== → <mark> element ─────────────────────

class _MarkSyntax extends md.InlineSyntax {
  _MarkSyntax() : super(r'==([^=\n]+)==');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('mark', match[1]!));
    return true;
  }
}

// ── Builder that renders <mark> elements with highlight bg + contrast text ────

class _MarkBuilder extends MarkdownElementBuilder {
  final Color bg;
  final Color fg;
  _MarkBuilder({required this.bg, required this.fg});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 1),
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        element.textContent,
        style: (preferredStyle ?? const TextStyle()).copyWith(
          color: fg,
          backgroundColor: Colors.transparent,
          fontSize: 15,
          height: 1.4,
        ),
      ),
    );
  }
}

// ── Markdown renderer ─────────────────────────────────────────────────────────

class _MarkdownContent extends StatelessWidget {
  final String text;
  final ThemeData theme;
  /// Highlight background colour. Null = amber (#FFD000).
  final Color? highlightColor;

  const _MarkdownContent({
    required this.text,
    required this.theme,
    this.highlightColor,
  });

  /// Convert <mark>…</mark> HTML tags to ==…== so _MarkSyntax can handle them.
  static String _preprocess(String src) => src.replaceAllMapped(
        RegExp(r'<mark>(.*?)</mark>', caseSensitive: false, dotAll: true),
        (m) => '==${m[1]}==',
      );

  @override
  Widget build(BuildContext context) {
    final highlightBg = highlightColor ?? const Color(0xFFFFD000);
    final highlightFg = onColor(highlightBg);

    return MarkdownBody(
      data: _preprocess(text),
      selectable: true,
      inlineSyntaxes: [_MarkSyntax()],
      builders: {
        'mark': _MarkBuilder(bg: highlightBg, fg: highlightFg),
      },
      onTapLink: (text, href, title) async {
        if (href == null) return;
        final uri = Uri.tryParse(href);
        if (uri == null) return;
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: theme.textTheme.bodyMedium?.copyWith(
          fontSize: 15,
          height: 1.4,
          color: theme.colorScheme.onSurface,
        ),
        code: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          color: theme.colorScheme.onSurface,
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        // Override the default Colors.blue.shade100 which is unreadable in
        // dark mode (white text on pale blue). Use a theme-aware background
        // with a primary-coloured left accent bar instead.
        blockquoteDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
          border: Border(
            left: BorderSide(
              color: theme.colorScheme.primary.withValues(alpha: 0.7),
              width: 3,
            ),
          ),
        ),
        blockquotePadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }
}

// ── Thinking block widget ─────────────────────────────────────────────────────

class _ThinkingBlock extends StatefulWidget {
  final String thinkText;
  /// True while the </think> tag hasn't arrived yet.
  final bool isStreaming;

  const _ThinkingBlock({
    super.key,
    required this.thinkText,
    required this.isStreaming,
  });

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseAnim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    if (widget.isStreaming) _pulseController.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_ThinkingBlock old) {
    super.didUpdateWidget(old);
    if (widget.isStreaming && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isStreaming && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final headerColor = cs.onSurfaceVariant;
    final borderColor = cs.outlineVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header row (always visible) ───────────────────────────────────
        GestureDetector(
          onTap: widget.thinkText.isNotEmpty
              ? () => setState(() => _expanded = !_expanded)
              : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: borderColor.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, child) => Opacity(
                    opacity: widget.isStreaming ? _pulseAnim.value : 1.0,
                    child: child,
                  ),
                  child: Icon(
                    Icons.psychology_outlined,
                    size: 15,
                    color: headerColor,
                  ),
                ),
                const SizedBox(width: 5),
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, child) => Opacity(
                    opacity: widget.isStreaming ? _pulseAnim.value : 1.0,
                    child: child,
                  ),
                  child: Text(
                    widget.isStreaming ? 'Thinking…' : 'Thinking',
                    style: TextStyle(
                      fontSize: 12,
                      color: headerColor,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                if (widget.thinkText.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 14,
                    color: headerColor,
                  ),
                ],
              ],
            ),
          ),
        ),

        // ── Expandable content ────────────────────────────────────────────
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 220),
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          firstChild: const SizedBox.shrink(),
          secondChild: widget.thinkText.isNotEmpty
              ? Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color:
                        cs.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: borderColor.withValues(alpha: 0.4)),
                  ),
                  child: SelectableText(
                    widget.thinkText.trim(),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: cs.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

// ── Typing indicator ──────────────────────────────────────────────────────────

class _TypingIndicator extends StatefulWidget {
  final Color color;
  const _TypingIndicator({required this.color});

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with TickerProviderStateMixin {
  late final List<AnimationController> _controllers;
  late final List<Animation<double>> _animations;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(
      3,
      (i) => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      )..repeat(reverse: true),
    );
    _animations = List.generate(3, (i) {
      Future.delayed(Duration(milliseconds: i * 150), () {
        if (mounted) _controllers[i].repeat(reverse: true);
      });
      return Tween<double>(begin: 0, end: 6).animate(
        CurvedAnimation(parent: _controllers[i], curve: Curves.easeInOut),
      );
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return AnimatedBuilder(
          animation: _animations[i],
          builder: (_, __) => Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            width: 7,
            height: 7 + _animations[i].value,
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
      }),
    );
  }
}

// ── Copy button ───────────────────────────────────────────────────────────────

class _CopyButton extends StatefulWidget {
  final VoidCallback onTap;
  const _CopyButton({required this.onTap});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _handleTap() async {
    widget.onTap();
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: _copied
            ? Icon(Icons.check_rounded,
                key: const ValueKey('check'), size: 14, color: color)
            : Icon(Icons.copy_rounded,
                key: const ValueKey('copy'), size: 14, color: color),
      ),
    );
  }
}

// ── Avatar ────────────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final bool isUser;
  final ColorScheme colorScheme;

  const _Avatar({required this.isUser, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: isUser
            ? colorScheme.primaryContainer
            : colorScheme.secondaryContainer,
        shape: BoxShape.circle,
      ),
      child: Icon(
        isUser ? Icons.person_rounded : Icons.auto_awesome_rounded,
        size: 16,
        color: isUser
            ? colorScheme.onPrimaryContainer
            : colorScheme.onSecondaryContainer,
      ),
    );
  }
}
