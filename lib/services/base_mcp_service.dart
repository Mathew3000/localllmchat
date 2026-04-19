import '../models/tool_call.dart';

/// Shared interface implemented by both MCP transport clients.
///
/// Two concrete implementations exist:
///   • [McpService]    — Streamable-HTTP transport (POST /mcp, session header)
///   • [McpSseService] — HTTP+SSE transport (GET /sse + POST to endpoint URL)
abstract class BaseMcpService {
  String get baseUrl;
  Future<List<McpToolDef>> listTools();
  Future<List<McpContent>> callTool(String name, Map<String, dynamic> arguments);

  /// Release any persistent resources (SSE stream, HTTP client, etc.).
  /// Default implementation is a no-op for stateless transports.
  void dispose() {}
}

/// Thrown when an MCP server returns a non-2xx HTTP status.
///
/// Lets the caller distinguish HTTP-level failures (e.g. 404 "endpoint not
/// found") from network-level failures, which enables the auto-detect logic
/// to try the alternate transport.
class McpHttpException implements Exception {
  final int statusCode;
  final String body;
  const McpHttpException(this.statusCode, this.body);

  @override
  String toString() => 'MCP HTTP $statusCode: $body';
}
