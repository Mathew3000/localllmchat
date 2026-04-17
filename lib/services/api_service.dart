import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/message.dart';
import '../models/settings.dart';
import '../models/tool_call.dart';

class ApiService {
  final AppSettings settings;
  final String _url;

  ApiService(this.settings, String activeBaseUrl) : _url = activeBaseUrl;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (settings.apiKey.isNotEmpty)
          'Authorization': 'Bearer ${settings.apiKey}',
      };

  String get _baseUrl {
    var url = _url.trimRight();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    return url;
  }

  List<Map<String, dynamic>> _buildMessages(
    List<Message> history, {
    bool toolsEnabled = false,
  }) {
    final messages = <Map<String, dynamic>>[];
    if (settings.systemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': settings.systemPrompt});
    }
    messages.addAll(
      history
          .where((m) => m.role != Role.system)
          // When not using tools, strip tool-call and tool-result messages —
          // sending them to a plain chat endpoint confuses most backends.
          .where((m) => toolsEnabled || (!m.isToolResult && !m.hasToolCalls))
          .map((m) => m.toJson()),
    );
    return messages;
  }

  Future<List<String>> fetchModels() async {
    final uri = Uri.parse('$_baseUrl/models');
    final response = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch models: ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['data'] as List<dynamic>;
    return list.map((m) => m['id'] as String).toList();
  }

  /// Streams chat completions (no tools). Yields delta text chunks.
  Stream<String> streamChat(List<Message> history) async* {
    final uri = Uri.parse('$_baseUrl/chat/completions');
    final body = jsonEncode({
      'model': settings.selectedModel,
      'messages': _buildMessages(history, toolsEnabled: false),
      'stream': true,
      'temperature': settings.temperature,
      'max_tokens': settings.maxTokens,
    });

    final request = http.Request('POST', uri)
      ..headers.addAll(_headers)
      ..body = body;

    final streamedResponse = await request
        .send()
        .timeout(Duration(seconds: settings.requestTimeoutSeconds));

    if (streamedResponse.statusCode != 200) {
      final errorBody = await streamedResponse.stream.bytesToString();
      throw Exception(
          'API error ${streamedResponse.statusCode}: $errorBody');
    }

    final lineStream = streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lineStream) {
      if (!line.startsWith('data: ')) continue;
      final data = line.substring(6).trim();
      if (data == '[DONE]') break;
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final choices = json['choices'] as List<dynamic>;
        if (choices.isEmpty) continue;
        final delta = choices[0]['delta'] as Map<String, dynamic>?;
        final content = delta?['content'] as String?;
        if (content != null && content.isNotEmpty) yield content;
      } catch (_) {}
    }
  }

  /// Non-streaming call with tools. Returns either tool calls or final text.
  Future<LlmResponse> chatWithTools(
      List<Message> history, List<McpToolDef> tools) async {
    final uri = Uri.parse('$_baseUrl/chat/completions');
    final body = jsonEncode({
      'model': settings.selectedModel,
      'messages': _buildMessages(history, toolsEnabled: true),
      'stream': false,
      'temperature': settings.temperature,
      'max_tokens': settings.maxTokens,
      'tools': tools.map((t) => t.toOpenAiTool()).toList(),
      'tool_choice': 'auto',
    });

    final response = await http
        .post(uri, headers: _headers, body: body)
        .timeout(Duration(seconds: settings.requestTimeoutSeconds));

    if (response.statusCode != 200) {
      throw Exception(
          'API error ${response.statusCode}: ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final choice =
        (json['choices'] as List<dynamic>)[0] as Map<String, dynamic>;
    final message = choice['message'] as Map<String, dynamic>;
    final finishReason = choice['finish_reason'] as String?;

    final rawCalls = message['tool_calls'] as List<dynamic>?;
    if (finishReason == 'tool_calls' ||
        (rawCalls != null && rawCalls.isNotEmpty)) {
      final toolCalls = rawCalls!.map((c) {
        final func = c['function'] as Map<String, dynamic>;
        Map<String, dynamic> args;
        try {
          args = jsonDecode(func['arguments'] as String)
              as Map<String, dynamic>;
        } catch (_) {
          args = {};
        }
        return ToolCall(
          id: c['id'] as String,
          name: func['name'] as String,
          arguments: args,
        );
      }).toList();
      return LlmResponse(toolCalls: toolCalls);
    }

    return LlmResponse(content: message['content'] as String? ?? '');
  }
}
