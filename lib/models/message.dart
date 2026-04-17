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

  Message({
    String? id,
    required this.role,
    this.content = '',
    this.isStreaming = false,
    this.toolCalls,
    this.toolCallId,
    this.toolName,
    this.toolContent,
  }) : id = id ?? const Uuid().v4();

  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;
  bool get isToolResult => role == Role.tool;

  // ── API serialisation ──────────────────────────────────────────────────────

  Map<String, dynamic> toJson() {
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
    return {'role': role.name, 'content': content};
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
    );
  }
}
