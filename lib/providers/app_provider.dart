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
import '../services/file_mcp_service.dart';
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
  /// Tokens that arrived before the local streaming placeholder was ready
  /// (e.g. reconnect or cross-device — generation_start comes before messages
  /// are loaded from the REST API).  Flushed into the placeholder as soon as
  /// it is created.
  final Map<String, StringBuffer> _pendingTokens = {};
  /// Maps call_id → the local tool-result Message for server-side tool calls.
  /// Used to fill in the result bubble when the backend sends a tool_result event.
  final Map<String, Message> _serverToolMsgs = {};

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

  // ── Built-in file MCP ─────────────────────────────────────────────────────

  /// Sentinel server-id for the built-in filesystem MCP service.
  static const _kFileMcpId = '__builtin_files__';

  /// Currently selected folder path (session-only, never persisted).
  String? _fileMcpFolder;

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
  /// Prefers the in-memory value (updated immediately after each response);
  /// falls back to the persisted value on the Conversation so the ring is
  /// non-zero immediately after a restart or cross-device sync.
  int? get activePromptTokens {
    if (_activeConversation == null) return null;
    return _promptTokens[_activeConversation!.id]
        ?? _activeConversation!.lastPromptTokens;
  }

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
  /// Expose the live [BackendService] for direct API calls (e.g. 2FA management).
  BackendService? get backendService => _backend;

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

  // ── Built-in file MCP getters ─────────────────────────────────────────────

  bool get fileMcpEnabled => _settings.fileMcpEnabled;
  String? get fileMcpFolder => _fileMcpFolder;

  /// Sets (or clears) the active folder for the built-in file MCP service.
  ///
  /// When [path] is non-null a [FileMcpService] is created and its tools are
  /// registered in the same maps used by network MCP servers, so both the
  /// direct agentic loop and the backend relay path pick them up automatically.
  ///
  /// When [path] is null (or the folder was just cleared) the service is
  /// removed and the tools become unavailable to the LLM.
  void setFileMcpFolder(String? path) {
    // Tear down any existing built-in service.
    _mcpServiceCache.remove(_kFileMcpId)?.dispose();
    _mcpToolsByServer.remove(_kFileMcpId);
    _mcpErrorByServer.remove(_kFileMcpId);

    _fileMcpFolder = path;

    if (path != null && path.isNotEmpty) {
      final svc = FileMcpService(path);
      _mcpServiceCache[_kFileMcpId] = svc;
      _mcpToolsByServer[_kFileMcpId] = FileMcpService.toolDefs;
    }

    _rebuildToolServiceMap();
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
    // Only attempt client-side MCP fetching in direct (non-backend) mode.
    // In backend mode the server handles MCP from its own network; the client
    // can't reliably reach those servers when away from home anyway.
    if (!(_settings.useBackend && _settings.backendToken.isNotEmpty)) {
      _fetchAllMcpTools();
    }
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
    final client = _settings.allowSelfSigned
        ? IOClient(HttpClient()..badCertificateCallback = (_, __, ___) => true)
        : http.Client();
    try {
      var url = _settings.baseUrlHome.trimRight();
      if (url.endsWith('/')) url = url.substring(0, url.length - 1);
      await client
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
    } finally {
      client.close();
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

  /// [localOnlyOnly] = true → only fetch servers marked [McpServer.localOnly].
  /// Used in backend mode to prime the client-relay set without fetching
  /// servers that the backend handles itself.
  Future<void> _fetchAllMcpTools({bool localOnlyOnly = false}) async {
    final enabled = _settings.mcpServers
        .where((s) => s.enabled && s.baseUrlHome.isNotEmpty)
        .where((s) => !localOnlyOnly || s.localOnly)
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
    // In direct mode: fetch everything.
    // In backend mode: only fetch localOnly servers (client relay); the
    // backend connects to the rest itself from its own network.
    if (!(_settings.useBackend && _settings.backendToken.isNotEmpty)) {
      for (final s in toFetch) {
        fetchMcpToolsForServer(s);
      }
    } else {
      for (final s in toFetch.where((s) => s.localOnly)) {
        fetchMcpToolsForServer(s);
      }
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

  // ── Token refresh helpers ─────────────────────────────────────────────────

  /// Decode the JWT payload (without signature verification) to check the
  /// `exp` claim.  Returns true if the token is expired or unparseable.
  static bool _isTokenExpired(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;
      // JWT uses base64url without padding — normalize to standard base64.
      final padded = base64Url.normalize(parts[1]);
      final payload = utf8.decode(base64Url.decode(padded));
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final exp = data['exp'] as int?;
      if (exp == null) return false;
      final expiry =
          DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
      // Add a 30-second buffer so we refresh slightly before the server rejects.
      return DateTime.now().toUtc().isAfter(
            expiry.subtract(const Duration(seconds: 30)),
          );
    } catch (_) {
      return false; // If we can't parse it, let the server decide.
    }
  }

  /// Try to refresh the backend access token using the stored refresh token.
  /// Updates [_settings] and persists to storage on success.
  /// Returns true if the access token was successfully renewed.
  Future<bool> _tryRefreshBackendToken() async {
    final refreshToken = _settings.backendRefreshToken;
    if (refreshToken.isEmpty) return false;
    try {
      final result = await BackendService.refreshTokenStatic(
        _settings.backendUrl,
        refreshToken,
        allowSelfSigned: _settings.backendAllowSelfSigned,
      );
      _settings = _settings.copyWith(
        backendToken: result.token!,
        backendRefreshToken: result.refreshToken ?? refreshToken,
      );
      await _storage.saveSettings(_settings);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _connectBackend() async {
    if (_backendConnecting) return;
    _backendConnecting = true;
    _backendConnectError = null;
    notifyListeners();

    try {
      // Proactively refresh the access token if it has already expired.
      // This avoids a failed WS connect and an extra round-trip.
      if (_settings.backendToken.isNotEmpty &&
          _isTokenExpired(_settings.backendToken)) {
        final refreshed = await _tryRefreshBackendToken();
        if (!refreshed) {
          _backendConnectError =
              'Session expired — please log in again.';
          _backendConnecting = false;
          notifyListeners();
          return;
        }
      }
      _backend?.dispose();
      final activeUrl = await _resolveBackendUrl();
      _backend = BackendService(
        baseUrl: activeUrl,
        token: _settings.backendToken,
        allowSelfSigned: _settings.backendAllowSelfSigned,
      );

      // Register the event listener BEFORE opening the WebSocket so that the
      // generation_start replay the backend sends immediately on connect is
      // never dropped.  (Broadcast streams discard events with no listeners.)
      _backendEventSub?.cancel();
      _backendEventSub = _backend!.events.listen(_handleBackendEvent);

      await _backend!.connect();

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
            'backendRefreshToken': _settings.backendRefreshToken,
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

      // If the backend reports an in-progress generation (is_generating flag)
      // and we haven't already been notified via a generation_start event,
      // prime the streaming state now so tokens arriving later are handled.
      final generatingConv =
          convs.where((c) => c.isGenerating).firstOrNull;
      if (generatingConv != null && _streamingBackendConvId == null) {
        _streamingBackendConvId = generatingConv.id;
        _isStreaming = true;
      }

      // Pre-load messages for the initially active conversation so the user
      // sees content immediately without having to tap it first.
      if (_activeConversation != null) {
        _loadConversationMessages(_activeConversation!.id);
      }
      // Also pre-load the generating conversation if it is different from the
      // active one so the streaming placeholder is set up immediately.
      if (_streamingBackendConvId != null &&
          _streamingBackendConvId != _activeConversation?.id) {
        _loadConversationMessages(_streamingBackendConvId!);
      }
      // In backend mode the server handles most MCP servers directly.
      // However, servers marked localOnly run on the client's local network
      // and must be reached by the client — fetch their tools now so they can
      // be relayed through the WebSocket during generation.
      _fetchAllMcpTools(localOnlyOnly: true);
    } on BackendAuthException {
      // The server rejected our access token (401/403).  Try once to refresh.
      _backend?.dispose();
      _backend = null;
      _backendConnecting = false; // allow the recursive call below
      final refreshed = await _tryRefreshBackendToken();
      if (refreshed) {
        // Retry with the new token (recursive — guarded by _backendConnecting).
        await _connectBackend();
      } else {
        _backendConnectError = 'Session expired — please log in again.';
        notifyListeners();
      }
      return;
    } catch (e) {
      // Check for WS upgrade auth failures (server sends HTTP 403 when the
      // token is invalid — the client sees a WebSocketException with "403").
      final msg = e.toString().toLowerCase();
      final looksLikeAuthError = msg.contains('403') ||
          msg.contains('401') ||
          msg.contains('1008') ||
          msg.contains('unauthorized');
      if (looksLikeAuthError) {
        _backend?.dispose();
        _backend = null;
        _backendConnecting = false;
        final refreshed = await _tryRefreshBackendToken();
        if (refreshed) {
          await _connectBackend();
        } else {
          _backendConnectError = 'Session expired — please log in again.';
          notifyListeners();
        }
        return;
      }
      // Give a friendly label when the error is a timeout so the user doesn't
      // see the raw Dart "TimeoutException: Future not completed after …".
      final errStr = e.toString();
      _backendConnectError = (e is TimeoutException ||
              errStr.contains('TimeoutException') ||
              errStr.toLowerCase().contains('timed out'))
          ? 'Connection timed out — check the server URL and your network.'
          : errStr;
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
    _serverToolMsgs.clear();
    _pendingTokens.clear();
  }

  /// Reconnects to the backend using the stored token (no re-authentication).
  Future<void> backendReconnect() => _connectBackend();

  /// Login to the backend server.
  /// Returns a [LoginResult]. If [LoginResult.requires2fa] is true the caller
  /// must prompt the user for a TOTP code and then call [backendComplete2fa].
  Future<LoginResult> backendLogin(
    String url,
    String username,
    String password,
  ) async {
    final result = await BackendService.loginStatic(
      url,
      username,
      password,
      allowSelfSigned: _settings.backendAllowSelfSigned,
    );
    if (result.requires2fa) {
      // Store URL so complete2fa can use it; do not connect yet.
      _settings = _settings.copyWith(backendUrl: url);
      await _storage.saveSettings(_settings);
      return result;
    }
    _settings = _settings.copyWith(
      backendUrl: url,
      backendToken: result.token!,
      backendRefreshToken: result.refreshToken ?? '',
      useBackend: true,
    );
    await _storage.saveSettings(_settings);
    await _connectBackend();
    return result;
  }

  /// Finalize a 2FA login with the TOTP [code] and the [partialToken] from
  /// the previous [backendLogin] call.
  Future<void> backendComplete2fa(String partialToken, String code) async {
    final result = await BackendService.complete2faStatic(
      _settings.backendUrl,
      partialToken,
      code,
      allowSelfSigned: _settings.backendAllowSelfSigned,
    );
    _settings = _settings.copyWith(
      backendToken: result.token!,
      backendRefreshToken: result.refreshToken ?? '',
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
    final result = await BackendService.registerStatic(
      url,
      username,
      password,
      allowSelfSigned: _settings.backendAllowSelfSigned,
    );
    _settings = _settings.copyWith(
      backendUrl: url,
      backendToken: result.token!,
      backendRefreshToken: result.refreshToken ?? '',
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
      backendRefreshToken: '',
    );
    await _storage.saveSettings(_settings);
    // Reload local conversations
    _conversations = await _storage.loadConversations();
    final logoutVisible =
        _conversations.where((c) => !c.isSecret).toList();
    _activeConversation =
        logoutVisible.isNotEmpty ? logoutVisible.first : null;
    // Switching back to direct mode — fetch MCP tools from the local network.
    _fetchAllMcpTools();
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
    if (_settings.useBackend && _backend != null) {
      if (conv.messages.isEmpty) {
        // Lazy-load messages from the backend.
        _loadConversationMessages(conv.id);
      } else if (conv.id == _streamingBackendConvId &&
          _streamingBackendMsg == null) {
        // Messages already loaded but the streaming placeholder isn't set up
        // yet (e.g. user taps the generating conv before _loadConversationMessages
        // completes on another code path).
        _setupStreamingPlaceholder(conv);
        notifyListeners();
      }
    }
  }

  Future<void> _loadConversationMessages(String convId) async {
    try {
      final full = await _backend!.fetchConversation(convId);
      final idx = _conversations.indexWhere((c) => c.id == convId);
      if (idx >= 0) _conversations[idx] = full;
      if (_activeConversation?.id == convId) _activeConversation = full;
      // If this is the conversation currently being generated and the local
      // streaming placeholder hasn't been set up yet, do it now using the
      // freshly-loaded message list (which includes the DB placeholder that
      // llm.py commits before it starts streaming tokens).
      if (convId == _streamingBackendConvId && _streamingBackendMsg == null) {
        _setupStreamingPlaceholder(full);
      }
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load messages: $e';
      notifyListeners();
    }
  }

  /// In backend mode: load canonical messages first so [_conversationById]
  /// returns the fresh object, then run auto-title on it.
  Future<void> _loadThenAutoTitle(String convId) async {
    await _loadConversationMessages(convId);
    final conv = _conversationById(convId);
    if (conv != null) unawaited(_maybeAutoTitle(conv));
  }

  /// After the first exchange, asks the LLM for a proper title and replaces
  /// the auto-truncated one. Silently swallows all errors.
  Future<void> _maybeAutoTitle(Conversation conv) async {
    final userMessages =
        conv.messages.where((m) => m.role == Role.user).toList();
    if (userMessages.length != 1) return; // not the first exchange
    final firstMessage = userMessages.first.content;
    if (firstMessage.isEmpty) return; // image-only message — skip

    try {
      final String title;
      if (_settings.useBackend && _backend != null) {
        title = await _backend!.generateTitle(conv.id, firstMessage);
      } else {
        title = await ApiService(_settings, activeBaseUrl).fetchTitle(firstMessage);
      }
      conv.title = title;
      if (!_settings.useBackend) _persistConversations();
      notifyListeners();
    } catch (_) {
      // Keep the auto-truncated title on any failure
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
      final next =
          visibleConversations.isNotEmpty ? visibleConversations.first : null;
      // Use selectConversation so backend mode triggers lazy message loading.
      if (next != null) {
        selectConversation(next);
      } else {
        _activeConversation = null;
      }
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

    // Create the typing-indicator placeholder before any async work so the
    // three-dot animation appears immediately — even while keep-alive starts,
    // URL auto-detection runs, or the memory context is being fetched.
    // The sub-functions receive this placeholder and reuse it instead of
    // creating a second one.
    final placeholder = Message(
      role: Role.assistant,
      content: '',
      isStreaming: true,
    );
    _activeConversation!.messages.add(placeholder);
    _activeConversation!.updatedAt = DateTime.now();
    notifyListeners();

    await StreamingKeepAlive.start();

    // In backend mode the server handles MCP tool listing, tool execution, and
    // memory pre-fetching itself (it is co-located with those services and never
    // "away").  The client only needs to do this work in direct (non-backend) mode.
    final bool usingBackend = _settings.useBackend && _backend != null;
    final memoryCtx = usingBackend ? null : await _fetchUserMemory();

    if (usingBackend) {
      await _runBackendGeneration(
        memoryCtx: memoryCtx,
        userMsg: userMsg,
        placeholder: placeholder,
      );
    } else {
      await _autoDetectUrl();
      if (mcpAvailable) {
        await _runAgenticLoop(memoryCtx: memoryCtx, placeholder: placeholder);
      } else {
        await _runStreamingChat(memoryCtx: memoryCtx, placeholder: placeholder);
      }
    }
  }

  // ── Backend generation ────────────────────────────────────────────────────

  Future<void> _runBackendGeneration({
    String? memoryCtx,
    Message? userMsg,
    Message? placeholder,
  }) async {
    final conv = _activeConversation!;
    // sendMessage() passes userMsg explicitly so we don't have to look it up
    // from conv.messages (which now ends with the placeholder, not the user msg).
    final Message actualUserMsg = userMsg ??
        conv.messages.lastWhere((m) => m.role == Role.user);

    final Message assistantMsg;
    if (placeholder != null) {
      // Reuse the pre-created placeholder — typing dots are already showing.
      assistantMsg = placeholder;
    } else {
      // Fallback for callers that don't pass a placeholder.
      assistantMsg = Message(role: Role.assistant, content: '', isStreaming: true);
      conv.messages.add(assistantMsg);
      conv.updatedAt = DateTime.now();
      notifyListeners();
    }
    _streamingBackendMsg = assistantMsg;
    _streamingBackendConvId = conv.id;

    // Collect tool schemas for client-relay:
    //  • servers with localOnly=true (from MCP Servers config)
    //  • the built-in file MCP when a folder is selected
    // The actual tool execution is relayed via WebSocket BEToolCall →
    // _executeRelayedToolCall.
    final List<Map<String, dynamic>> localOnlyTools = [];
    if (_mcpActive) {
      for (final server in _settings.mcpServers) {
        if (!server.enabled || !server.localOnly) continue;
        for (final tool in (_mcpToolsByServer[server.id] ?? [])) {
          localOnlyTools.add(tool.toOpenAiTool());
        }
      }
      // Built-in file MCP (session folder, if selected).
      for (final tool in (_mcpToolsByServer[_kFileMcpId] ?? [])) {
        localOnlyTools.add(tool.toOpenAiTool());
      }
    }

    try {
      await _backend!.sendMessage(
        conv.id,
        actualUserMsg.content,
        actualUserMsg.images,
        messageId: actualUserMsg.id,
        // localOnly tools are sent by the client and relayed via WebSocket;
        // all other MCP servers are handled by the backend directly.
        // memoryContext is omitted — backend pre-fetches it from non-local
        // memory servers before the first LLM call.
        tools: localOnlyTools,
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
          // Normal fast path: placeholder is ready, append immediately.
          _streamingBackendMsg!.content += text;
          notifyListeners();
        } else if (cid == _streamingBackendConvId) {
          // Placeholder not ready yet (messages still loading) — buffer.
          (_pendingTokens[cid] ??= StringBuffer()).write(text);
        }

      case BEMessageComplete(
          conversationId: final cid,
          promptTokens: final pt,
          completionTokens: final ct,
        ):
        if (cid == _streamingBackendConvId) {
          // Discard any buffered tokens — generation is complete and the
          // canonical content will be loaded from the DB via _loadThenAutoTitle.
          _pendingTokens.remove(cid);
          _streamingBackendMsg?.isStreaming = false;
          _streamingBackendMsg = null;
          if (pt != null) {
            _promptTokens[cid] = pt;
            _completionTokens[cid] = ct ?? 0;
            // Persist on the local Conversation object so the ring survives
            // reconnects.  The backend DB is the authoritative store in
            // backend mode, but updating local state keeps things responsive.
            final conv = _conversations.firstWhere(
              (c) => c.id == cid,
              orElse: () => throw StateError('conv not found'),
            );
            conv.lastPromptTokens = pt;
          }
          final completedConvId = _streamingBackendConvId;
          _streamingBackendConvId = null;
          _isStreaming = false;
          StreamingKeepAlive.stop();
          notifyListeners();
          _processNextInQueue();
          // Reload canonical messages then (if first exchange) auto-title.
          if (completedConvId != null && _backend != null) {
            unawaited(_loadThenAutoTitle(completedConvId));
          }
        }

      case BEError(conversationId: final cid, detail: final detail):
        if (cid == _streamingBackendConvId || cid == null) {
          _pendingTokens.remove(cid ?? _streamingBackendConvId);
          // Finalize any pending server-side tool placeholders.
          for (final msg in _serverToolMsgs.values) {
            msg.isStreaming = false;
          }
          _serverToolMsgs.clear();
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
          _pendingTokens.remove(cid);
          for (final msg in _serverToolMsgs.values) {
            msg.isStreaming = false;
          }
          _serverToolMsgs.clear();
          _streamingBackendMsg?.isStreaming = false;
          _streamingBackendMsg = null;
          _streamingBackendConvId = null;
          _isStreaming = false;
          StreamingKeepAlive.stop();
          notifyListeners();
        }

      case BEGenerationStart(conversationId: final cid):
        if (cid == _streamingBackendConvId && _streamingBackendMsg == null) {
          // Continuation after a tool call: the previous _streamingBackendMsg
          // was finalized by BEToolCall; create a new placeholder.
          // Also handles the reconnect/cross-device case when
          // _streamingBackendConvId was already set by the is_generating flag
          // from fetchConversations() but messages aren't loaded yet.
          final conv = _conversationById(cid);
          if (conv != null) {
            _setupStreamingPlaceholder(conv);
          }
          // If conv not found yet, _setupStreamingPlaceholder will be called
          // from _loadConversationMessages once messages arrive.
          notifyListeners();
        } else if (_streamingBackendConvId == null) {
          // Generation started on another device (cross-device), or a reconnect
          // replay arrived before fetchConversations() set the flag.
          _streamingBackendConvId = cid;
          _isStreaming = true;
          final conv = _conversationById(cid);
          if (conv != null) {
            // Messages already loaded — set up placeholder immediately.
            _setupStreamingPlaceholder(conv);
          } else {
            // Messages not yet loaded; trigger a load.  _setupStreamingPlaceholder
            // will be called from _loadConversationMessages when it completes.
            unawaited(_loadConversationMessages(cid));
          }
          notifyListeners();
        }

      case BEToolCall(
            conversationId: final cid,
            callId: final callId,
            name: final toolName,
            arguments: final argsJson,
            serverSide: final serverSide,
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

          if (serverSide) {
            // Backend executes the tool itself — store the placeholder so
            // BEToolResult can fill it in when the result arrives.
            _serverToolMsgs[callId] = toolMsg;
          } else {
            // Client-relay mode: execute locally and send the result back.
            _executeRelayedToolCall(cid, callId, toolName, argsJson, toolMsg);
          }
        }

      case BEToolResult(
            conversationId: _,
            callId: final callId,
            content: final content,
          ):
        // Backend finished executing a server-side tool — fill in the placeholder.
        final toolMsg = _serverToolMsgs.remove(callId);
        if (toolMsg != null) {
          toolMsg.content = content;
          toolMsg.isStreaming = false;
          notifyListeners();
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

  /// Creates (or reuses) the streaming assistant placeholder for [conv] and
  /// assigns it to [_streamingBackendMsg].
  ///
  /// Tries to reuse an existing empty assistant message at the tail of the
  /// message list — this is the DB placeholder that [llm.py] commits before
  /// it begins streaming.  Falls back to creating a fresh in-memory message
  /// so the UI shows a typing indicator immediately.
  ///
  /// After setting [_streamingBackendMsg], any tokens that buffered while we
  /// were waiting are flushed into the placeholder.
  void _setupStreamingPlaceholder(Conversation conv) {
    if (_streamingBackendMsg != null) return; // already wired up
    final msgs = conv.messages;
    Message placeholder;
    if (msgs.isNotEmpty &&
        msgs.last.role == Role.assistant &&
        msgs.last.content.isEmpty &&
        !msgs.last.isStreaming) {
      // Reuse the DB placeholder committed by llm.py before streaming began.
      placeholder = msgs.last;
      placeholder.isStreaming = true;
    } else {
      placeholder = Message(role: Role.assistant, content: '', isStreaming: true);
      msgs.add(placeholder);
    }
    _streamingBackendMsg = placeholder;
    _flushTokenBuffer(conv.id);
  }

  /// Applies any tokens that arrived before [_streamingBackendMsg] was ready
  /// and clears the buffer entry for [convId].
  void _flushTokenBuffer(String convId) {
    final buf = _pendingTokens.remove(convId);
    if (buf != null && buf.isNotEmpty && _streamingBackendMsg != null) {
      _streamingBackendMsg!.content += buf.toString();
    }
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

  Future<void> _runStreamingChat({
    String? memoryCtx,
    Message? placeholder,
  }) async {
    final conv = _activeConversation!; // capture for auto-title
    final Message assistantMsg;
    if (placeholder != null) {
      assistantMsg = placeholder; // reuse pre-created placeholder
    } else {
      assistantMsg = Message(role: Role.assistant, content: '', isStreaming: true);
      conv.messages.add(assistantMsg);
      conv.updatedAt = DateTime.now();
      notifyListeners();
    }

    try {
      final api = ApiService(_settingsWithMemory(memoryCtx), activeBaseUrl);
      final history = conv.messages
          .where((m) => m.id != assistantMsg.id)
          .toList();

      final convId = conv.id;
      _streamSub = api.streamChat(
        history,
        onUsage: (prompt, completion) {
          _promptTokens[convId] = prompt;
          _completionTokens[convId] = completion;
          conv.lastPromptTokens = prompt;
          _persistConversations();
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
          unawaited(_maybeAutoTitle(conv));
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

  Future<void> _runAgenticLoop({
    String? memoryCtx,
    Message? placeholder,
  }) async {
    final conv = _activeConversation!; // capture for auto-title
    final api = ApiService(_settingsWithMemory(memoryCtx), activeBaseUrl);
    const maxIterations = 10;

    // On the first iteration we reuse the pre-created placeholder so that
    // typing dots appear immediately.  Subsequent iterations (after tool calls)
    // always create fresh messages.
    Message? activeMsg = placeholder;

    try {
      for (int i = 0; i < maxIterations; i++) {
        // Exclude the current streaming message from the LLM history so the
        // empty placeholder is never sent as context.
        final history = _activeConversation!.messages
            .where((m) => activeMsg == null || m.id != activeMsg.id)
            .toList();

        if (activeMsg == null) {
          // No pre-created placeholder available — create one now.
          activeMsg =
              Message(role: Role.assistant, content: '', isStreaming: true);
          _activeConversation!.messages.add(activeMsg);
          _activeConversation!.updatedAt = DateTime.now();
          notifyListeners();
        }
        // else: first iteration with pre-created placeholder — already in
        // the message list, no notifyListeners() needed.

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
          _activeConversation!.lastPromptTokens = resp.promptTokens;
          _persistConversations();
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
      unawaited(_maybeAutoTitle(conv));
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
    for (final msg in _serverToolMsgs.values) {
      msg.isStreaming = false;
    }
    _serverToolMsgs.clear();
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
        backendRefreshToken: _settings.backendRefreshToken,
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
