import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/tool_call.dart';
import 'base_mcp_service.dart';
import 'debug_logger.dart';

/// HTTP client for a Local-MCP-server instance (Streamable-HTTP transport).
///
/// Protocol flow:
///   1. POST /mcp  with `initialize`  → server returns Mcp-Session-Id header
///   2. POST /mcp  with `notifications/initialized`  (no response body needed)
///   3. All subsequent POSTs carry `Mcp-Session-Id: <id>`
class McpService extends BaseMcpService {
  @override
  final String baseUrl;

  /// Extra headers injected into every request (e.g. auth tokens).
  /// These are merged after the protocol headers so they can override defaults.
  final Map<String, String> extraHeaders;

  /// Label used in debug log entries to identify this server.
  final String tag;

  McpService(this.baseUrl, {Map<String, String>? extraHeaders, String? tag})
      : extraHeaders = extraHeaders ?? const {},
        tag = tag != null ? 'MCP[$tag]' : 'MCP';

  String? _sessionId;

  String get _endpoint {
    var url = baseUrl.trimRight();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (url.endsWith('/mcp')) return url;
    return '$url/mcp';
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
        ...extraHeaders,
      };

  // ── Session handshake ───────────────────────────────────────────────────────

  Future<void> _ensureSession() async {
    if (_sessionId != null) return;

    // 1. initialize  (use _headers so custom auth headers are included)
    final initResp = await http
        .post(
          Uri.parse(_endpoint),
          headers: _headers,
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': DateTime.now().millisecondsSinceEpoch,
            'method': 'initialize',
            'params': {
              'protocolVersion': '2024-11-05',
              'capabilities': {},
              'clientInfo': {'name': 'LoomChat', 'version': '1.0.0'},
            },
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (initResp.statusCode != 200) {
      throw McpHttpException(initResp.statusCode, initResp.body);
    }

    _sessionId = initResp.headers['mcp-session-id'];

    // 2. notifications/initialized  (fire-and-forget, ignore errors)
    try {
      await http
          .post(
            Uri.parse(_endpoint),
            headers: _headers,
            body: jsonEncode({
              'jsonrpc': '2.0',
              'method': 'notifications/initialized',
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // notification delivery is best-effort
    }
  }

  // ── Core request ────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    await _ensureSession();

    final reqBody = jsonEncode({
      'jsonrpc': '2.0',
      'id': DateTime.now().millisecondsSinceEpoch,
      ...body,
    });
    DebugLogger.instance.logRequest(tag, 'POST', _endpoint, reqBody);

    final response = await http
        .post(
          Uri.parse(_endpoint),
          headers: _headers,
          body: reqBody,
        )
        .timeout(const Duration(seconds: 30));

    DebugLogger.instance.logResponse(tag, _endpoint, response.statusCode, response.body);

    // Session expired — reset and retry once.
    if (response.statusCode == 400 && response.body.contains('session')) {
      _sessionId = null;
      await _ensureSession();
      return _post(body);
    }

    if (response.statusCode != 200) {
      throw McpHttpException(response.statusCode, response.body);
    }

    // Server may reply with plain JSON or SSE (data: {...}\n\n).
    final contentType = response.headers['content-type'] ?? '';
    String jsonBody;
    if (contentType.contains('text/event-stream')) {
      final dataLine = response.body
          .split('\n')
          .map((l) => l.trim())
          .firstWhere(
            (l) => l.startsWith('data:') && l.length > 5,
            orElse: () => '',
          );
      if (dataLine.isEmpty) throw Exception('MCP: empty SSE response');
      jsonBody = dataLine.substring(5).trim();
    } else {
      jsonBody = response.body;
    }

    final json = jsonDecode(jsonBody) as Map<String, dynamic>;
    if (json['error'] != null) {
      throw Exception('MCP error: ${json['error']}');
    }
    return json['result'] as Map<String, dynamic>;
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Returns all tools advertised by the server.
  @override
  Future<List<McpToolDef>> listTools() async {
    final result = await _post({'method': 'tools/list', 'params': {}});
    final tools = result['tools'] as List<dynamic>;
    return tools
        .map((t) => McpToolDef.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  /// Calls [name] with [arguments] and returns content items.
  @override
  Future<List<McpContent>> callTool(
      String name, Map<String, dynamic> arguments) async {
    final result = await _post({
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    });
    final content = result['content'] as List<dynamic>? ?? [];
    return content
        .map((c) => McpContent.fromMcpJson(c as Map<String, dynamic>))
        .toList();
  }
}
