import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../models/tool_call.dart';

// ── Display-name helper ───────────────────────────────────────────────────────

/// Converts a snake_case tool name to a user-friendly label.
///
/// Examples:
///   "web_search_and_read" → "Web search and read"
///   "get_weather"         → "Get weather"
///   "code_interpreter"    → "Code interpreter"
String _toolLabel(String name) {
  if (name.isEmpty) return 'tool';
  final words = name.split('_');
  final first = words.first;
  final capitalised =
      first[0].toUpperCase() + first.substring(1).toLowerCase();
  if (words.length == 1) return capitalised;
  return '$capitalised ${words.skip(1).join(' ').toLowerCase()}';
}

// ── Public bubble widget ──────────────────────────────────────────────────────

/// Renders an assistant tool-call message or a tool-result message.
class ToolBubble extends StatelessWidget {
  final Message message;
  const ToolBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    if (message.hasToolCalls) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: message.toolCalls!
            .map((call) => _ToolCallCard(call: call))
            .toList(),
      );
    }
    if (message.isToolResult) {
      return _ToolResultCard(message: message);
    }
    return const SizedBox.shrink();
  }
}

// ── Tool-call card ("Performing …") ──────────────────────────────────────────

class _ToolCallCard extends StatefulWidget {
  final ToolCall call;
  const _ToolCallCard({required this.call});

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    String argPreview;
    try {
      argPreview =
          const JsonEncoder.withIndent('  ').convert(widget.call.arguments);
    } catch (_) {
      argPreview = widget.call.arguments.toString();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Container(
        decoration: BoxDecoration(
          color: cs.secondaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: cs.secondary.withValues(alpha: 0.3), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            InkWell(
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(12), bottom: Radius.circular(12)),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.build_outlined,
                        size: 15, color: cs.onSecondaryContainer),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Performing ${_toolLabel(widget.call.name)}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: cs.onSecondaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: cs.onSecondaryContainer,
                    ),
                  ],
                ),
              ),
            ),
            // ── Arguments (expanded) ─────────────────────────────────────────
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: SelectableText(
                  argPreview,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: cs.onSecondaryContainer,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tool-result card ("… result" / "Running …") ───────────────────────────────

class _ToolResultCard extends StatefulWidget {
  final Message message;
  const _ToolResultCard({required this.message});

  @override
  State<_ToolResultCard> createState() => _ToolResultCardState();
}

class _ToolResultCardState extends State<_ToolResultCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final running = widget.message.isStreaming;
    final label = _toolLabel(widget.message.toolName ?? '');
    final contents = widget.message.toolContent ?? [];
    final hasContent = !running &&
        (contents.isNotEmpty || widget.message.content.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.5), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            InkWell(
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(12), bottom: Radius.circular(12)),
              onTap: hasContent
                  ? () => setState(() => _expanded = !_expanded)
                  : null,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    // Spinner while running, checkmark when done
                    if (running)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: cs.primary,
                        ),
                      )
                    else
                      Icon(Icons.check_circle_outline_rounded,
                          size: 15, color: cs.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        running
                            ? 'Running $label\u2026'
                            : '$label result',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (hasContent)
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        color: cs.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),
            // ── Content (expanded) ────────────────────────────────────────────
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (contents.isNotEmpty)
                      ...contents.map((c) => _ContentItem(content: c))
                    else
                      SelectableText(
                        widget.message.content,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Individual content item (text or image) ───────────────────────────────────

class _ContentItem extends StatelessWidget {
  final McpContent content;
  const _ContentItem({required this.content});

  @override
  Widget build(BuildContext context) {
    if (content.type == 'image' && content.imageData != null) {
      try {
        final Uint8List bytes = base64Decode(content.imageData!);
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  const Text('[image decode error]'),
            ),
          ),
        );
      } catch (_) {
        return const Text('[image]');
      }
    }
    final text = content.text ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    return SelectableText(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
    );
  }
}
