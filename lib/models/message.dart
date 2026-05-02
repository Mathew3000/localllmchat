import 'package:uuid/uuid.dart';
import 'tool_call.dart';

enum Role { user, assistant, system, tool }

class Message {
  final String id;
  final Role role;
  String content;
  bool isStreaming;

  // ── Tool-call fields (role == assistant, LLM chose to call tools) ─────────
  final List<ToolCall>? toolCalls;

  // ── Tool-result fields (role == tool) ─────────────────────────────────────
  final String? toolCallId;
  final String? toolName;
  /// MCP content items (may include images). Kept in-memory only.
  List<McpContent>? toolContent;

  // ── Image attachments (user messages only) ─────────────────────────────────
  /// Data-URL strings attached by the user, e.g. `"data:image/jpeg;base64,…"`.
  /// Sent to the model as multimodal content parts.
  final List<String> images;

  Message({
    String? id,
    required this.role,
    this.content = '',
    this.isStreaming = false,
    this.toolCalls,
    this.toolCallId,
    this.toolName,
    this.toolContent,
    this.images = const [],
  }) : id = id ?? const Uuid().v4();

  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;
  bool get isToolResult => role == Role.tool;

  /// Content with `<think>…</think>` blocks stripped.
  ///
  /// Thinking tokens are generated locally for display only; they must not
  /// be echoed back to the LLM as part of the conversation history unless
  /// [preserveThinking] is explicitly requested.
  String get contentForApi {
    return content
        .replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '')
        .replaceAll(RegExp(r'<think>[\s\S]*'), '') // unclosed block
        .trim();
  }

  /// The reasoning content inside the first `<think>…</think>` block, or
  /// null when the message contains no thinking tokens.
  String? get thinkingContent {
    final m = RegExp(r'<think>([\s\S]*?)</think>').firstMatch(content);
    final text = m?.group(1)?.trim();
    return (text != null && text.isNotEmpty) ? text : null;
  }

  // ── API serialisation ──────────────────────────────────────────────────────

  /// Serialises this message for the OpenAI chat/completions API.
  ///
  /// When [preserveThinking] is true, any `<think>…</think>` content from a
  /// previous assistant turn is surfaced as a `reasoning_content` field
  /// (recognised by vLLM / SGLang) rather than stripped entirely.  Servers
  /// that don't understand the extra field simply ignore it.
  Map<String, dynamic> toJson({bool preserveThinking = false}) {
    if (role == Role.tool) {
      return {
        'role': 'tool',
        'tool_call_id': toolCallId,
        'content':
            toolContent?.map((c) => c.toApiText()).join('\n') ?? content,
      };
    }
    if (hasToolCalls) {
      return {
        'role': 'assistant',
        'content': null,
        'tool_calls': toolCalls!.map((t) => t.toApiJson()).toList(),
      };
    }

    // Multimodal: build content array when images are attached.
    if (role == Role.user && images.isNotEmpty) {
      final parts = <Map<String, dynamic>>[];
      for (final img in images) {
        parts.add({'type': 'image_url', 'image_url': {'url': img}});
      }
      final text = contentForApi;
      if (text.isNotEmpty) {
        parts.add({'type': 'text', 'text': text});
      }
      return {'role': 'user', 'content': parts};
    }

    // For assistant messages: optionally preserve thinking as reasoning_content.
    if (role == Role.assistant && preserveThinking) {
      final thinking = thinkingContent;
      if (thinking != null) {
        final apiContent = contentForApi;
        return {
          'role': 'assistant',
          'content': apiContent.isEmpty ? null : apiContent,
          'reasoning_content': thinking,
        };
      }
    }

    // Default: strip thinking blocks so the model doesn't see its own reasoning.
    return {'role': role.name, 'content': contentForApi};
  }

  // ── Storage serialisation ─────────────────────────────────────────────────

  Map<String, dynamic> toStorageJson() {
    if (role == Role.tool) {
      return {
        'id': id,
        'role': 'tool',
        'content': content,
        'toolCallId': toolCallId,
        'toolName': toolName,
        'toolContent':
            toolContent?.map((c) => c.toStorageJson()).toList(),
      };
    }
    if (hasToolCalls) {
      return {
        'id': id,
        'role': 'assistant',
        'content': content,
        'isStreaming': false,
        'toolCalls': toolCalls!.map((t) => t.toStorageJson()).toList(),
      };
    }
    return {
      'id': id,
      'role': role.name,
      'content': content,
      'isStreaming': false,
      if (images.isNotEmpty) 'images': images,
    };
  }

  factory Message.fromStorageJson(Map<String, dynamic> json) {
    final roleStr = json['role'] as String? ?? 'user';
    final role = Role.values.firstWhere(
      (r) => r.name == roleStr,
      orElse: () => Role.user,
    );

    if (role == Role.tool) {
      return Message(
        id: json['id'] as String? ?? const Uuid().v4(),
        role: Role.tool,
        content: json['content'] as String? ?? '',
        toolCallId: json['toolCallId'] as String?,
        toolName: json['toolName'] as String?,
        toolContent: (json['toolContent'] as List<dynamic>?)
            ?.map((c) =>
                McpContent.fromStorageJson(c as Map<String, dynamic>))
            .toList(),
      );
    }

    final rawCalls = json['toolCalls'] as List<dynamic>?;
    return Message(
      id: json['id'] as String? ?? const Uuid().v4(),
      role: role,
      content: json['content'] as String? ?? '',
      toolCalls: rawCalls
          ?.map((t) =>
              ToolCall.fromStorageJson(t as Map<String, dynamic>))
          .toList(),
      images: (json['images'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
    );
  }
}
