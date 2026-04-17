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
  /// MCP server base URL (e.g. http://192.168.1.x:4242). Empty = disabled.
  final String mcpBaseUrl;
  /// Whether to include MCP tools in LLM requests.
  final bool mcpEnabled;
  /// Default ARGB colour for user message bubbles. Null = theme default.
  final int? defaultUserBubbleColor;
  /// Default ARGB colour for assistant message bubbles. Null = theme default.
  final int? defaultAssistantBubbleColor;
  /// LLM request timeout in seconds. Applies to both streaming connect and
  /// non-streaming tool-call requests. Default 300 s (5 min).
  final int requestTimeoutSeconds;

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
    this.mcpBaseUrl = '',
    this.mcpEnabled = false,
    this.requestTimeoutSeconds = 300,
  });

  /// The URL that is currently active based on [useAwayUrl].
  String get activeBaseUrl =>
      (useAwayUrl && baseUrlAway.isNotEmpty) ? baseUrlAway : baseUrlHome;

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
    String? mcpBaseUrl,
    bool? mcpEnabled,
    int? requestTimeoutSeconds,
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
        mcpBaseUrl: mcpBaseUrl ?? this.mcpBaseUrl,
        mcpEnabled: mcpEnabled ?? this.mcpEnabled,
        requestTimeoutSeconds:
            requestTimeoutSeconds ?? this.requestTimeoutSeconds,
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
        'mcpBaseUrl': mcpBaseUrl,
        'mcpEnabled': mcpEnabled,
        'requestTimeoutSeconds': requestTimeoutSeconds,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
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
        mcpBaseUrl: json['mcpBaseUrl'] as String? ?? '',
        mcpEnabled: json['mcpEnabled'] as bool? ?? false,
        requestTimeoutSeconds:
            json['requestTimeoutSeconds'] as int? ?? 300,
      );
}
