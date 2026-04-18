import 'package:uuid/uuid.dart';

/// Configuration for a single MCP server instance.
class McpServer {
  final String id;
  String name;
  /// Primary URL used when on the home/local network.
  String baseUrlHome;
  /// Optional away / VPN URL. Empty = no override.
  String baseUrlAway;
  bool enabled;

  McpServer({
    String? id,
    this.name = 'New Server',
    this.baseUrlHome = '',
    this.baseUrlAway = '',
    this.enabled = true,
  }) : id = id ?? const Uuid().v4();

  McpServer copyWith({
    String? name,
    String? baseUrlHome,
    String? baseUrlAway,
    bool? enabled,
  }) =>
      McpServer(
        id: id,
        name: name ?? this.name,
        baseUrlHome: baseUrlHome ?? this.baseUrlHome,
        baseUrlAway: baseUrlAway ?? this.baseUrlAway,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrlHome': baseUrlHome,
        'baseUrlAway': baseUrlAway,
        'enabled': enabled,
      };

  factory McpServer.fromJson(Map<String, dynamic> json) => McpServer(
        id: json['id'] as String?,
        name: json['name'] as String? ?? 'MCP Server',
        baseUrlHome: json['baseUrlHome'] as String? ?? '',
        baseUrlAway: json['baseUrlAway'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
      );
}
