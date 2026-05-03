import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import '../models/message.dart';
import '../models/settings.dart';
import '../models/tool_call.dart';
import 'debug_logger.dart';

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
    // Build system prompt, optionally appending current date/time.
    final systemBase = settings.systemPrompt;
    final dateTimeSuffix = settings.injectDateTime
        ? '\n\nCurrent date and time: ${DateFormat("EEEE, d MMMM yyyy, HH:mm").format(DateTime.now())}'
        : '';
    final systemContent = '$systemBase$dateTimeSuffix'.trim();
    if (systemContent.isNotEmpty) {
      messages.add({'role': 'system', 'content': systemContent});
    }
    messages.addAll(
      history
          .where((m) => m.role != Role.system)
          // When not using tools, strip tool-call and tool-result messages —
          // sending them to a plain chat endpoint confuses most backends.
          .where((m) => toolsEnabled || (!m.isToolResult && !m.hasToolCalls))
          // Drop thinking-only assistant messages (empty after stripping
          // <think> blocks) — the model shouldn't see its own reasoning.
          .where((m) {
            if (m.role == Role.assistant && !m.hasToolCalls) {
              return m.contentForApi.isNotEmpty;
            }
            return true;
          })
          .map((m) => m.toJson(preserveThinking: settings.preserveThinking)),
    );
    return messages;
  }

  Future<List<String>> fetchModels() async {
    final uri = Uri.parse('$_baseUrl/models');
    DebugLogger.instance.logRequest('LLM', 'GET', uri.toString(), '');
    final response = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 10));
    DebugLogger.instance.logResponse('LLM', uri.toString(), response.statusCode, response.body);
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
    DebugLogger.instance.logRequest('LLM', 'POST', uri.toString(), body);
    final request = http.Request('POST', uri)
      ..headers.addAll(_headers)
      ..body = body;
    final resp = await request
        .send()
        .timeout(Duration(seconds: settings.requestTimeoutSeconds));
    if (resp.statusCode != 200) {
      final err = await resp.stream.bytesToString();
      DebugLogger.instance.logResponse('LLM', uri.toString(), resp.statusCode, err);
      throw Exception('API error ${resp.statusCode}: $err');
    }
    return resp;
  }

  Stream<String> _lines(http.StreamedResponse resp) =>
      resp.stream.transform(utf8.decoder).transform(const LineSplitter());

  // ── Plain streaming (no tools) ────────────────────────────────────────────

  /// Streams chat completions without tools. Yields delta text chunks.
  ///
  /// Handles thinking models (e.g. Qwen3): `reasoning_content` deltas are
  /// wrapped in `<think>…</think>` so the bubble widget renders them as a
  /// collapsible thinking block.
  ///
  /// [onUsage] is called once after the stream ends with prompt and completion
  /// token counts (when the backend includes usage data).
  Stream<String> streamChat(
    List<Message> history, {
    void Function(int prompt, int completion)? onUsage,
  }) async* {
    final endpoint = '$_baseUrl/chat/completions';
    final resp = await _openStream(jsonEncode({
      'model': settings.selectedModel,
      'messages': _buildMessages(history, toolsEnabled: false),
      'stream': true,
      'temperature': settings.temperature,
      'max_tokens': settings.maxTokens,
    }));

    bool inThinking = false;
    bool thinkingClosed = false;
    int? promptTokensOut;
    int? completionTokensOut;
    final rawBuf = DebugLogger.instance.enabled ? StringBuffer() : null;

    try {
      await for (final line in _lines(resp)) {
        rawBuf?.writeln(line);
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;

          // Capture usage when present (may appear in a chunk with empty choices).
          final usage = json['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            promptTokensOut = usage['prompt_tokens'] as int?;
            completionTokensOut = usage['completion_tokens'] as int?;
          }

          final choices = json['choices'] as List<dynamic>;
          if (choices.isEmpty) continue;
          final delta = choices[0]['delta'] as Map<String, dynamic>?;
          if (delta == null) continue;

          final reasoning = delta['reasoning_content'] as String?;
          final content = delta['content'] as String?;

          if (reasoning != null && reasoning.isNotEmpty) {
            if (!inThinking) {
              yield '<think>';
              inThinking = true;
            }
            yield reasoning;
          }
          if (content != null && content.isNotEmpty) {
            if (inThinking && !thinkingClosed) {
              yield '</think>';
              thinkingClosed = true;
            }
            yield content;
          }
        } catch (_) {}
      }
    } finally {
      if (rawBuf != null) {
        DebugLogger.instance.logResponse('LLM', endpoint, 200, rawBuf.toString());
      }
      if (promptTokensOut != null && completionTokensOut != null) {
        onUsage?.call(promptTokensOut, completionTokensOut);
      }
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
    final endpoint = '$_baseUrl/chat/completions';
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
      DebugLogger.instance.logResponse('LLM', endpoint, 200, body);
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
              final reasoning = message['reasoning_content'] as String?;
              final body = message['content'] as String? ?? '';
              text = (reasoning != null && reasoning.isNotEmpty)
                  ? '<think>$reasoning</think>$body'
                  : body;
              if (text.isNotEmpty) yield text;
            }
          }
        }
      } catch (_) {}
      // Capture usage from the JSON fallback response.
      int? fbPrompt;
      int? fbCompletion;
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final u = json['usage'] as Map<String, dynamic>?;
        if (u != null) {
          fbPrompt = u['prompt_tokens'] as int?;
          fbCompletion = u['completion_tokens'] as int?;
        }
      } catch (_) {}
      onComplete(toolCalls != null
          ? LlmResponse(toolCalls: toolCalls, promptTokens: fbPrompt, completionTokens: fbCompletion)
          : LlmResponse(content: text, promptTokens: fbPrompt, completionTokens: fbCompletion));
      return;
    }

    // ── SSE path ─────────────────────────────────────────────────────────────
    final contentBuf = StringBuffer(); // actual response text (not thinking)
    final Map<int, _ToolCallBuilder> builders = {};
    String? finishReason;
    bool inThinking = false;
    bool thinkingClosed = false;
    int? promptTokensOut;
    int? completionTokensOut;
    final rawBuf = DebugLogger.instance.enabled ? StringBuffer() : null;

    try {
      await for (final line in _lines(resp)) {
        rawBuf?.writeln(line);
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;

          // Capture usage (may arrive in a chunk with empty choices).
          final usage = json['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            promptTokensOut = usage['prompt_tokens'] as int?;
            completionTokensOut = usage['completion_tokens'] as int?;
          }

          final choices = json['choices'] as List<dynamic>;
          if (choices.isEmpty) continue;

          final choice = choices[0] as Map<String, dynamic>;
          finishReason = choice['finish_reason'] as String? ?? finishReason;
          final delta = choice['delta'] as Map<String, dynamic>?;
          if (delta == null) continue;

          // Thinking tokens (Qwen3 / reasoning models) — wrap in <think> tags
          final reasoning = delta['reasoning_content'] as String?;
          if (reasoning != null && reasoning.isNotEmpty) {
            if (!inThinking) {
              yield '<think>';
              inThinking = true;
            }
            yield reasoning;
          }

          // Actual response content — close any open think block first
          final content = delta['content'] as String?;
          if (content != null && content.isNotEmpty) {
            if (inThinking && !thinkingClosed) {
              yield '</think>';
              thinkingClosed = true;
            }
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
    } finally {
      if (rawBuf != null) {
        DebugLogger.instance.logResponse('LLM', endpoint, 200, rawBuf.toString());
      }
    }

    // Deliver the complete response via callback (runs before stream closes).
    // Use contentBuf (actual text only) to decide tool-call vs text response —
    // reasoning tokens alone must not prevent tool-call detection.
    if (builders.isNotEmpty &&
        (finishReason == 'tool_calls' || contentBuf.isEmpty)) {
      final sorted = builders.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      onComplete(LlmResponse(
        toolCalls: sorted.map((e) => e.value.build()).toList(),
        promptTokens: promptTokensOut,
        completionTokens: completionTokensOut,
      ));
    } else {
      onComplete(LlmResponse(
        content: contentBuf.toString(),
        promptTokens: promptTokensOut,
        completionTokens: completionTokensOut,
      ));
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
