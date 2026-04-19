import 'package:uuid/uuid.dart';

/// Which MCP wire transport to use when connecting to this server.
enum McpTransport {
  /// Try Streamable-HTTP (POST /mcp) first; if the server returns 404 or 405
  /// automatically fall back to HTTP+SSE (GET /sse).
  auto,

  /// Always use the Streamable-HTTP transport (MCP 2024-11-05 / 2025-03-26).
  streamableHttp,

  /// Always use the HTTP+SSE transport (older servers, npx-based, Python
  /// reference implementations, etc.).
  sse,
}

/// Configuration for a single MCP server instance.
class McpServer {
  final String id;
  String name;

  /// Primary URL used when on the home/local network.
  String baseUrlHome;

  /// Optional away / VPN URL. Empty = no override.
  String baseUrlAway;

  bool enabled;

  /// Which transport protocol to use (default: auto-detect).
  McpTransport transport;

  McpServer({
    String? id,
    this.name = 'New Server',
    this.baseUrlHome = '',
    this.baseUrlAway = '',
    this.enabled = true,
    this.transport = McpTransport.auto,
  }) : id = id ?? const Uuid().v4();

  McpServer copyWith({
    String? name,
    String? baseUrlHome,
    String? baseUrlAway,
    bool? enabled,
    McpTransport? transport,
  }) =>
      McpServer(
        id: id,
        name: name ?? this.name,
        baseUrlHome: baseUrlHome ?? this.baseUrlHome,
        baseUrlAway: baseUrlAway ?? this.baseUrlAway,
        enabled: enabled ?? this.enabled,
        transport: transport ?? this.transport,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrlHome': baseUrlHome,
        'baseUrlAway': baseUrlAway,
        'enabled': enabled,
        'transport': transport.name, // 'auto' | 'streamableHttp' | 'sse'
      };

  factory McpServer.fromJson(Map<String, dynamic> json) => McpServer(
        id: json['id'] as String?,
        name: json['name'] as String? ?? 'MCP Server',
        baseUrlHome: json['baseUrlHome'] as String? ?? '',
        baseUrlAway: json['baseUrlAway'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
        transport: McpTransport.values.firstWhere(
          (t) => t.name == (json['transport'] as String?),
          orElse: () => McpTransport.auto,
        ),
      );
}
