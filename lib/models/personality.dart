import 'package:uuid/uuid.dart';

/// A named chat profile with its own system prompt and MCP server selection.
///
/// Every conversation is assigned exactly one personality at creation time.
/// The [activeMcpServerIds] is a subset of the globally configured servers —
/// a server must be both globally enabled AND in this set to participate.
class Personality {
  final String id;
  String name;
  String systemPrompt;

  /// IDs of [McpServer] entries from [AppSettings.mcpServers] that are active
  /// for this personality. Empty = no external MCP servers.
  /// The built-in file MCP (folder picker) is always available regardless.
  Set<String> activeMcpServerIds;

  Personality({
    String? id,
    required this.name,
    required this.systemPrompt,
    Set<String>? activeMcpServerIds,
  })  : id = id ?? const Uuid().v4(),
        activeMcpServerIds = activeMcpServerIds ?? {};

  Personality copyWith({
    String? name,
    String? systemPrompt,
    Set<String>? activeMcpServerIds,
  }) =>
      Personality(
        id: id,
        name: name ?? this.name,
        systemPrompt: systemPrompt ?? this.systemPrompt,
        activeMcpServerIds:
            activeMcpServerIds ?? Set.of(this.activeMcpServerIds),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'systemPrompt': systemPrompt,
        'activeMcpServerIds': activeMcpServerIds.toList(),
      };

  factory Personality.fromJson(Map<String, dynamic> json) => Personality(
        id: json['id'] as String?,
        name: json['name'] as String? ?? 'Personality',
        systemPrompt: json['systemPrompt'] as String? ?? '',
        activeMcpServerIds:
            (json['activeMcpServerIds'] as List<dynamic>? ?? [])
                .map((e) => e as String)
                .toSet(),
      );
}
