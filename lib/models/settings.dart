import 'mcp_server.dart';

class AppSettings {
  final String baseUrlHome;
  final String baseUrlAway;
  /// True → use [baseUrlAway]; false → use [baseUrlHome].
  final bool useAwayUrl;
  final String apiKey;
  final String selectedModel;
  final String systemPrompt;
  final double temperature;
  final int maxTokens;
  /// SHA-256 hash of the secret-chat password. Empty = feature disabled.
  final String secretPasswordHash;
  /// ARGB colour value for the chat background. Null = theme default.
  final int? backgroundColor;
  /// Default ARGB colour for user message bubbles. Null = theme default.
  final int? defaultUserBubbleColor;
  /// Default ARGB colour for assistant message bubbles. Null = theme default.
  final int? defaultAssistantBubbleColor;
  /// LLM request timeout in seconds. Default 300 s (5 min).
  final int requestTimeoutSeconds;
  /// All configured MCP servers.
  final List<McpServer> mcpServers;

  // ── Sync settings ──────────────────────────────────────────────────────────
  /// Base URL of the self-hosted sync server, e.g. http://192.168.1.10:8080
  final String syncUrl;
  /// Username on the sync server.
  final String syncUsername;
  /// JWT access token (stored locally; excluded from sync payload).
  final String syncAccessToken;
  /// Refresh token (stored locally; excluded from sync payload).
  final String syncRefreshToken;
  /// ISO-8601 timestamp of last successful sync. Null = never synced.
  final String syncLastAt;

  const AppSettings({
    this.baseUrlHome = 'http://192.168.1.1:5000/v1',
    this.baseUrlAway = '',
    this.useAwayUrl = false,
    this.apiKey = '',
    this.selectedModel = '',
    this.systemPrompt =
        'You are a helpful, harmless, and honest AI assistant.',
    this.temperature = 0.7,
    this.maxTokens = 2048,
    this.secretPasswordHash = '',
    this.backgroundColor,
    this.defaultUserBubbleColor,
    this.defaultAssistantBubbleColor,
    this.requestTimeoutSeconds = 300,
    this.mcpServers = const [],
    this.syncUrl = '',
    this.syncUsername = '',
    this.syncAccessToken = '',
    this.syncRefreshToken = '',
    this.syncLastAt = '',
  });

  /// The URL that is currently active based on [useAwayUrl].
  String get activeBaseUrl =>
      (useAwayUrl && baseUrlAway.isNotEmpty) ? baseUrlAway : baseUrlHome;

  /// True when at least one server is enabled.
  bool get mcpEnabled => mcpServers.any((s) => s.enabled);

  // Sentinel used so copyWith can distinguish "set to null" from "not provided".
  static const Object _unset = Object();

  AppSettings copyWith({
    String? baseUrlHome,
    String? baseUrlAway,
    bool? useAwayUrl,
    String? apiKey,
    String? selectedModel,
    String? systemPrompt,
    double? temperature,
    int? maxTokens,
    String? secretPasswordHash,
    Object? backgroundColor = _unset,
    Object? defaultUserBubbleColor = _unset,
    Object? defaultAssistantBubbleColor = _unset,
    int? requestTimeoutSeconds,
    List<McpServer>? mcpServers,
    String? syncUrl,
    String? syncUsername,
    String? syncAccessToken,
    String? syncRefreshToken,
    String? syncLastAt,
  }) =>
      AppSettings(
        baseUrlHome: baseUrlHome ?? this.baseUrlHome,
        baseUrlAway: baseUrlAway ?? this.baseUrlAway,
        useAwayUrl: useAwayUrl ?? this.useAwayUrl,
        apiKey: apiKey ?? this.apiKey,
        selectedModel: selectedModel ?? this.selectedModel,
        systemPrompt: systemPrompt ?? this.systemPrompt,
        temperature: temperature ?? this.temperature,
        maxTokens: maxTokens ?? this.maxTokens,
        secretPasswordHash: secretPasswordHash ?? this.secretPasswordHash,
        backgroundColor: identical(backgroundColor, _unset)
            ? this.backgroundColor
            : backgroundColor as int?,
        defaultUserBubbleColor: identical(defaultUserBubbleColor, _unset)
            ? this.defaultUserBubbleColor
            : defaultUserBubbleColor as int?,
        defaultAssistantBubbleColor:
            identical(defaultAssistantBubbleColor, _unset)
                ? this.defaultAssistantBubbleColor
                : defaultAssistantBubbleColor as int?,
        requestTimeoutSeconds:
            requestTimeoutSeconds ?? this.requestTimeoutSeconds,
        mcpServers: mcpServers ?? this.mcpServers,
        syncUrl: syncUrl ?? this.syncUrl,
        syncUsername: syncUsername ?? this.syncUsername,
        syncAccessToken: syncAccessToken ?? this.syncAccessToken,
        syncRefreshToken: syncRefreshToken ?? this.syncRefreshToken,
        syncLastAt: syncLastAt ?? this.syncLastAt,
      );

  Map<String, dynamic> toJson() => {
        'baseUrlHome': baseUrlHome,
        'baseUrlAway': baseUrlAway,
        'useAwayUrl': useAwayUrl,
        'apiKey': apiKey,
        'selectedModel': selectedModel,
        'systemPrompt': systemPrompt,
        'temperature': temperature,
        'maxTokens': maxTokens,
        'secretPasswordHash': secretPasswordHash,
        'backgroundColor': backgroundColor,
        'defaultUserBubbleColor': defaultUserBubbleColor,
        'defaultAssistantBubbleColor': defaultAssistantBubbleColor,
        'requestTimeoutSeconds': requestTimeoutSeconds,
        'mcpServers': mcpServers.map((s) => s.toJson()).toList(),
        'syncUrl': syncUrl,
        'syncUsername': syncUsername,
        'syncAccessToken': syncAccessToken,
        'syncRefreshToken': syncRefreshToken,
        'syncLastAt': syncLastAt,
      };

  /// Settings JSON for the sync payload — excludes device-specific credentials
  /// so tokens and last-sync timestamps are not overwritten on other devices.
  Map<String, dynamic> toSyncJson() {
    final j = toJson();
    j.remove('syncAccessToken');
    j.remove('syncRefreshToken');
    j.remove('syncLastAt');
    return j;
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    // ── Migrate old single-server config ────────────────────────────────────
    List<McpServer> mcpServers;
    if (json['mcpServers'] != null) {
      mcpServers = (json['mcpServers'] as List<dynamic>)
          .map((e) => McpServer.fromJson(e as Map<String, dynamic>))
          .toList();
    } else {
      final oldUrl = json['mcpBaseUrl'] as String? ?? '';
      final oldEnabled = json['mcpEnabled'] as bool? ?? false;
      mcpServers = (oldUrl.isNotEmpty && oldEnabled)
          ? [McpServer(name: 'MCP Server', baseUrlHome: oldUrl)]
          : [];
    }

    return AppSettings(
      // Migrate old 'baseUrl' key → baseUrlHome
      baseUrlHome: json['baseUrlHome'] as String? ??
          json['baseUrl'] as String? ??
          'http://192.168.1.1:5000/v1',
      baseUrlAway: json['baseUrlAway'] as String? ?? '',
      useAwayUrl: json['useAwayUrl'] as bool? ?? false,
      apiKey: json['apiKey'] as String? ?? '',
      selectedModel: json['selectedModel'] as String? ?? '',
      systemPrompt: json['systemPrompt'] as String? ??
          'You are a helpful, harmless, and honest AI assistant.',
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      maxTokens: json['maxTokens'] as int? ?? 2048,
      secretPasswordHash: json['secretPasswordHash'] as String? ?? '',
      backgroundColor: json['backgroundColor'] as int?,
      defaultUserBubbleColor: json['defaultUserBubbleColor'] as int?,
      defaultAssistantBubbleColor:
          json['defaultAssistantBubbleColor'] as int?,
      requestTimeoutSeconds:
          json['requestTimeoutSeconds'] as int? ?? 300,
      mcpServers: mcpServers,
      syncUrl: json['syncUrl'] as String? ?? '',
      syncUsername: json['syncUsername'] as String? ?? '',
      syncAccessToken: json['syncAccessToken'] as String? ?? '',
      syncRefreshToken: json['syncRefreshToken'] as String? ?? '',
      syncLastAt: json['syncLastAt'] as String? ?? '',
    );
  }
}
