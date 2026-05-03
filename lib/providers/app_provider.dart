import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:intl/intl.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../models/conversation.dart';
import '../models/mcp_server.dart';
import '../models/message.dart';
import '../models/settings.dart';
import '../models/tool_call.dart';
import '../services/api_service.dart';
import '../services/backend_service.dart';
import '../services/base_mcp_service.dart';
import '../services/mcp_service.dart';
import '../services/mcp_sse_service.dart';
import '../services/storage_service.dart';
import '../services/streaming_keep_alive.dart';
import '../services/sync_service.dart';
import '../services/debug_logger.dart';

// ── Queued-message data class ─────────────────────────────────────────────────

class _QueuedMessage {
  final String content;
  final List<String> images;
  const _QueuedMessage(this.content, {this.images = const []});
}

// ─────────────────────────────────────────────────────────────────────────────

class AppProvider extends ChangeNotifier with WidgetsBindingObserver {
  final StorageService _storage = StorageService();

  AppSettings _settings = const AppSettings();
  List<Conversation> _conversations = [];
  Conversation? _activeConversation;
  final bool _isLoading = false;
  String? _error;
  List<String> _availableModels = [];
  bool _fetchingModels = false;
  StreamSubscription<String>? _streamSub;
  bool _isStreaming = false;

  // ── Backend generation ────────────────────────────────────────────────────
  BackendService? _backend;
  StreamSubscription<BackendEvent>? _backendEventSub;
  /// The assistant message currently being streamed from the backend.
  Message? _streamingBackendMsg;
  String? _streamingBackendConvId;
  bool _backendConnecting = false;
  String? _backendConnectError;
  bool _backendUsingAway = false;

  // ── Message queue ─────────────────────────────────────────────────────────
  /// Messages waiting to be sent once the current run finishes.
  final List<_QueuedMessage> _messageQueue = [];

  bool _secretsUnlocked = false;

  // ── Sync ──────────────────────────────────────────────────────────────────

  /// AES-256 key derived from the sync password at login. Null = not authenticated
  /// this session (PBKDF2 derivation hasn't been run yet). Kept in memory only.
  Uint8List? _syncKey;
  SyncStatus _syncStatus = SyncStatus.idle;
  String? _syncError;

  /// Periodic timer that fires [syncNow] automatically. Null = disabled or
  /// not started yet (e.g. sync key not loaded).
  Timer? _autoSyncTimer;

  // ── Network auto-detection (LLM server) ──────────────────────────────────

  bool _usingAway = false;
  DateTime? _lastNetworkCheck;
  static const _networkCacheDuration = Duration(seconds: 60);

  // ── MCP (multi-server) ────────────────────────────────────────────────────

  /// Cached service instances (Streamable-HTTP or SSE), keyed by server id.
  final Map<String, BaseMcpService> _mcpServiceCache = {};
  /// Tools loaded per server id.
  final Map<String, List<McpToolDef>> _mcpToolsByServer = {};
  /// In-progress fetch flag per server id.
  final Map<String, bool> _fetchingByServer = {};
  /// Last error per server id.
  final Map<String, String> _mcpErrorByServer = {};
  /// Whether the away URL is currently active for a given server id.
  final Map<String, bool> _serverUsingAway = {};
  /// Last time the home/away decision was made for each server id.
  final Map<String, DateTime> _serverLastUrlCheck = {};
  /// Routes a tool name to the service that provides it.
  final Map<String, BaseMcpService> _toolServiceMap = {};

  /// Runtime override — lets the user toggle tools on/off without touching settings.
  bool _mcpActive = true;

  // ── Memory pre-fetch cache ────────────────────────────────────────────────
  String? _cachedMemoryContext;
  DateTime? _memoryCacheTime;
  static const _memoryCacheDuration = Duration(minutes: 5);

  // ── Token usage (prompt tokens per conversation) ──────────────────────────
  /// Last known prompt token count per conversation ID.
  final Map<String, int> _promptTokens = {};
  final Map<String, int> _completionTokens = {};

  // ── Getters ───────────────────────────────────────────────────────────────

  AppSettings get settings => _settings;
  List<Conversation> get conversations => _conversations;
  Conversation? get activeConversation => _activeConversation;
  bool get isLoading => _isLoading;
  String? get error => _error;
  List<String> get availableModels => _availableModels;
  bool get fetchingModels => _fetchingModels;
  bool get isStreaming => _isStreaming;
  /// Text content of queued messages, for display in the queue strip.
  List<String> get messageQueue =>
      List.unmodifiable(_messageQueue.map((m) => m.content).toList());
  bool get secretsUnlocked => _secretsUnlocked;
  bool get hasSecretPassword => _settings.secretPasswordHash.isNotEmpty;
  bool get usingAwayUrl => _usingAway;
  bool get mcpActive => _mcpActive;

  /// Prompt tokens used in the active conversation (null = not yet known).
  int? get activePromptTokens => _activeConversation != null
      ? _promptTokens[_activeConversation!.id]
      : null;

  /// Completion tokens from the last turn in the active conversation.
  int? get activeCompletionTokens => _activeConversation != null
      ? _completionTokens[_activeConversation!.id]
      : null;

  // Backend getters
  bool get backendConnecting => _backendConnecting;
  String? get backendConnectError => _backendConnectError;
  bool get backendConnected => _backend?.isConnected ?? false;
  bool get backendUsingAway => _backendUsingAway;
  bool get backendConfigured =>
      _settings.backendUrl.isNotEmpty && _settings.backendToken.isNotEmpty;

  // Sync getters
  /// True when sync credentials are stored (server URL + tokens configured).
  bool get syncConfigured =>
      _settings.syncUrl.isNotEmpty && _settings.syncAccessToken.isNotEmpty;
  /// True when configured AND the encryption key is loaded for this session.
  bool get syncReady => syncConfigured && _syncKey != null;
  SyncStatus get syncStatus => _syncStatus;
  String? get syncError => _syncError;

  /// Flat list of all tools from all enabled servers.
  List<McpToolDef> get mcpTools =>
      _mcpToolsByServer.values.expand((l) => l).toList();

  /// True when any server is still loading tools.
  bool get fetchingMcpTools => _fetchingByServer.values.any((v) => v);

  /// True when MCP is configured, tools loaded, AND runtime toggle is on.
  bool get mcpAvailable =>
      _settings.mcpEnabled && mcpTools.isNotEmpty && _mcpActive;

  /// True when MCP is configured at all (ignoring runtime toggle).
  bool get mcpConfigured => _settings.mcpEnabled && mcpTools.isNotEmpty;

  // ── Per-server state for the MCP servers screen ───────────────────────────

  List<McpToolDef> mcpToolsForServer(String serverId) =>
      _mcpToolsByServer[serverId] ?? [];

  bool fetchingForServer(String serverId) =>
      _fetchingByServer[serverId] ?? false;

  String? errorForServer(String serverId) => _mcpErrorByServer[serverId];

  bool serverUsingAway(String serverId) =>
      _serverUsingAway[serverId] ?? false;

  /// When transport is [McpTransport.auto], returns the transport that was
  /// actually detected ('SSE' or 'HTTP'). Returns null when not yet connected.
  String? detectedTransportForServer(String serverId) {
    final svc = _mcpServiceCache[serverId];
    if (svc == null) return null;
    return svc is McpSseService ? 'SSE' : 'HTTP';
  }

  void toggleMcp() {
    _mcpActive = !_mcpActive;
    notifyListeners();
  }

  // ── Memory helpers ────────────────────────────────────────────────────────

  /// Returns the first enabled memory server, or null.
  McpServer? _findMemoryServer() {
    for (final s in _settings.mcpServers) {
      if (s.isMemory && s.enabled) return s;
    }
    return null;
  }

  /// Pre-fetches the user entity from the memory MCP server (if configured
  /// and the MCP toggle is on).  Results are cached for [_memoryCacheDuration]
  /// to avoid a round-trip on every single message.
  Future<String?> _fetchUserMemory() async {
    if (!_mcpActive) return null;
    final server = _findMemoryServer();
    if (server == null) return null;
    final service = _mcpServiceCache[server.id];
    if (service == null) return null;

    // Return from cache if still fresh.
    if (_cachedMemoryContext != null &&
        _memoryCacheTime != null &&
        DateTime.now().difference(_memoryCacheTime!) < _memoryCacheDuration) {
      return _cachedMemoryContext;
    }

    try {
      final content = await service
          .callTool('search_nodes', {'query': 'user'})
          .timeout(const Duration(seconds: 5));
      if (content.isEmpty) return null;
      final text = content.map((c) => c.toApiText()).join('\n').trim();
      if (text.isEmpty) return null;
      _cachedMemoryContext = text;
      _memoryCacheTime = DateTime.now();
      return text;
    } catch (_) {
      return null;
    }
  }

  /// Returns a copy of [_settings] with [memoryCtx] appended to the system
  /// prompt.  Used in direct-mode generation so both streaming and agentic
  /// paths receive the user context without any further plumbing.
  AppSettings _settingsWithMemory(String? memoryCtx) {
    if (memoryCtx == null || memoryCtx.isEmpty) return _settings;
    const separator = '\n\n---\n**About the user (from memory):**\n';
    const footer =
        '\n\nUse the memory tools to look up more details or save new '
        'information you learn about the user during this conversation.';
    return _settings.copyWith(
      systemPrompt: _settings.systemPrompt + separator + memoryCtx + footer,
    );
  }

  String get activeBaseUrl =>
      (_usingAway && _settings.baseUrlAway.isNotEmpty)
          ? _settings.baseUrlAway
          : _settings.baseUrlHome;

  List<Conversation> get visibleConversations => _secretsUnlocked
      ? _conversations
      : _conversations.where((c) => !c.isSecret).toList();

  AppProvider() {
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disconnectBackend();
    super.dispose();
  }

  // ── App lifecycle ─────────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onAppResumed();
  }

  /// Called when the app returns to the foreground.
  /// Reconnects the backend WebSocket if it dropped (e.g. screen locked while
  /// idle — the foreground service only runs during active generation so idle
  /// connections are not protected). Also refreshes the conversation list so
  /// chats created on other devices appear without requiring a full restart.
  void _onAppResumed() {
    if (!_settings.useBackend || _settings.backendToken.isEmpty) return;
    if (_backend == null) {
      // Service was fully torn down — do a full reconnect.
      _connectBackend();
      return;
    }
    if (backendConnected) {
      // Still connected — refresh list to pick up chats from other devices.
      _refreshConversations();
      return;
    }

    // WebSocket dropped — reconnect lightly without re-fetching everything.
    _backend!.connect().then((_) {
      notifyListeners();
      _refreshConversations();
    }).catchError((_) {
      // Reconnect failed — show disconnected state; user can retry from settings.
      notifyListeners();
    });
  }

  /// Fetches a fresh conversation list from the backend while preserving any
  /// already-loaded messages in the in-memory list.
  Future<void> _refreshConversations() async {
    if (_backend == null) return;
    try {
      final fresh = await _backend!.fetchConversations();
      // Keep messages that were already loaded locally.
      final localMsgs = {
        for (final c in _conversations)
          if (c.messages.isNotEmpty) c.id: c.messages
      };
      for (final c in fresh) {
        final loaded = localMsgs[c.id];
        if (loaded != null) c.messages.addAll(loaded);
      }
      _conversations = fresh;
      // Re-point active conversation to the updated instance.
      if (_activeConversation != null) {
        // Try to keep the same conversation; fall back to first visible one
        // (never expose a secret chat while secrets are locked).
        final stillExists =
            fresh.where((c) => c.id == _activeConversation!.id).toList();
        if (stillExists.isNotEmpty) {
          _activeConversation = stillExists.first;
        } else {
          final visible = fresh.where((c) => !c.isSecret).toList();
          _activeConversation = visible.isNotEmpty ? visible.first : null;
        }
      }
      notifyListeners();
    } catch (_) {
      // Non-fatal — keep what we have.
    }
  }

  Future<void> _init() async {
    _settings = await _storage.loadSettings();
    // Start debug logger early so first requests are captured.
    await DebugLogger.instance.init(
      enabled: _settings.debugLogging,
      folderPath: _settings.debugLogPath,
    );
    _conversations = await _storage.loadConversations();
    if (_conversations.isNotEmpty) {
      final visible = _conversations.where((c) => !c.isSecret).toList();
      _activeConversation = visible.isNotEmpty ? visible.first : null;
    }
    notifyListeners();
    _autoDetectUrl();
    _fetchAllMcpTools();
    _startAutoSync();
    if (_settings.useBackend && _settings.backendToken.isNotEmpty) {
      _connectBackend();
    }
  }

  // ── Network auto-detect (LLM server) ─────────────────────────────────────

  Future<void> _autoDetectUrl() async {
    if (_settings.baseUrlAway.isEmpty) {
      _usingAway = false;
      return;
    }
    final now = DateTime.now();
    if (_lastNetworkCheck != null &&
        now.difference(_lastNetworkCheck!) < _networkCacheDuration) {
      return;
    }
    final reachable = await _pingHome();
    _lastNetworkCheck = DateTime.now();
    final shouldUseAway = !reachable;
    if (shouldUseAway != _usingAway) {
      _usingAway = shouldUseAway;
      notifyListeners();
    }
  }

  Future<bool> _pingHome() async {
    try {
      var url = _settings.baseUrlHome.trimRight();
      if (url.endsWith('/')) url = url.substring(0, url.length - 1);
      await http
          .get(Uri.parse('$url/models'), headers: {
            if (_settings.apiKey.isNotEmpty)
              'Authorization': 'Bearer ${_settings.apiKey}',
          })
          .timeout(const Duration(milliseconds: 1500));
      return true;
    } on TimeoutException {
      return false;
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('unreachable') ||
          msg.contains('no route') ||
          msg.contains('network is down') ||
          msg.contains('failed host lookup')) {
        return false;
      }
      return true;
    }
  }

  Future<void> recheckNetwork() async {
    _lastNetworkCheck = null;
    await _autoDetectUrl();
  }

  // ── MCP: per-server ping & URL selection ──────────────────────────────────

  /// Checks whether the home MCP server is reachable by opening a raw TCP
  /// connection to its host:port. This avoids depending on any specific HTTP
  /// endpoint or verb — some MCP servers do not respond to GET /mcp at all,
  /// which caused spurious timeouts and permanent fallback to the away URL.
  Future<bool> _pingMcpServer(McpServer server) async {
    try {
      final uri = Uri.tryParse(server.baseUrlHome.trim());
      if (uri == null || !uri.hasAuthority) return false;
      final port = uri.hasPort
          ? uri.port
          : (uri.scheme == 'https' ? 443 : 80);
      final socket = await Socket.connect(
        uri.host,
        port,
        timeout: const Duration(milliseconds: 1500),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── MCP: transport-aware service creation ────────────────────────────────

  /// Returns a cached service if URL and concrete type still match;
  /// otherwise creates a new one.
  BaseMcpService _reuseOrCreate(
      String serverId, String url, McpTransport type,
      {Map<String, String> headers = const {}}) {
    final cached = _mcpServiceCache[serverId];
    if (cached != null && cached.baseUrl == url) {
      if (type == McpTransport.sse && cached is McpSseService) return cached;
      if (type == McpTransport.streamableHttp && cached is McpService) {
        return cached;
      }
    }
    cached?.dispose();
    // Look up the server name for the debug log tag.
    final serverName = _settings.mcpServers
        .firstWhere((s) => s.id == serverId, orElse: () => McpServer(name: serverId))
        .name;
    return type == McpTransport.sse
        ? McpSseService(url, extraHeaders: headers, tag: serverName)
        : McpService(url, extraHeaders: headers, tag: serverName);
  }

  /// For [McpTransport.auto]: tries Streamable-HTTP first; on 404/405 falls
  /// back to HTTP+SSE.  Reuses a cached service if the URL hasn't changed.
  Future<(BaseMcpService, List<McpToolDef>)> _autoDetect(
      String serverId, String url,
      {Map<String, String> headers = const {}}) async {
    // Reuse whatever worked last time (same URL).
    final cached = _mcpServiceCache[serverId];
    if (cached != null && cached.baseUrl == url) {
      try {
        return (cached, await cached.listTools());
      } catch (_) {
        cached.dispose();
        _mcpServiceCache.remove(serverId);
      }
    }

    // Look up the server name for the debug log tag.
    final serverName = _settings.mcpServers
        .firstWhere((s) => s.id == serverId, orElse: () => McpServer(name: serverId))
        .name;

    // Try Streamable-HTTP.
    try {
      final svc = McpService(url, extraHeaders: headers, tag: serverName);
      final tools = await svc.listTools();
      return (svc, tools);
    } on McpHttpException catch (e) {
      // 404/405 means the server doesn't have a /mcp endpoint — try SSE.
      if (e.statusCode != 404 && e.statusCode != 405) rethrow;
    }

    // Fall back to HTTP+SSE.
    final svc = McpSseService(url, extraHeaders: headers, tag: serverName);
    final tools = await svc.listTools();
    return (svc, tools);
  }

  /// Resolves the active URL (home vs away) for [server].
  ///
  /// Result is cached for [_networkCacheDuration] (60 s) to avoid
  /// re-pinging on every tool refresh — mirrors the LLM server behaviour.
  Future<String> _selectUrl(McpServer server) async {
    if (server.baseUrlAway.isEmpty) {
      _serverUsingAway.remove(server.id);
      _serverLastUrlCheck.remove(server.id);
      return server.baseUrlHome;
    }
    final last = _serverLastUrlCheck[server.id];
    final cacheValid = last != null &&
        DateTime.now().difference(last) < _networkCacheDuration;
    if (cacheValid) {
      final usingAway = _serverUsingAway[server.id] ?? false;
      return usingAway ? server.baseUrlAway : server.baseUrlHome;
    }
    final reachable = await _pingMcpServer(server);
    _serverUsingAway[server.id] = !reachable;
    _serverLastUrlCheck[server.id] = DateTime.now();
    return reachable ? server.baseUrlHome : server.baseUrlAway;
  }

  void _rebuildToolServiceMap() {
    _toolServiceMap.clear();
    for (final entry in _mcpToolsByServer.entries) {
      final service = _mcpServiceCache[entry.key];
      if (service != null) {
        for (final tool in entry.value) {
          _toolServiceMap[tool.name] = service;
        }
      }
    }
  }

  // ── MCP: public fetch API ─────────────────────────────────────────────────

  /// Fetches (or re-fetches) tools for a single server.
  Future<void> fetchMcpToolsForServer(McpServer server) async {
    if (!server.enabled || server.baseUrlHome.isEmpty) {
      _mcpServiceCache.remove(server.id)?.dispose();
      _mcpToolsByServer.remove(server.id);
      _mcpErrorByServer.remove(server.id);
      _rebuildToolServiceMap();
      notifyListeners();
      return;
    }

    _fetchingByServer[server.id] = true;
    _mcpErrorByServer.remove(server.id);
    notifyListeners();

    try {
      final activeUrl = await _selectUrl(server);

      BaseMcpService service;
      List<McpToolDef> tools;

      switch (server.transport) {
        case McpTransport.streamableHttp:
          service = _reuseOrCreate(server.id, activeUrl, McpTransport.streamableHttp,
              headers: server.headers);
          tools = await service.listTools();
        case McpTransport.sse:
          service = _reuseOrCreate(server.id, activeUrl, McpTransport.sse,
              headers: server.headers);
          tools = await service.listTools();
        case McpTransport.auto:
          (service, tools) = await _autoDetect(server.id, activeUrl,
              headers: server.headers);
      }

      _mcpServiceCache[server.id] = service;
      _mcpToolsByServer[server.id] = tools;
      _rebuildToolServiceMap();
    } catch (e) {
      _mcpServiceCache.remove(server.id)?.dispose();
      _mcpToolsByServer.remove(server.id);
      _mcpErrorByServer[server.id] = e.toString();
      _rebuildToolServiceMap();
    } finally {
      _fetchingByServer[server.id] = false;
      notifyListeners();
    }
  }

  /// Fetches tools for all currently enabled servers (in parallel).
  Future<void> fetchMcpTools() => _fetchAllMcpTools();

  Future<void> _fetchAllMcpTools() async {
    final enabled = _settings.mcpServers
        .where((s) => s.enabled && s.baseUrlHome.isNotEmpty)
        .toList();
    if (enabled.isEmpty) return;
    await Future.wait(enabled.map(fetchMcpToolsForServer));
  }

  /// Persists an updated server list, evicts stale caches, and triggers
  /// fetches for any server that was just enabled or had its URL changed.
  /// Called by McpServersScreen whenever the user edits server config.
  Future<void> saveMcpServers(List<McpServer> servers) async {
    final oldById = {for (final s in _settings.mcpServers) s.id: s};
    _settings = _settings.copyWith(mcpServers: servers);
    await _storage.saveSettings(_settings);

    final toFetch = <McpServer>[];

    for (final s in servers) {
      final old = oldById[s.id];
      final urlOrTransportChanged = old != null &&
          (old.baseUrlHome != s.baseUrlHome ||
              old.baseUrlAway != s.baseUrlAway ||
              old.transport != s.transport);

      if (urlOrTransportChanged) {
        // Evict stale service and force re-ping with new URL.
        _mcpServiceCache.remove(s.id)?.dispose();
        _mcpToolsByServer.remove(s.id);
        _mcpErrorByServer.remove(s.id);
        _serverLastUrlCheck.remove(s.id);
      }

      final wasEnabled = old?.enabled ?? false;
      final justEnabled = !wasEnabled && s.enabled;
      final justDisabled = wasEnabled && !s.enabled;

      // Invalidate memory cache if anything about the memory server changed.
      if (s.isMemory || (old?.isMemory ?? false)) {
        _cachedMemoryContext = null;
        _memoryCacheTime = null;
      }

      if (justDisabled) {
        // Clear tools for a server that was just turned off.
        _mcpServiceCache.remove(s.id)?.dispose();
        _mcpToolsByServer.remove(s.id);
        _mcpErrorByServer.remove(s.id);
      } else if (s.enabled && (justEnabled || urlOrTransportChanged)) {
        // Re-fetch tools for a newly-enabled server or one whose URL changed.
        toFetch.add(s);
      }
    }

    // Clean up entries for removed servers.
    final ids = servers.map((s) => s.id).toSet();
    for (final id in _mcpServiceCache.keys.toList()) {
      if (!ids.contains(id)) _mcpServiceCache.remove(id)?.dispose();
    }
    _mcpToolsByServer.removeWhere((k, _) => !ids.contains(k));
    _fetchingByServer.removeWhere((k, _) => !ids.contains(k));
    _mcpErrorByServer.removeWhere((k, _) => !ids.contains(k));
    _serverUsingAway.removeWhere((k, _) => !ids.contains(k));
    _serverLastUrlCheck.removeWhere((k, _) => !ids.contains(k));
    _rebuildToolServiceMap();
    notifyListeners();

    // Kick off fetches outside the synchronous path.
    for (final s in toFetch) {
      fetchMcpToolsForServer(s);
    }
  }

  // ── Secret chats ──────────────────────────────────────────────────────────

  static String _hashPassword(String password) =>
      sha256.convert(utf8.encode(password)).toString();

  /// Returns true when [password] matches the stored secret-chat password hash,
  /// without changing any unlock state.
  bool verifySecretPassword(String password) {
    if (_settings.secretPasswordHash.isEmpty) return false;
    final hash = sha256.convert(utf8.encode(password)).toString();
    return hash == _settings.secretPasswordHash;
  }

  bool unlockSecrets(String password) {
    if (_hashPassword(password) == _settings.secretPasswordHash) {
      _secretsUnlocked = true;
      notifyListeners();
      return true;
    }
    return false;
  }

  void lockSecrets() {
    _secretsUnlocked = false;
    if (_activeConversation?.isSecret == true) {
      final visible = _conversations.where((c) => !c.isSecret).toList();
      _activeConversation = visible.isNotEmpty ? visible.first : null;
    }
    notifyListeners();
  }

  void setConversationColors(String id,
      {required int? userBubbleColor,
      required int? assistantBubbleColor}) {
    final conv = _conversations.firstWhere((c) => c.id == id);
    conv.userBubbleColor = userBubbleColor;
    conv.assistantBubbleColor = assistantBubbleColor;
    if (_settings.useBackend && _backend != null) {
      _backend!.patchConversation(id, {
        'user_bubble_color': userBubbleColor,
        'assistant_bubble_color': assistantBubbleColor,
      }).catchError((_) {});
    } else {
      _persistConversations();
    }
    notifyListeners();
  }

  void toggleConversationSecret(String id) {
    final conv = _conversations.firstWhere((c) => c.id == id);
    conv.isSecret = !conv.isSecret;
    if (!_secretsUnlocked &&
        _activeConversation?.id == id &&
        conv.isSecret) {
      final visible = _conversations.where((c) => !c.isSecret).toList();
      _activeConversation = visible.isNotEmpty ? visible.first : null;
    }
    if (_settings.useBackend && _backend != null) {
      _backend!.patchConversation(id, {'is_secret': conv.isSecret})
          .catchError((_) {});
    } else {
      _persistConversations();
    }
    notifyListeners();
  }

  Future<void> setSecretPassword(String newPassword) async {
    _settings =
        _settings.copyWith(secretPasswordHash: _hashPassword(newPassword));
    await _storage.saveSettings(_settings);
    notifyListeners();
  }

  Future<bool> changeSecretPassword(
      String currentPassword, String newPassword) async {
    if (_hashPassword(currentPassword) != _settings.secretPasswordHash) {
      return false;
    }
    _settings =
        _settings.copyWith(secretPasswordHash: _hashPassword(newPassword));
    await _storage.saveSettings(_settings);
    notifyListeners();
    return true;
  }

  Future<bool> removeSecretPassword(String currentPassword) async {
    if (_hashPassword(currentPassword) != _settings.secretPasswordHash) {
      return false;
    }
    for (final c in _conversations) {
      c.isSecret = false;
    }
    _settings = _settings.copyWith(secretPasswordHash: '');
    _secretsUnlocked = false;
    await _storage.saveSettings(_settings);
    await _persistConversations();
    notifyListeners();
    return true;
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  Future<void> updateSettings(AppSettings newSettings) async {
    _settings = newSettings;
    await _storage.saveSettings(_settings);
    _availableModels = [];
    _lastNetworkCheck = null;
    _startAutoSync(); // restart in case interval or enabled flag changed
    // Push shared settings to backend so run_generation() picks them up.
    if (_settings.useBackend && _backend != null) {
      _backend!.pushSettings(_settings.toSyncJson()).catchError((_) {});
    }
    notifyListeners();
  }

  /// Save only the debug logging settings without resetting the model list or
  /// network state — avoids disruptive side-effects when toggling from the
  /// Settings screen while other fields are in progress.
  Future<void> saveDebugSettings({
    required bool enabled,
    required String path,
  }) async {
    _settings = _settings.copyWith(debugLogging: enabled, debugLogPath: path);
    await _storage.saveSettings(_settings);
    await DebugLogger.instance.init(enabled: enabled, folderPath: path);
    notifyListeners();
  }

  // ── Backend server ────────────────────────────────────────────────────────

  /// Persists the backend away URL immediately (no full settings save needed).
  Future<void> setBackendAwayUrl(String url) async {
    _settings = _settings.copyWith(backendAwayUrl: url);
    await _storage.saveSettings(_settings);
    notifyListeners();
  }

  /// Returns the backend URL to use, trying [backendUrl] (home) first.
  /// If unreachable and [backendAwayUrl] is set, falls back to away.
  Future<String> _resolveBackendUrl() async {
    final home = _settings.backendUrl;
    final away = _settings.backendAwayUrl;
    if (away.isEmpty) {
      _backendUsingAway = false;
      return home;
    }
    try {
      final base = home.trimRight().replaceAll(RegExp(r'/$'), '');
      final client = _settings.backendAllowSelfSigned
          ? IOClient(HttpClient()..badCertificateCallback = (_, __, ___) => true)
          : http.Client();
      try {
        await client
            .get(Uri.parse('$base/health'))
            .timeout(const Duration(milliseconds: 1500));
        _backendUsingAway = false;
        return home;
      } finally {
        client.close();
      }
    } catch (_) {
      _backendUsingAway = true;
      return away;
    }
  }

  Future<void> _connectBackend() async {
    if (_backendConnecting) return;
    _backendConnecting = true;
    _backendConnectError = null;
    notifyListeners();

    try {
      _backend?.dispose();
      final activeUrl = await _resolveBackendUrl();
      _backend = BackendService(
        baseUrl: activeUrl,
        token: _settings.backendToken,
        allowSelfSigned: _settings.backendAllowSelfSigned,
      );

      await _backend!.connect();

      _backendEventSub?.cancel();
      _backendEventSub = _backend!.events.listen(_handleBackendEvent);

      // Pull server-side settings and merge into local settings so the app
      // reflects whatever was last saved (e.g. LLM URL, model, system prompt).
      try {
        final remote = await _backend!.fetchSettings();
        if (remote.isNotEmpty) {
          _settings = AppSettings.fromJson({
            ..._settings.toJson(),   // local base (has device-local fields)
            ...remote,               // server overrides shared fields
            // Always keep device-local fields from local settings:
            'useBackend': _settings.useBackend,
            'backendUrl': _settings.backendUrl,
            'backendToken': _settings.backendToken,
            'backendAllowSelfSigned': _settings.backendAllowSelfSigned,
            'autoSyncEnabled': _settings.autoSyncEnabled,
            'autoSyncIntervalMinutes': _settings.autoSyncIntervalMinutes,
            'debugLogging': _settings.debugLogging,
            'debugLogPath': _settings.debugLogPath,
            'syncAccessToken': _settings.syncAccessToken,
            'syncRefreshToken': _settings.syncRefreshToken,
          });
          await _storage.saveSettings(_settings);
        }
      } catch (_) {
        // Non-fatal — proceed with local settings if the pull fails.
      }

      // Load conversations from the backend
      final convs = await _backend!.fetchConversations();
      _conversations = convs;
      final visibleConvs = convs.where((c) => !c.isSecret).toList();
      _activeConversation = visibleConvs.isNotEmpty ? visibleConvs.first : null;
      // Pre-load messages for the initially active conversation so the user
      // sees content immediately without having to tap it first.
      if (_activeConversation != null) {
        _loadConversationMessages(_activeConversation!.id);
      }
      // Re-fetch MCP tools now that settings may have been updated from the
      // server — the initial _fetchAllMcpTools() runs before backend connects.
      _fetchAllMcpTools();
    } catch (e) {
      _backendConnectError = e.toString();
      _backend?.dispose();
      _backend = null;
    } finally {
      _backendConnecting = false;
      notifyListeners();
    }
  }

  void _disconnectBackend() {
    _backendEventSub?.cancel();
    _backendEventSub = null;
    _backend?.dispose();
    _backend = null;
    _streamingBackendMsg = null;
    _streamingBackendConvId = null;
  }

  /// Reconnects to the backend using the stored token (no re-authentication).
  Future<void> backendReconnect() => _connectBackend();

  /// Login to the backend server and connect.
  Future<void> backendLogin(
    String url,
    String username,
    String password,
  ) async {
    final token = await BackendService.loginStatic(
      url,
      username,
      password,
      allowSelfSigned: _settings.backendAllowSelfSigned,
    );
    _settings = _settings.copyWith(
      backendUrl: url,
      backendToken: token,
      useBackend: true,
    );
    await _storage.saveSettings(_settings);
    await _connectBackend();
  }

  /// Register a new account on the backend server and connect.
  Future<void> backendRegister(
    String url,
    String username,
    String password,
  ) async {
    final token = await BackendService.registerStatic(
      url,
      username,
      password,
      allowSelfSigned: _settings.backendAllowSelfSigned,
    );
    _settings = _settings.copyWith(
      backendUrl: url,
      backendToken: token,
      useBackend: true,
    );
    await _storage.saveSettings(_settings);
    await _connectBackend();
  }

  /// Disconnect from the backend and switch back to direct LLM mode.
  Future<void> backendLogout() async {
    _disconnectBackend();
    _settings = _settings.copyWith(
      useBackend: false,
      backendToken: '',
    );
    await _storage.saveSettings(_settings);
    // Reload local conversations
    _conversations = await _storage.loadConversations();
    final logoutVisible =
        _conversations.where((c) => !c.isSecret).toList();
    _activeConversation =
        logoutVisible.isNotEmpty ? logoutVisible.first : null;
    notifyListeners();
  }

  /// Update the backendAllowSelfSigned flag immediately (no Save needed).
  Future<void> setBackendAllowSelfSigned(bool value) async {
    _settings = _settings.copyWith(backendAllowSelfSigned: value);
    await _storage.saveSettings(_settings);
    notifyListeners();
  }

  Future<void> fetchModels() async {
    _fetchingModels = true;
    _error = null;
    notifyListeners();
    try {
      if (_settings.useBackend && _backend != null) {
        _availableModels = await _backend!.fetchModels();
      } else {
        await _autoDetectUrl();
        _availableModels =
            await ApiService(_settings, activeBaseUrl).fetchModels();
      }
      if (_availableModels.isNotEmpty &&
          !_availableModels.contains(_settings.selectedModel)) {
        _settings =
            _settings.copyWith(selectedModel: _availableModels.first);
        await _storage.saveSettings(_settings);
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _fetchingModels = false;
      notifyListeners();
    }
  }

  // ── Conversations ─────────────────────────────────────────────────────────

  Future<void> newConversation() async {
    if (_settings.useBackend && _backend != null) {
      try {
        final conv = await _backend!.createConversation();
        _conversations.insert(0, conv);
        _activeConversation = conv;
      } catch (e) {
        _error = 'Failed to create conversation: $e';
      }
    } else {
      final conv = Conversation();
      _conversations.insert(0, conv);
      _activeConversation = conv;
      _persistConversations();
    }
    notifyListeners();
  }

  void selectConversation(Conversation conv) {
    _activeConversation = conv;
    notifyListeners();
    // In backend mode, lazy-load messages if not yet fetched.
    if (_settings.useBackend && conv.messages.isEmpty && _backend != null) {
      _loadConversationMessages(conv.id);
    }
  }

  Future<void> _loadConversationMessages(String convId) async {
    try {
      final full = await _backend!.fetchConversation(convId);
      final idx = _conversations.indexWhere((c) => c.id == convId);
      if (idx >= 0) _conversations[idx] = full;
      if (_activeConversation?.id == convId) _activeConversation = full;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load messages: $e';
      notifyListeners();
    }
  }

  void renameConversation(String id, String newTitle) {
    final title = newTitle.trim();
    if (title.isEmpty) return;
    final conv = _conversations.firstWhere((c) => c.id == id,
        orElse: () => throw StateError('not found'));
    conv.title = title;
    if (_settings.useBackend && _backend != null) {
      _backend!.renameConversation(id, title).catchError((_) {});
    } else {
      _persistConversations();
    }
    notifyListeners();
  }

  /// Deletes the message with [id] from the active conversation.
  /// When [andFollowingResponse] is true, also removes all consecutive
  /// non-user messages that immediately follow it (the AI turn).
  void deleteMessage(String id, {bool andFollowingResponse = false}) {
    final conv = _activeConversation;
    if (conv == null) return;
    final msgs = conv.messages;
    final idx = msgs.indexWhere((m) => m.id == id);
    if (idx == -1) return;

    final idsToDelete = <String>[];
    if (andFollowingResponse) {
      int end = idx + 1;
      while (end < msgs.length && msgs[end].role != Role.user) { end++; }
      idsToDelete.addAll(msgs.sublist(idx, end).map((m) => m.id));
      msgs.removeRange(idx, end);
    } else {
      idsToDelete.add(id);
      msgs.removeAt(idx);
    }

    if (_settings.useBackend && _backend != null) {
      for (final mid in idsToDelete) {
        _backend!.deleteMessage(conv.id, mid).catchError((_) {});
      }
    } else {
      _persistConversations();
    }
    notifyListeners();
  }

  void deleteConversation(String id) {
    _conversations.removeWhere((c) => c.id == id);
    if (_activeConversation?.id == id) {
      _activeConversation = visibleConversations.isNotEmpty
          ? visibleConversations.first
          : null;
    }
    if (_settings.useBackend && _backend != null) {
      _backend!.deleteConversation(id).catchError((_) {});
    } else {
      _persistConversations();
    }
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  // ── Chat ──────────────────────────────────────────────────────────────────

  /// Adds a message to the queue without starting a new run.
  void enqueueMessage(String text, {List<String> images = const []}) {
    final t = text.trim();
    if (t.isEmpty && images.isEmpty) return;
    _messageQueue.add(_QueuedMessage(t, images: images));
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (index >= 0 && index < _messageQueue.length) {
      _messageQueue.removeAt(index);
      notifyListeners();
    }
  }

  void clearQueue() {
    _messageQueue.clear();
    notifyListeners();
  }

  /// Pops the next queued message and sends it, if any.
  /// Called automatically at the end of each completed run.
  Future<void> _processNextInQueue() async {
    if (_messageQueue.isEmpty) return;
    final next = _messageQueue.removeAt(0);
    notifyListeners();
    await sendMessage(next.content, images: next.images);
  }

  Future<void> sendMessage(String content,
      {List<String> images = const []}) async {
    if (content.trim().isEmpty && images.isEmpty) return;
    // If a run is already in progress, park the message in the queue.
    if (_isStreaming) {
      enqueueMessage(content, images: images);
      return;
    }

    if (_activeConversation == null) newConversation();

    final userMsg = Message(
        role: Role.user, content: content.trim(), images: images);
    _activeConversation!.messages.add(userMsg);

    if (_activeConversation!.title == 'New Chat') {
      final t = content.trim();
      _activeConversation!.title = t.isNotEmpty
          ? (t.length > 40 ? '${t.substring(0, 40)}…' : t)
          : '📷 Image${images.length > 1 ? 's' : ''}';
    }

    _isStreaming = true;
    _error = null;
    notifyListeners();

    await StreamingKeepAlive.start();

    // Pre-fetch user memory context (non-blocking — failures are silently
    // swallowed and we proceed without memory rather than blocking the user).
    final memoryCtx = await _fetchUserMemory();

    if (_settings.useBackend && _backend != null) {
      await _runBackendGeneration(memoryCtx: memoryCtx);
    } else {
      await _autoDetectUrl();
      if (mcpAvailable) {
        await _runAgenticLoop(memoryCtx: memoryCtx);
      } else {
        await _runStreamingChat(memoryCtx: memoryCtx);
      }
    }
  }

  // ── Backend generation ────────────────────────────────────────────────────

  Future<void> _runBackendGeneration({String? memoryCtx}) async {
    final conv = _activeConversation!;
    final userMsg = conv.messages.last; // just added in sendMessage()

    // Create local placeholder so the bubble appears immediately
    final assistantMsg = Message(
      role: Role.assistant,
      content: '',
      isStreaming: true,
    );
    conv.messages.add(assistantMsg);
    conv.updatedAt = DateTime.now();
    _streamingBackendMsg = assistantMsg;
    _streamingBackendConvId = conv.id;
    notifyListeners();

    try {
      await _backend!.sendMessage(
        conv.id,
        userMsg.content,
        userMsg.images,
        messageId: userMsg.id,
        // Forward tool definitions so the backend can include them in the LLM
        // request and relay tool_call events back to this client for execution.
        tools: mcpAvailable
            ? mcpTools.map((t) => t.toOpenAiTool()).toList()
            : const [],
        memoryContext: memoryCtx,
        // Send the client's local datetime so the backend uses the user's
        // timezone rather than the server's (which is often UTC in Docker).
        clientDatetime: settings.injectDateTime
            ? DateFormat('EEEE, d MMMM yyyy, HH:mm').format(DateTime.now())
            : null,
      );
    } catch (e) {
      assistantMsg.isStreaming = false;
      assistantMsg.content = '[Error: $e]';
      _streamingBackendMsg = null;
      _streamingBackendConvId = null;
      _error = e.toString();
      _isStreaming = false;
      StreamingKeepAlive.stop();
      notifyListeners();
      _processNextInQueue();
    }
    // Completion is handled by _handleBackendEvent via the WS stream.
  }

  void _handleBackendEvent(BackendEvent event) {
    switch (event) {
      case BEToken(
            conversationId: final cid,
            content: final text,
          ):
        if (cid == _streamingBackendConvId && _streamingBackendMsg != null) {
          _streamingBackendMsg!.content += text;
          notifyListeners();
        }

      case BEMessageComplete(
          conversationId: final cid,
          promptTokens: final pt,
          completionTokens: final ct,
        ):
        if (cid == _streamingBackendConvId) {
          _streamingBackendMsg?.isStreaming = false;
          _streamingBackendMsg = null;
          if (pt != null) {
            _promptTokens[cid] = pt;
            _completionTokens[cid] = ct ?? 0;
          }
          final completedConvId = _streamingBackendConvId;
          _streamingBackendConvId = null;
          _isStreaming = false;
          StreamingKeepAlive.stop();
          notifyListeners();
          // Reload from backend to get canonical message state (tool messages,
          // correct IDs, etc.) after a completed generation.
          if (completedConvId != null && _backend != null) {
            _loadConversationMessages(completedConvId);
          }
          _processNextInQueue();
        }

      case BEError(conversationId: final cid, detail: final detail):
        if (cid == _streamingBackendConvId || cid == null) {
          if (_streamingBackendMsg != null) {
            _streamingBackendMsg!.isStreaming = false;
            if (_streamingBackendMsg!.content.isEmpty) {
              _streamingBackendMsg!.content = '[Error: $detail]';
            }
          }
          _streamingBackendMsg = null;
          _streamingBackendConvId = null;
          _error = detail;
          _isStreaming = false;
          StreamingKeepAlive.stop();
          notifyListeners();
          _processNextInQueue();
        }

      case BECancelled(conversationId: final cid):
        if (cid == _streamingBackendConvId) {
          _streamingBackendMsg?.isStreaming = false;
          _streamingBackendMsg = null;
          _streamingBackendConvId = null;
          _isStreaming = false;
          StreamingKeepAlive.stop();
          notifyListeners();
        }

      case BEGenerationStart(conversationId: final cid):
        // Initial generation_start: the placeholder was already created in
        // _runBackendGeneration(), so nothing to do.
        // Subsequent generation_start (after tool calls): the previous
        // _streamingBackendMsg was finalized by BEToolCall; create a new
        // placeholder for the continuation response.
        if (cid == _streamingBackendConvId && _streamingBackendMsg == null) {
          final newMsg = Message(
            role: Role.assistant,
            content: '',
            isStreaming: true,
          );
          // Always append to the owning conversation, not the currently
          // visible one — the user may have switched chats mid-generation.
          _conversationById(cid)?.messages.add(newMsg);
          _streamingBackendMsg = newMsg;
          notifyListeners();
        }

      case BEToolCall(
            conversationId: final cid,
            callId: final callId,
            name: final toolName,
            arguments: final argsJson,
          ):
        if (cid == _streamingBackendConvId) {
          // Finalize the current streaming message (may contain thinking content).
          _streamingBackendMsg?.isStreaming = false;
          _streamingBackendMsg = null;

          // Add an assistant message with toolCalls so the "Performing X…"
          // bubble is visible during live streaming (mirrors _runAgenticLoop).
          Map<String, dynamic> parsedArgs;
          try {
            parsedArgs = jsonDecode(argsJson) as Map<String, dynamic>;
          } catch (_) {
            parsedArgs = {};
          }
          final conv = _conversationById(cid);
          conv?.messages.add(Message(
            role: Role.assistant,
            toolCalls: [ToolCall(id: callId, name: toolName, arguments: parsedArgs)],
          ));

          // Show a tool-execution placeholder in the owning conversation,
          // regardless of which chat the user is currently viewing.
          final toolMsg = Message(
            role: Role.tool,
            content: '',
            toolCallId: callId,
            toolName: toolName,
            isStreaming: true,
          );
          conv?.messages.add(toolMsg);
          notifyListeners();

          // Execute asynchronously and relay result back to backend.
          _executeRelayedToolCall(cid, callId, toolName, argsJson, toolMsg);
        }
    }
  }

  /// Looks up a conversation by id from the in-memory list.
  /// Returns null if not found.
  Conversation? _conversationById(String id) {
    for (final c in _conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Executes an MCP tool requested by the backend and sends the result back.
  void _executeRelayedToolCall(
    String convId,
    String callId,
    String toolName,
    String argsJson,
    Message toolMsg,
  ) {
    // Run async without awaiting so the event loop can process more events.
    () async {
      String content;
      bool isError = false;
      try {
        Map<String, dynamic> args;
        try {
          args = jsonDecode(argsJson) as Map<String, dynamic>;
        } catch (_) {
          args = {};
        }
        final service = _toolServiceMap[toolName];
        if (service == null) {
          content = 'Tool error: unknown tool "$toolName"';
          isError = true;
        } else {
          final mcpContent = await service.callTool(toolName, args);
          toolMsg.toolContent = mcpContent;
          content = mcpContent.map((c) => c.toApiText()).join('\n');
        }
      } catch (e) {
        content = 'Tool error: $e';
        isError = true;
      }

      toolMsg.content = content;
      toolMsg.isStreaming = false;
      notifyListeners();

      // Send the result back to the backend to unblock its await.
      try {
        await _backend?.sendToolResult(convId, callId, content,
            isError: isError);
      } catch (_) {}
    }();
  }

  // ── Streaming (no tools) ──────────────────────────────────────────────────

  Future<void> _runStreamingChat({String? memoryCtx}) async {
    final assistantMsg = Message(
      role: Role.assistant,
      content: '',
      isStreaming: true,
    );
    _activeConversation!.messages.add(assistantMsg);
    _activeConversation!.updatedAt = DateTime.now();
    notifyListeners();

    try {
      final api = ApiService(_settingsWithMemory(memoryCtx), activeBaseUrl);
      final history = _activeConversation!.messages
          .where((m) => m.id != assistantMsg.id)
          .toList();

      final convId = _activeConversation!.id;
      _streamSub = api.streamChat(
        history,
        onUsage: (prompt, completion) {
          _promptTokens[convId] = prompt;
          _completionTokens[convId] = completion;
        },
      ).listen(
        (chunk) {
          assistantMsg.content += chunk;
          notifyListeners();
        },
        onDone: () {
          assistantMsg.isStreaming = false;
          _isStreaming = false;
          StreamingKeepAlive.stop();
          _persistConversations();
          notifyListeners();
          _processNextInQueue();
        },
        onError: (Object e) {
          assistantMsg.isStreaming = false;
          if (assistantMsg.content.isEmpty) {
            assistantMsg.content = '[Error: $e]';
          }
          _error = e.toString();
          _isStreaming = false;
          StreamingKeepAlive.stop();
          _persistConversations();
          notifyListeners();
          _processNextInQueue();
        },
        cancelOnError: true,
      );
    } catch (e) {
      assistantMsg.isStreaming = false;
      assistantMsg.content = '[Error: $e]';
      _error = e.toString();
      _isStreaming = false;
      StreamingKeepAlive.stop();
      _persistConversations();
      notifyListeners();
    }
  }

  // ── Agentic loop (with MCP tools, fully streaming) ───────────────────────

  Future<void> _runAgenticLoop({String? memoryCtx}) async {
    final api = ApiService(_settingsWithMemory(memoryCtx), activeBaseUrl);
    const maxIterations = 10;

    Message? activeMsg;

    try {
      for (int i = 0; i < maxIterations; i++) {
        final history = _activeConversation!.messages
            .where((m) => activeMsg == null || m.id != activeMsg.id)
            .toList();

        activeMsg =
            Message(role: Role.assistant, content: '', isStreaming: true);
        _activeConversation!.messages.add(activeMsg);
        _activeConversation!.updatedAt = DateTime.now();
        notifyListeners();

        LlmResponse? response;
        await for (final chunk in api.streamChatWithTools(
          history,
          mcpTools,
          (r) => response = r,
        )) {
          activeMsg.content += chunk;
          notifyListeners();
        }

        final resp = response;
        if (resp == null) break;

        // Capture token usage from this turn.
        if (resp.promptTokens != null) {
          _promptTokens[_activeConversation!.id] = resp.promptTokens!;
          _completionTokens[_activeConversation!.id] =
              resp.completionTokens ?? 0;
        }

        if (resp.hasToolCalls) {
          // Keep the streaming placeholder if it accumulated thinking content
          // so the thinking block stays visible in the conversation.
          if (activeMsg.content.isNotEmpty) {
            activeMsg.isStreaming = false; // finalise in-place
          } else {
            _activeConversation!.messages.remove(activeMsg); // empty — discard
          }
          activeMsg = null;
          _activeConversation!.messages.add(Message(
            role: Role.assistant,
            toolCalls: resp.toolCalls,
          ));
          notifyListeners();

          for (final call in resp.toolCalls!) {
            // Add a pending result placeholder immediately so the user
            // sees the spinner before the tool finishes executing.
            final resultMsg = Message(
              role: Role.tool,
              content: '',
              toolCallId: call.id,
              toolName: call.name,
              isStreaming: true,
            );
            _activeConversation!.messages.add(resultMsg);
            notifyListeners(); // spinner appears now, before the HTTP call

            try {
              final service = _toolServiceMap[call.name];
              if (service == null) {
                resultMsg.content =
                    'Tool error: unknown tool "${call.name}"';
                resultMsg.toolContent = [
                  McpContent(type: 'text', text: resultMsg.content)
                ];
              } else {
                final content =
                    await service.callTool(call.name, call.arguments);
                resultMsg.content =
                    content.map((c) => c.toApiText()).join('\n');
                resultMsg.toolContent = content;
              }
            } catch (e) {
              resultMsg.content = 'Tool error: $e';
              resultMsg.toolContent = [
                McpContent(type: 'text', text: resultMsg.content)
              ];
            } finally {
              resultMsg.isStreaming = false;
              notifyListeners(); // result fills in
            }
          }
        } else {
          activeMsg.isStreaming = false;
          activeMsg = null;
          notifyListeners();
          break;
        }
      }
    } catch (e) {
      if (activeMsg != null) {
        _activeConversation!.messages.remove(activeMsg);
        activeMsg = null;
      }
      _error = e.toString();
      _activeConversation!.messages.add(
        Message(role: Role.assistant, content: '[Error: $e]'),
      );
    } finally {
      if (activeMsg != null) {
        _activeConversation!.messages.remove(activeMsg);
      }
      _isStreaming = false;
      StreamingKeepAlive.stop();
      _persistConversations();
      notifyListeners();
      _processNextInQueue();
    }
  }

  Future<void> cancelStream() async {
    _messageQueue.clear();
    if (_settings.useBackend && _backend != null) {
      final cid = _streamingBackendConvId ?? _activeConversation?.id;
      if (cid != null) _backend!.cancelGeneration(cid);
    } else {
      await _streamSub?.cancel();
      _streamSub = null;
    }
    if (_activeConversation != null) {
      final msgs = _activeConversation!.messages;
      if (msgs.isNotEmpty && msgs.last.isStreaming) {
        msgs.last.isStreaming = false;
      }
    }
    _streamingBackendMsg = null;
    _streamingBackendConvId = null;
    _isStreaming = false;
    StreamingKeepAlive.stop();
    notifyListeners();
  }

  Future<void> _persistConversations() =>
      _storage.saveConversations(_conversations);

  // ── Auto-sync timer ───────────────────────────────────────────────────────

  /// Starts (or restarts) the periodic auto-sync timer using the current
  /// settings.  No-op when auto-sync is disabled or the sync key is not loaded.
  void _startAutoSync() {
    _stopAutoSync();
    if (!_settings.autoSyncEnabled || !syncReady) return;
    final interval = Duration(minutes: _settings.autoSyncIntervalMinutes);
    _autoSyncTimer = Timer.periodic(interval, (_) {
      if (syncReady && _syncStatus != SyncStatus.syncing) {
        syncNow().catchError((_) {});
      }
    });
  }

  void _stopAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
  }

  /// Persists auto-sync settings and restarts the timer immediately.
  Future<void> saveAutoSyncSettings({
    required bool enabled,
    required int intervalMinutes,
  }) async {
    _settings = _settings.copyWith(
      autoSyncEnabled: enabled,
      autoSyncIntervalMinutes: intervalMinutes,
    );
    await _storage.saveSettings(_settings);
    _startAutoSync();
    notifyListeners();
  }

  // ── Sync ──────────────────────────────────────────────────────────────────

  /// Registers a new sync account. Derives both the auth hash and the in-memory
  /// encryption key from [password]. Persists tokens to settings.
  Future<void> syncRegister(
      String serverUrl, String username, String password) async {
    final result =
        await SyncService.register(serverUrl, username, password);
    final crypto = await SyncCrypto.fromCredentials(password, username);
    _syncKey = crypto.keyBytes;
    _settings = _settings.copyWith(
      syncUrl: serverUrl,
      syncUsername: username,
      syncAccessToken: result.accessToken,
      syncRefreshToken: result.refreshToken,
    );
    await _storage.saveSettings(_settings);
    _startAutoSync();
    notifyListeners();
  }

  /// Logs in to an existing sync account. Derives the encryption key from
  /// [password] and persists tokens. Call [syncNow] afterwards to pull data.
  Future<void> syncLogin(
      String serverUrl, String username, String password) async {
    final result = await SyncService.login(serverUrl, username, password);
    final crypto = await SyncCrypto.fromCredentials(password, username);
    _syncKey = crypto.keyBytes;
    _settings = _settings.copyWith(
      syncUrl: serverUrl,
      syncUsername: username,
      syncAccessToken: result.accessToken,
      syncRefreshToken: result.refreshToken,
    );
    await _storage.saveSettings(_settings);
    _startAutoSync();
    notifyListeners();
  }

  /// Removes all sync credentials and clears the in-memory key.
  Future<void> syncLogout() async {
    _stopAutoSync();
    _syncKey = null;
    _settings = _settings.copyWith(
      syncUrl: '',
      syncUsername: '',
      syncAccessToken: '',
      syncRefreshToken: '',
      syncLastAt: '',
    );
    _syncStatus = SyncStatus.idle;
    _syncError = null;
    await _storage.saveSettings(_settings);
    notifyListeners();
  }

  /// Runs a full bidirectional sync.
  ///
  /// Conversation strategy: union merge — for each conversation the side with
  /// the newer [updatedAt] wins. Conversations present on only one side are
  /// copied to the other. Server-deleted conversations are removed locally.
  ///
  /// Settings strategy: last-write-wins based on [updatedAt].
  ///
  /// Note: conversations deleted locally (via [deleteConversation]) while
  /// offline will be re-pulled from the server on the next sync unless the
  /// deletion has been propagated first. Use [deleteConversation] which sends
  /// the DELETE immediately; offline deletions are best-effort in v1.
  Future<void> syncNow() async {
    if (_syncKey == null) throw StateError('Sync key not loaded — log in first');
    if (_settings.syncUrl.isEmpty) throw StateError('Sync URL not configured');

    _syncStatus = SyncStatus.syncing;
    _syncError = null;
    notifyListeners();

    try {
      final crypto = SyncCrypto.fromKey(_syncKey!);
      final svc = SyncService(
        serverUrl: _settings.syncUrl,
        accessToken: _settings.syncAccessToken,
        refreshToken: _settings.syncRefreshToken,
        onTokensRefreshed: (access, refresh) async {
          _settings = _settings.copyWith(
            syncAccessToken: access,
            syncRefreshToken: refresh,
          );
          await _storage.saveSettings(_settings);
        },
      );

      final state = await svc.getState();

      await _syncConversations(svc, crypto, state);
      await _syncSettings(svc, crypto, state.settingsUpdatedAt);

      _settings = _settings.copyWith(
          syncLastAt: DateTime.now().toUtc().toIso8601String());
      await _storage.saveSettings(_settings);

      _syncStatus = SyncStatus.idle;
    } on SyncAuthExpiredException {
      _syncKey = null;
      _settings = _settings.copyWith(syncAccessToken: '', syncRefreshToken: '');
      await _storage.saveSettings(_settings);
      _syncStatus = SyncStatus.error;
      _syncError = 'Session expired — please log in again.';
    } catch (e) {
      _syncStatus = SyncStatus.error;
      _syncError = e.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> _syncConversations(
    SyncService svc,
    SyncCrypto crypto,
    SyncStateResult state,
  ) async {
    final localById = {for (final c in _conversations) c.id: c};
    final serverById = {for (final m in state.conversations) m.id: m};

    // Push: local conversations newer than server (or not on server at all).
    for (final local in _conversations) {
      final serverMeta = serverById[local.id];
      if (serverMeta == null ||
          (!serverMeta.deleted &&
              local.updatedAt.isAfter(serverMeta.updatedAt))) {
        final blob = await crypto
            .encrypt(jsonEncode(local.toJson()));
        await svc.putConversation(local.id, blob, local.updatedAt);
      }
    }

    // Pull: server conversations newer than local or not present locally.
    for (final meta in state.conversations) {
      if (meta.deleted) {
        // Server tombstone → remove locally.
        _conversations.removeWhere((c) => c.id == meta.id);
        continue;
      }
      final local = localById[meta.id];
      if (local == null || meta.updatedAt.isAfter(local.updatedAt)) {
        final blobResult = await svc.getConversation(meta.id);
        final plain = await crypto.decrypt(blobResult.encryptedBlob);
        final conv = Conversation.fromJson(
            jsonDecode(plain) as Map<String, dynamic>);
        final idx = _conversations.indexWhere((c) => c.id == meta.id);
        if (idx >= 0) {
          _conversations[idx] = conv;
        } else {
          _conversations.add(conv);
        }
      }
    }

    // Sort by most recently updated.
    _conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _persistConversations();
    notifyListeners();
  }

  Future<void> _syncSettings(
    SyncService svc,
    SyncCrypto crypto,
    DateTime? serverSettingsUpdatedAt,
  ) async {
    final localUpdatedAt = _settings.syncLastAt.isNotEmpty
        ? DateTime.tryParse(_settings.syncLastAt)
        : null;

    // Push local settings if they're newer (or server has nothing yet).
    final shouldPush = serverSettingsUpdatedAt == null ||
        (localUpdatedAt != null &&
            localUpdatedAt.isAfter(serverSettingsUpdatedAt));

    if (shouldPush) {
      final blob = await crypto
          .encrypt(jsonEncode(_settings.toSyncJson()));
      await svc.putSettings(
          blob, localUpdatedAt ?? DateTime.now().toUtc());
    } else {
      // Pull and merge — preserve device-specific sync credentials.
      final remote = await svc.getSettings();
      if (remote != null) {
        final plain = await crypto.decrypt(remote.encryptedBlob);
        final remoteSettings = AppSettings.fromJson(
            jsonDecode(plain) as Map<String, dynamic>);
        _settings = remoteSettings.copyWith(
          syncUrl: _settings.syncUrl,
          syncUsername: _settings.syncUsername,
          syncAccessToken: _settings.syncAccessToken,
          syncRefreshToken: _settings.syncRefreshToken,
          syncLastAt: _settings.syncLastAt,
        );
        await _storage.saveSettings(_settings);
      }
    }
  }

  /// Propagates a conversation deletion to the server immediately (when online).
  /// Falls back to local-only deletion if the sync server is unreachable.
  Future<void> deleteConversationWithSync(String id) async {
    deleteConversation(id); // local delete first (instant feedback)
    if (!syncReady) return;
    try {
      final svc = SyncService(
        serverUrl: _settings.syncUrl,
        accessToken: _settings.syncAccessToken,
        refreshToken: _settings.syncRefreshToken,
        onTokensRefreshed: (access, refresh) async {
          _settings = _settings.copyWith(
            syncAccessToken: access,
            syncRefreshToken: refresh,
          );
          await _storage.saveSettings(_settings);
        },
      );
      await svc.deleteConversation(id);
    } catch (_) {
      // Offline — deletion will not be propagated; acceptable in v1.
    }
  }

  // ── Backup / Restore ──────────────────────────────────────────────────────

  /// Serialises all conversations + settings into a backup JSON string.
  String buildBackupJson() {
    return jsonEncode({
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'conversations': _conversations.map((c) => c.toJson()).toList(),
      'settings': _settings.toJson(),
    });
  }

  /// Replaces all conversations and settings from a backup JSON string.
  /// Returns `null` on success, or an error description on failure.
  Future<String?> applyBackupJson(String jsonStr) async {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final version = data['version'] as int? ?? 0;
      if (version > 1) {
        return 'Backup format v$version is newer than this app supports.';
      }
      final convList = (data['conversations'] as List<dynamic>)
          .map((j) => Conversation.fromJson(j as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      // Parse imported settings but preserve all device-local fields so that
      // backend credentials, sync tokens, and debug settings are not wiped.
      final imported =
          AppSettings.fromJson(data['settings'] as Map<String, dynamic>);
      final merged = imported.copyWith(
        useBackend: _settings.useBackend,
        backendUrl: _settings.backendUrl,
        backendToken: _settings.backendToken,
        backendAllowSelfSigned: _settings.backendAllowSelfSigned,
        backendAwayUrl: _settings.backendAwayUrl,
        autoSyncEnabled: _settings.autoSyncEnabled,
        autoSyncIntervalMinutes: _settings.autoSyncIntervalMinutes,
        debugLogging: _settings.debugLogging,
        debugLogPath: _settings.debugLogPath,
        syncUrl: _settings.syncUrl,
        syncUsername: _settings.syncUsername,
        syncAccessToken: _settings.syncAccessToken,
        syncRefreshToken: _settings.syncRefreshToken,
        syncLastAt: _settings.syncLastAt,
      );

      _conversations = convList;
      _settings = merged;
      _activeConversation = null;
      _secretsUnlocked = false;

      if (_settings.useBackend && _backend != null) {
        // Upload conversations to the backend, then refresh from server so
        // the local list reflects what was actually stored.
        await _uploadConversationsToBackend(convList);
        try {
          _conversations = await _backend!.fetchConversations();
        } catch (_) {}
      } else {
        await _storage.saveConversations(_conversations);
      }

      await _storage.saveSettings(_settings);
      notifyListeners();
      return null;
    } catch (e) {
      return 'Could not parse backup: $e';
    }
  }

  /// Uploads a list of conversations (with all their messages) to the backend.
  /// Used during backup import in backend mode.
  Future<void> _uploadConversationsToBackend(List<Conversation> convs) async {
    for (final conv in convs) {
      // Create conversation — may already exist, that's fine.
      try {
        await _backend!.createConversation(
          id: conv.id,
          title: conv.title,
          isSecret: conv.isSecret,
          userBubbleColor: conv.userBubbleColor,
          assistantBubbleColor: conv.assistantBubbleColor,
        );
      } catch (_) {}
      // Upload messages individually — each has its own error boundary so one
      // failure (e.g. duplicate ID) doesn't abort the rest of the conversation.
      for (final msg in conv.messages) {
        try {
          await _backend!.addMessage(conv.id, msg);
        } catch (_) {}
      }
    }
  }
}
