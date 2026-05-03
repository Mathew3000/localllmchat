import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, WebSocket;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web_socket_channel/io.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import '../models/tool_call.dart';

// ── WebSocket event hierarchy ─────────────────────────────────────────────────

sealed class BackendEvent {
  const BackendEvent();
}

class BEGenerationStart extends BackendEvent {
  final String conversationId;
  final String messageId;
  const BEGenerationStart(
      {required this.conversationId, required this.messageId});
}

class BEToken extends BackendEvent {
  final String conversationId;
  final String messageId;
  final String content;
  const BEToken(
      {required this.conversationId,
      required this.messageId,
      required this.content});
}

class BEMessageComplete extends BackendEvent {
  final String conversationId;
  final Map<String, dynamic> message;
  final int? promptTokens;
  final int? completionTokens;
  const BEMessageComplete({
    required this.conversationId,
    required this.message,
    this.promptTokens,
    this.completionTokens,
  });
}

class BEError extends BackendEvent {
  final String? conversationId;
  final String detail;
  const BEError({this.conversationId, required this.detail});
}

class BECancelled extends BackendEvent {
  final String conversationId;
  const BECancelled({required this.conversationId});
}

class BEToolCall extends BackendEvent {
  final String conversationId;
  final String messageId;
  final String callId;
  final String name;
  /// Raw JSON string of the tool arguments.
  final String arguments;
  const BEToolCall({
    required this.conversationId,
    required this.messageId,
    required this.callId,
    required this.name,
    required this.arguments,
  });
}

// ── Service ───────────────────────────────────────────────────────────────────

class BackendService {
  final String baseUrl;
  final String token;
  final bool allowSelfSigned;

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _pingTimer;
  bool _disposed = false;

  final _events = StreamController<BackendEvent>.broadcast();

  Stream<BackendEvent> get events => _events.stream;
  bool get isConnected => _channel != null;

  BackendService({
    required this.baseUrl,
    required this.token,
    this.allowSelfSigned = false,
  });

  // ── URL helpers ───────────────────────────────────────────────────────────

  String get _base =>
      baseUrl.trimRight().replaceAll(RegExp(r'/$'), '');

  String get _wsUrl {
    final base = _base
        .replaceFirst(RegExp(r'^https://'), 'wss://')
        .replaceFirst(RegExp(r'^http://'), 'ws://');
    return '$base/ws?token=${Uri.encodeComponent(token)}';
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

  // ── HTTP client (supports self-signed certs) ──────────────────────────────

  http.Client _httpClient() {
    if (allowSelfSigned) {
      final inner = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      return IOClient(inner);
    }
    return http.Client();
  }

  // ── Auth (static — no token required) ────────────────────────────────────

  static Future<String> loginStatic(
    String baseUrl,
    String username,
    String password, {
    bool allowSelfSigned = false,
  }) =>
      _authCall(baseUrl, 'login', username, password,
          allowSelfSigned: allowSelfSigned);

  static Future<String> registerStatic(
    String baseUrl,
    String username,
    String password, {
    bool allowSelfSigned = false,
  }) =>
      _authCall(baseUrl, 'register', username, password,
          allowSelfSigned: allowSelfSigned);

  static Future<String> _authCall(
    String baseUrl,
    String endpoint,
    String username,
    String password, {
    bool allowSelfSigned = false,
  }) async {
    final base = baseUrl.trimRight().replaceAll(RegExp(r'/$'), '');
    http.Client client;
    if (allowSelfSigned) {
      final inner = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      client = IOClient(inner);
    } else {
      client = http.Client();
    }
    try {
      final resp = await client
          .post(
            Uri.parse('$base/api/auth/$endpoint'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        return jsonDecode(resp.body)['access_token'] as String;
      }
      String? detail;
      try {
        detail = jsonDecode(resp.body)['detail'] as String?;
      } catch (_) {}
      throw Exception(detail ?? 'Authentication failed (${resp.statusCode})');
    } finally {
      client.close();
    }
  }

  // ── WebSocket lifecycle ───────────────────────────────────────────────────

  Future<void> connect() async {
    if (_channel != null) return;
    try {
      final IOWebSocketChannel ch;
      if (allowSelfSigned) {
        final inner = HttpClient()
          ..badCertificateCallback = (cert, host, port) => true;
        final raw = await WebSocket.connect(_wsUrl, customClient: inner);
        ch = IOWebSocketChannel(raw);
      } else {
        ch = IOWebSocketChannel.connect(Uri.parse(_wsUrl));
      }
      _channel = ch;

      _wsSub = ch.stream.listen(
        _onMessage,
        onDone: _onDone,
        onError: (Object e) {
          if (!_disposed) _events.add(BEError(detail: e.toString()));
        },
        cancelOnError: false,
      );

      // Keep-alive ping every 30 s
      _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        _send({'type': 'ping'});
      });
    } catch (e) {
      _channel = null;
      rethrow;
    }
  }

  void disconnect() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _wsSub?.cancel();
    _wsSub = null;
    _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    _disposed = true;
    disconnect();
    if (!_events.isClosed) _events.close();
  }

  void _send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (_) {}
  }

  void _onMessage(dynamic raw) {
    if (_disposed) return;
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (msg['type'] as String?) {
        case 'generation_start':
          _events.add(BEGenerationStart(
            conversationId: msg['conversation_id'] as String,
            messageId: msg['message_id'] as String,
          ));
        case 'token':
          _events.add(BEToken(
            conversationId: msg['conversation_id'] as String,
            messageId: msg['message_id'] as String,
            content: msg['content'] as String,
          ));
        case 'message_complete':
          final usage = msg['usage'] as Map<String, dynamic>?;
          _events.add(BEMessageComplete(
            conversationId: msg['conversation_id'] as String,
            message: msg['message'] as Map<String, dynamic>,
            promptTokens: usage?['prompt_tokens'] as int?,
            completionTokens: usage?['completion_tokens'] as int?,
          ));
        case 'error':
          _events.add(BEError(
            conversationId: msg['conversation_id'] as String?,
            detail: msg['detail'] as String? ?? 'Unknown error',
          ));
        case 'cancelled':
          _events.add(BECancelled(
            conversationId: msg['conversation_id'] as String,
          ));
        case 'tool_call':
          _events.add(BEToolCall(
            conversationId: msg['conversation_id'] as String,
            messageId: msg['message_id'] as String,
            callId: msg['call_id'] as String,
            name: msg['name'] as String,
            arguments: msg['arguments'] as String? ?? '{}',
          ));
        case 'pong':
          break; // ignore keepalive replies
      }
    } catch (_) {}
  }

  void _onDone() {
    _channel = null;
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  // ── Messaging ─────────────────────────────────────────────────────────────

  Future<void> ensureConnected() async {
    if (_channel == null) await connect();
  }

  Future<void> sendMessage(
    String conversationId,
    String content,
    List<String> images, {
    String? messageId,
    List<Map<String, dynamic>> tools = const [],
    String? memoryContext,
  }) async {
    await ensureConnected();
    _send({
      'type': 'send_message',
      'conversation_id': conversationId,
      'content': content,
      'images': images,
      if (messageId != null) 'message_id': messageId,
      if (tools.isNotEmpty) 'tools': tools,
      if (memoryContext != null && memoryContext.isNotEmpty)
        'memory_context': memoryContext,
    });
  }

  /// Send a tool-execution result back to the backend (MCP relay).
  Future<void> sendToolResult(
    String conversationId,
    String callId,
    String content, {
    bool isError = false,
  }) async {
    await ensureConnected();
    _send({
      'type': 'tool_result',
      'conversation_id': conversationId,
      'call_id': callId,
      'content': content,
      'is_error': isError,
    });
  }

  void cancelGeneration(String conversationId) {
    _send({'type': 'cancel', 'conversation_id': conversationId});
  }

  // ── REST: Conversations ───────────────────────────────────────────────────

  Future<List<Conversation>> fetchConversations() async {
    final client = _httpClient();
    try {
      final resp = await client
          .get(Uri.parse('$_base/api/conversations'), headers: _headers)
          .timeout(const Duration(seconds: 15));
      _check(resp);
      final list = jsonDecode(resp.body) as List<dynamic>;
      return list
          .map((j) => _convFromJson(j as Map<String, dynamic>))
          .toList();
    } finally {
      client.close();
    }
  }

  Future<Conversation> fetchConversation(String id) async {
    final client = _httpClient();
    try {
      final resp = await client
          .get(Uri.parse('$_base/api/conversations/$id'), headers: _headers)
          .timeout(const Duration(seconds: 15));
      _check(resp);
      return _convFromJson(jsonDecode(resp.body) as Map<String, dynamic>,
          withMessages: true);
    } finally {
      client.close();
    }
  }

  Future<Conversation> createConversation({
    String? id,
    String title = 'New Chat',
    bool isSecret = false,
    int? userBubbleColor,
    int? assistantBubbleColor,
  }) async {
    final client = _httpClient();
    try {
      final resp = await client
          .post(
            Uri.parse('$_base/api/conversations'),
            headers: _headers,
            body: jsonEncode({
              'title': title,
              if (id != null) 'id': id,
              'is_secret': isSecret,
              if (userBubbleColor != null) 'user_bubble_color': userBubbleColor,
              if (assistantBubbleColor != null)
                'assistant_bubble_color': assistantBubbleColor,
            }),
          )
          .timeout(const Duration(seconds: 15));
      _check(resp);
      return _convFromJson(jsonDecode(resp.body) as Map<String, dynamic>);
    } finally {
      client.close();
    }
  }

  Future<void> patchConversation(String id, Map<String, dynamic> fields) async {
    final client = _httpClient();
    try {
      final resp = await client
          .patch(
            Uri.parse('$_base/api/conversations/$id'),
            headers: _headers,
            body: jsonEncode(fields),
          )
          .timeout(const Duration(seconds: 15));
      _check(resp);
    } finally {
      client.close();
    }
  }

  Future<void> renameConversation(String id, String title) =>
      patchConversation(id, {'title': title});

  Future<void> deleteConversation(String id) async {
    final client = _httpClient();
    try {
      final resp = await client
          .delete(Uri.parse('$_base/api/conversations/$id'), headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 204 && resp.statusCode != 404) {
        throw Exception('Delete failed: ${resp.statusCode}');
      }
    } finally {
      client.close();
    }
  }

  Future<void> addMessage(String convId, Message msg) async {
    final client = _httpClient();
    try {
      final body = <String, dynamic>{
        'id': msg.id,
        'role': msg.role.name,
        'content': msg.content,
        'images': msg.images,
        if (msg.toolCallId != null) 'tool_call_id': msg.toolCallId,
        if (msg.toolCalls != null)
          'tool_calls': msg.toolCalls!.map((t) => t.toApiJson()).toList(),
      };
      final resp = await client
          .post(
            Uri.parse('$_base/api/conversations/$convId/messages'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      _check(resp);
    } finally {
      client.close();
    }
  }

  Future<void> deleteMessage(String convId, String msgId) async {
    final client = _httpClient();
    try {
      final resp = await client
          .delete(
            Uri.parse('$_base/api/conversations/$convId/messages/$msgId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 204 && resp.statusCode != 404) {
        throw Exception('Delete failed: ${resp.statusCode}');
      }
    } finally {
      client.close();
    }
  }

  // ── REST: Settings ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> fetchSettings() async {
    final client = _httpClient();
    try {
      final resp = await client
          .get(Uri.parse('$_base/api/settings'), headers: _headers)
          .timeout(const Duration(seconds: 15));
      _check(resp);
      return (jsonDecode(resp.body) as Map<String, dynamic>)['data']
          as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<void> pushSettings(Map<String, dynamic> data) async {
    final client = _httpClient();
    try {
      final resp = await client
          .put(
            Uri.parse('$_base/api/settings'),
            headers: _headers,
            body: jsonEncode({'data': data}),
          )
          .timeout(const Duration(seconds: 15));
      _check(resp);
    } finally {
      client.close();
    }
  }

  // ── REST: Models ──────────────────────────────────────────────────────────

  Future<List<String>> fetchModels() async {
    final client = _httpClient();
    try {
      final resp = await client
          .get(Uri.parse('$_base/api/models'), headers: _headers)
          .timeout(const Duration(seconds: 15));
      _check(resp);
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = data['data'] as List<dynamic>;
      return list.map((m) => m['id'] as String).toList();
    } finally {
      client.close();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _check(http.Response resp) {
    if (resp.statusCode >= 400) {
      String? detail;
      try {
        detail = (jsonDecode(resp.body) as Map<String, dynamic>)['detail']
            as String?;
      } catch (_) {}
      throw Exception(detail ?? 'HTTP ${resp.statusCode}');
    }
  }

  /// Parse a backend (snake_case) conversation JSON into a [Conversation].
  static Conversation _convFromJson(
    Map<String, dynamic> j, {
    bool withMessages = false,
  }) {
    final messagesRaw = j['messages'] as List<dynamic>? ?? [];
    final messages = withMessages
        ? messagesRaw
            .map((m) => _msgFromJson(m as Map<String, dynamic>))
            .toList()
        : <Message>[];

    // Second pass: derive toolName for tool-result messages by looking up the
    // call id in preceding assistant tool-call messages.  toolName is not
    // persisted on the backend — it's a display-only field computed here.
    if (withMessages && messages.isNotEmpty) {
      final callNames = <String, String>{};
      for (final msg in messages) {
        if (msg.hasToolCalls) {
          for (final tc in msg.toolCalls!) {
            if (tc.id.isNotEmpty && tc.name.isNotEmpty) {
              callNames[tc.id] = tc.name;
            }
          }
        }
      }
      for (int i = 0; i < messages.length; i++) {
        final msg = messages[i];
        if (msg.isToolResult &&
            msg.toolCallId != null &&
            msg.toolName == null) {
          final name = callNames[msg.toolCallId!];
          if (name != null) {
            messages[i] = Message(
              id: msg.id,
              role: msg.role,
              content: msg.content,
              toolCallId: msg.toolCallId,
              toolName: name,
              images: msg.images,
            );
          }
        }
      }
    }

    return Conversation(
      id: j['id'] as String,
      title: j['title'] as String,
      messages: messages,
      createdAt: DateTime.parse(j['created_at'] as String),
      updatedAt: DateTime.parse(j['updated_at'] as String),
      isSecret: j['is_secret'] as bool? ?? false,
      userBubbleColor: j['user_bubble_color'] as int?,
      assistantBubbleColor: j['assistant_bubble_color'] as int?,
    );
  }

  /// Parse a backend (snake_case) message JSON into a [Message].
  static Message _msgFromJson(Map<String, dynamic> j) {
    final roleStr = j['role'] as String? ?? 'user';
    final role = Role.values.firstWhere(
      (r) => r.name == roleStr,
      orElse: () => Role.user,
    );
    // tool_calls are stored in OpenAI wire format on the backend.
    final rawCalls = j['tool_calls'] as List<dynamic>?;
    final toolCalls = rawCalls
        ?.map((t) => ToolCall.fromApiJson(t as Map<String, dynamic>))
        .where((tc) => tc.id.isNotEmpty)
        .toList();
    return Message(
      id: j['id'] as String,
      role: role,
      content: j['content'] as String? ?? '',
      toolCallId: j['tool_call_id'] as String?,
      toolCalls: (toolCalls != null && toolCalls.isNotEmpty) ? toolCalls : null,
      images:
          (j['images'] as List<dynamic>?)?.map((e) => e as String).toList() ??
              const [],
    );
  }
}
