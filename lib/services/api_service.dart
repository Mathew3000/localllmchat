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

  // ── Helpers shared by both streaming methods ─────────────────────────────

  Future<http.StreamedResponse> _openStream(String body) async {
    final uri = Uri.parse('$_baseUrl/chat/completions');
    final request = http.Request('POST', uri)
      ..headers.addAll(_headers)
      ..body = body;
    final resp = await request
        .send()
        .timeout(Duration(seconds: settings.requestTimeoutSeconds));
    if (resp.statusCode != 200) {
      final err = await resp.stream.bytesToString();
      throw Exception('API error ${resp.statusCode}: $err');
    }
    return resp;
  }

  Stream<String> _lines(http.StreamedResponse resp) =>
      resp.stream.transform(utf8.decoder).transform(const LineSplitter());

  // ── Plain streaming (no tools) ────────────────────────────────────────────

  /// Streams chat completions without tools. Yields delta text chunks.
  Stream<String> streamChat(List<Message> history) async* {
    final resp = await _openStream(jsonEncode({
      'model': settings.selectedModel,
      'messages': _buildMessages(history, toolsEnabled: false),
      'stream': true,
      'temperature': settings.temperature,
      'max_tokens': settings.maxTokens,
    }));

    await for (final line in _lines(resp)) {
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

  // ── Streaming with tool detection ─────────────────────────────────────────

  /// Streams chat completions when tools are enabled.
  ///
  /// Text tokens are yielded for live rendering. [onComplete] is called
  /// exactly once — after the stream ends — with the full [LlmResponse]
  /// (either the streamed text content, or accumulated tool calls).
  ///
  /// Falls back to plain-JSON parsing if the server ignores `stream:true`
  /// when `tools` is present (common with llama.cpp / some backends).
  Stream<String> streamChatWithTools(
    List<Message> history,
    List<McpToolDef> tools,
    void Function(LlmResponse) onComplete,
  ) async* {
    final resp = await _openStream(jsonEncode({
      'model': settings.selectedModel,
      'messages': _buildMessages(history, toolsEnabled: true),
      'stream': true,
      'temperature': settings.temperature,
      'max_tokens': settings.maxTokens,
      'tools': tools.map((t) => t.toOpenAiTool()).toList(),
      'tool_choice': 'auto',
    }));

    // ── JSON fallback ────────────────────────────────────────────────────────
    // Some backends (llama.cpp, text-generation-webui, …) return a plain JSON
    // chat-completion object instead of SSE when `tools` is in the request,
    // even though we asked for `stream: true`.  Detect via Content-Type and
    // parse the whole body at once so the UI still gets a usable response.
    final contentType = resp.headers['content-type'] ?? '';
    if (!contentType.contains('event-stream')) {
      final body = await resp.stream.bytesToString();
      String text = '';
      List<ToolCall>? toolCalls;
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final choices = json['choices'] as List<dynamic>;
        if (choices.isNotEmpty) {
          final message = (choices[0] as Map<String, dynamic>)['message']
              as Map<String, dynamic>?;
          if (message != null) {
            final rawCalls = message['tool_calls'] as List<dynamic>?;
            if (rawCalls != null && rawCalls.isNotEmpty) {
              toolCalls = rawCalls.map((raw) {
                final c = raw as Map<String, dynamic>;
                final func = c['function'] as Map<String, dynamic>;
                Map<String, dynamic> args;
                try {
                  args = jsonDecode(func['arguments'] as String)
                      as Map<String, dynamic>;
                } catch (_) {
                  args = {};
                }
                return ToolCall(
                  id: c['id'] as String? ?? '',
                  name: func['name'] as String? ?? '',
                  arguments: args,
                );
              }).toList();
            } else {
              text = message['content'] as String? ?? '';
              if (text.isNotEmpty) yield text;
            }
          }
        }
      } catch (_) {}
      onComplete(toolCalls != null
          ? LlmResponse(toolCalls: toolCalls)
          : LlmResponse(content: text));
      return;
    }

    // ── SSE path ─────────────────────────────────────────────────────────────
    final contentBuf = StringBuffer();
    final Map<int, _ToolCallBuilder> builders = {};
    String? finishReason;

    await for (final line in _lines(resp)) {
      if (!line.startsWith('data: ')) continue;
      final data = line.substring(6).trim();
      if (data == '[DONE]') break;
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final choices = json['choices'] as List<dynamic>;
        if (choices.isEmpty) continue;

        final choice = choices[0] as Map<String, dynamic>;
        finishReason = choice['finish_reason'] as String? ?? finishReason;
        final delta = choice['delta'] as Map<String, dynamic>?;
        if (delta == null) continue;

        // Text content — yield for live display
        final content = delta['content'] as String?;
        if (content != null && content.isNotEmpty) {
          contentBuf.write(content);
          yield content;
        }

        // Tool-call deltas — accumulate incrementally
        final rawCalls = delta['tool_calls'] as List<dynamic>?;
        if (rawCalls != null) {
          for (final raw in rawCalls) {
            final c = raw as Map<String, dynamic>;
            final idx = c['index'] as int;
            builders.putIfAbsent(idx, _ToolCallBuilder.new);
            builders[idx]!.update(c);
          }
        }
      } catch (_) {}
    }

    // Deliver the complete response via callback (runs before stream closes).
    if (builders.isNotEmpty &&
        (finishReason == 'tool_calls' || contentBuf.isEmpty)) {
      final sorted = builders.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      onComplete(
          LlmResponse(toolCalls: sorted.map((e) => e.value.build()).toList()));
    } else {
      onComplete(LlmResponse(content: contentBuf.toString()));
    }
  }
}

// ── Private helper: accumulates incremental tool-call deltas ─────────────────

class _ToolCallBuilder {
  String id = '';
  String name = '';
  final StringBuffer _args = StringBuffer();

  void update(Map<String, dynamic> delta) {
    if (delta['id'] != null) id = delta['id'] as String;
    final func = delta['function'] as Map<String, dynamic>?;
    if (func != null) {
      if (func['name'] != null) name += func['name'] as String;
      if (func['arguments'] != null) _args.write(func['arguments'] as String);
    }
  }

  ToolCall build() {
    Map<String, dynamic> args;
    try {
      args = jsonDecode(_args.toString()) as Map<String, dynamic>;
    } catch (_) {
      args = {};
    }
    return ToolCall(id: id, name: name, arguments: args);
  }
}
