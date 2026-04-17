import 'dart:convert';

/// A tool definition fetched from the MCP server, forwarded to the LLM.
class McpToolDef {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const McpToolDef({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  /// OpenAI `tools` array format.
  Map<String, dynamic> toOpenAiTool() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': inputSchema,
        },
      };

  factory McpToolDef.fromJson(Map<String, dynamic> json) => McpToolDef(
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        inputSchema: json['inputSchema'] as Map<String, dynamic>? ??
            {'type': 'object', 'properties': {}},
      );
}

/// A tool call chosen by the LLM (parsed from an OpenAI response).
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  /// Format sent back to the LLM in the next round.
  Map<String, dynamic> toApiJson() => {
        'id': id,
        'type': 'function',
        'function': {
          'name': name,
          'arguments': jsonEncode(arguments),
        },
      };

  Map<String, dynamic> toStorageJson() =>
      {'id': id, 'name': name, 'arguments': arguments};

  factory ToolCall.fromStorageJson(Map<String, dynamic> json) => ToolCall(
        id: json['id'] as String,
        name: json['name'] as String,
        arguments:
            (json['arguments'] as Map<String, dynamic>?) ?? {},
      );
}

/// A single content item in a tool result (text or image).
class McpContent {
  final String type; // 'text' | 'image'
  final String? text;
  /// Base64-encoded image bytes. In-memory only — not persisted.
  final String? imageData;
  final String? mimeType;

  const McpContent({
    required this.type,
    this.text,
    this.imageData,
    this.mimeType,
  });

  factory McpContent.fromMcpJson(Map<String, dynamic> json) => McpContent(
        type: json['type'] as String? ?? 'text',
        text: json['text'] as String?,
        imageData: json['data'] as String?,
        mimeType: json['mimeType'] as String?,
      );

  /// Text representation sent back to the LLM.
  String toApiText() => type == 'text' ? (text ?? '') : '[image]';

  /// Stored without image data (images are display-only in-memory).
  Map<String, dynamic> toStorageJson() => {'type': type, 'text': text};

  factory McpContent.fromStorageJson(Map<String, dynamic> json) => McpContent(
        type: json['type'] as String? ?? 'text',
        text: json['text'] as String?,
      );
}

/// Parsed response from the LLM — either tool calls or final text.
class LlmResponse {
  final String? content;
  final List<ToolCall>? toolCalls;

  const LlmResponse({this.content, this.toolCalls});

  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;
}
