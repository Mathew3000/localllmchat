import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/tool_call.dart';
import 'base_mcp_service.dart';

/// HTTP+SSE transport client (legacy MCP transport, used by many servers
/// built before the Streamable-HTTP spec, e.g. mcp-server-fetch, npx-based
/// servers, most Python/Node reference servers).
///
/// Protocol:
///   1. GET /sse  → persistent SSE stream from the server.
///      Server immediately emits:  event: endpoint\ndata: /messages?sessionId=…
///   2. Client POSTs JSON-RPC requests to that endpoint URL.
///   3. Responses arrive as  event: message\ndata: {…}  events on the stream.
class McpSseService extends BaseMcpService {
  @override
  final String baseUrl;

  /// Extra headers injected into every HTTP request (e.g. auth tokens).
  final Map<String, String> extraHeaders;

  McpSseService(this.baseUrl, {Map<String, String>? extraHeaders})
      : extraHeaders = extraHeaders ?? const {};

  final http.Client _client = http.Client();

  // ── Connection state ───────────────────────────────────────────────────────

  bool _connected = false;
  Future<void>? _connectFuture;
  StreamSubscription<String>? _sseSub;

  /// Completer that resolves with the server-provided POST endpoint path
  /// on the initial `endpoint` SSE event.
  Completer<String>? _endpointCompleter;

  String? _postEndpoint;

  // ── In-flight requests ─────────────────────────────────────────────────────

  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _idCounter = 1;

  // ── SSE line-parser state ──────────────────────────────────────────────────

  String _sseEventType = '';
  final StringBuffer _sseBuf = StringBuffer();

  // ── URL helpers ────────────────────────────────────────────────────────────

  String get _sseUrl {
    var url = baseUrl.trimRight();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    // If the user already appended /sse, keep it as-is; otherwise append it.
    if (url.endsWith('/sse')) return url;
    return '$url/sse';
  }

  String _resolveEndpoint(String raw) {
    // Absolute URL — use directly.
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    // Relative path — combine with base URL's scheme/host/port.
    final base =
        Uri.parse(baseUrl.trimRight().replaceAll(RegExp(r'/$'), ''));
    final rel = Uri.parse(raw);
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.port,
      path: rel.path,
      query: rel.hasQuery ? rel.query : null,
    ).toString();
  }

  // ── Connection management ──────────────────────────────────────────────────

  Future<void> _ensureConnected() {
    if (_connected) return Future.value();
    return _connectFuture ??=
        _doConnect().whenComplete(() => _connectFuture = null);
  }

  Future<void> _doConnect() async {
    _endpointCompleter = Completer<String>();

    // 1. Open persistent SSE stream.
    final request = http.Request('GET', Uri.parse(_sseUrl));
    request.headers['Accept'] = 'text/event-stream';
    request.headers['Cache-Control'] = 'no-cache';
    // Inject auth headers (after protocol headers so they can override).
    extraHeaders.forEach((k, v) => request.headers[k] = v);

    final response =
        await _client.send(request).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw McpHttpException(response.statusCode, body);
    }

    _sseEventType = '';
    _sseBuf.clear();

    _sseSub = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onSseLine,
            onDone: _onDisconnect, cancelOnError: false);

    // 2. Wait for the `endpoint` event (server tells us where to POST).
    _postEndpoint = _resolveEndpoint(
      await _endpointCompleter!.future.timeout(const Duration(seconds: 10)),
    );
    _endpointCompleter = null;

    // 3. Send `initialize`.
    final initId = _idCounter++;
    final initCompleter = Completer<Map<String, dynamic>>();
    _pending[initId] = initCompleter;

    await _client
        .post(
          Uri.parse(_postEndpoint!),
          headers: {'Content-Type': 'application/json', ...extraHeaders},
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': initId,
            'method': 'initialize',
            'params': {
              'protocolVersion': '2024-11-05',
              'capabilities': {},
              'clientInfo': {'name': 'LocalLLMChat', 'version': '1.0.0'},
            },
          }),
        )
        .timeout(const Duration(seconds: 10));

    await initCompleter.future.timeout(const Duration(seconds: 10));

    // 4. Fire-and-forget `notifications/initialized`.
    unawaited(
      _client
          .post(
            Uri.parse(_postEndpoint!),
            headers: {'Content-Type': 'application/json', ...extraHeaders},
            body: jsonEncode(
                {'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
          )
          .catchError((_) => http.Response('', 200)),
    );

    _connected = true;
  }

  // ── SSE event parser ───────────────────────────────────────────────────────

  void _onSseLine(String line) {
    if (line.startsWith('event:')) {
      _sseEventType = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      if (_sseBuf.isNotEmpty) _sseBuf.write('\n');
      _sseBuf.write(line.substring(5).trim());
    } else if (line.isEmpty) {
      // Blank line = end of event.
      _dispatchSseEvent(_sseEventType, _sseBuf.toString());
      _sseEventType = '';
      _sseBuf.clear();
    }
    // Ignore `id:`, `:` (comments), and unknown fields.
  }

  void _dispatchSseEvent(String type, String data) {
    if (data.isEmpty) return;

    if (type == 'endpoint') {
      // Deliver the POST endpoint to _doConnect's waiter.
      if (_endpointCompleter?.isCompleted == false) {
        _endpointCompleter!.complete(data);
      }
      return;
    }

    // `message` events (or events with no explicit type) carry JSON-RPC
    // responses; match them to the correct in-flight request by id.
    if (type == 'message' || type.isEmpty) {
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final id = json['id'];
        if (id is int) {
          final completer = _pending.remove(id);
          if (completer != null && !completer.isCompleted) {
            completer.complete(json);
          }
        }
      } catch (_) {}
    }
  }

  void _onDisconnect() {
    _connected = false;
    _sseSub = null;
    _postEndpoint = null;
    // Fail any waiter that is still waiting for the endpoint event.
    if (_endpointCompleter?.isCompleted == false) {
      _endpointCompleter!
          .completeError(Exception('SSE disconnected before endpoint event'));
    }
    _endpointCompleter = null;
    // Fail all in-flight requests.
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(Exception('SSE connection closed'));
    }
    _pending.clear();
  }

  // ── JSON-RPC request ───────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _request(
      String method, Map<String, dynamic> params) async {
    await _ensureConnected();

    final id = _idCounter++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    final resp = await _client
        .post(
          Uri.parse(_postEndpoint!),
          headers: {'Content-Type': 'application/json', ...extraHeaders},
          body: jsonEncode(
              {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}),
        )
        .timeout(const Duration(seconds: 10));

    // 200 (with body) or 202 (accepted, response arrives via SSE) are both ok.
    if (resp.statusCode != 200 && resp.statusCode != 202) {
      _pending.remove(id);
      throw McpHttpException(resp.statusCode, resp.body);
    }

    // Wait for the matching response event to arrive on the SSE stream.
    final result =
        await completer.future.timeout(const Duration(seconds: 30));

    if (result['error'] != null) {
      throw Exception('MCP error: ${result['error']}');
    }
    return result['result'] as Map<String, dynamic>;
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  @override
  Future<List<McpToolDef>> listTools() async {
    final result = await _request('tools/list', {});
    final tools = result['tools'] as List<dynamic>;
    return tools
        .map((t) => McpToolDef.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<McpContent>> callTool(
      String name, Map<String, dynamic> arguments) async {
    final result = await _request(
        'tools/call', {'name': name, 'arguments': arguments});
    final content = result['content'] as List<dynamic>? ?? [];
    return content
        .map((c) => McpContent.fromMcpJson(c as Map<String, dynamic>))
        .toList();
  }

  @override
  void dispose() {
    _sseSub?.cancel();
    _client.close();
  }
}
