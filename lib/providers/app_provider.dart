import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/conversation.dart';
import '../models/mcp_server.dart';
import '../models/message.dart';
import '../models/settings.dart';
import '../models/tool_call.dart';
import '../services/api_service.dart';
import '../services/mcp_service.dart';
import '../services/storage_service.dart';
import '../services/streaming_keep_alive.dart';

class AppProvider extends ChangeNotifier {
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

  bool _secretsUnlocked = false;

  // ── Network auto-detection (LLM server) ──────────────────────────────────

  bool _usingAway = false;
  DateTime? _lastNetworkCheck;
  static const _networkCacheDuration = Duration(seconds: 60);

  // ── MCP (multi-server) ────────────────────────────────────────────────────

  /// Cached McpService instances, keyed by server id.
  final Map<String, McpService> _mcpServiceCache = {};
  /// Tools loaded per server id.
  final Map<String, List<McpToolDef>> _mcpToolsByServer = {};
  /// In-progress fetch flag per server id.
  final Map<String, bool> _fetchingByServer = {};
  /// Last error per server id.
  final Map<String, String> _mcpErrorByServer = {};
  /// Whether the away URL is currently active for a given server id.
  final Map<String, bool> _serverUsingAway = {};
  /// Routes a tool name to the McpService that provides it.
  final Map<String, McpService> _toolServiceMap = {};

  /// Runtime override — lets the user toggle tools on/off without touching settings.
  bool _mcpActive = true;

  // ── Getters ───────────────────────────────────────────────────────────────

  AppSettings get settings => _settings;
  List<Conversation> get conversations => _conversations;
  Conversation? get activeConversation => _activeConversation;
  bool get isLoading => _isLoading;
  String? get error => _error;
  List<String> get availableModels => _availableModels;
  bool get fetchingModels => _fetchingModels;
  bool get isStreaming => _isStreaming;
  bool get secretsUnlocked => _secretsUnlocked;
  bool get hasSecretPassword => _settings.secretPasswordHash.isNotEmpty;
  bool get usingAwayUrl => _usingAway;
  bool get mcpActive => _mcpActive;

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

  void toggleMcp() {
    _mcpActive = !_mcpActive;
    notifyListeners();
  }

  String get activeBaseUrl =>
      (_usingAway && _settings.baseUrlAway.isNotEmpty)
          ? _settings.baseUrlAway
          : _settings.baseUrlHome;

  List<Conversation> get visibleConversations => _secretsUnlocked
      ? _conversations
      : _conversations.where((c) => !c.isSecret).toList();

  AppProvider() {
    _init();
  }

  Future<void> _init() async {
    _settings = await _storage.loadSettings();
    _conversations = await _storage.loadConversations();
    if (_conversations.isNotEmpty) {
      _activeConversation = _conversations.firstWhere(
          (c) => !c.isSecret,
          orElse: () => _conversations.first);
    }
    notifyListeners();
    _autoDetectUrl();
    _fetchAllMcpTools();
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

  Future<bool> _pingMcpServer(McpServer server) async {
    try {
      var url = server.baseUrlHome.trimRight();
      if (url.endsWith('/')) url = url.substring(0, url.length - 1);
      if (!url.endsWith('/mcp')) url = '$url/mcp';
      await http
          .get(Uri.parse(url),
              headers: {'Accept': 'application/json, text/event-stream'})
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

  McpService _mcpServiceForServer(McpServer server, String activeUrl) {
    final cached = _mcpServiceCache[server.id];
    if (cached == null || cached.baseUrl != activeUrl) {
      _mcpServiceCache[server.id] = McpService(activeUrl);
    }
    return _mcpServiceCache[server.id]!;
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
      // Auto-detect home vs away for this server.
      String activeUrl = server.baseUrlHome;
      if (server.baseUrlAway.isNotEmpty) {
        final reachable = await _pingMcpServer(server);
        _serverUsingAway[server.id] = !reachable;
        if (!reachable) activeUrl = server.baseUrlAway;
      } else {
        _serverUsingAway.remove(server.id);
      }

      final service = _mcpServiceForServer(server, activeUrl);
      _mcpToolsByServer[server.id] = await service.listTools();
      _rebuildToolServiceMap();
    } catch (e) {
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

  /// Persists an updated server list without re-fetching tools.
  /// Called by McpServersScreen whenever the user edits server config.
  Future<void> saveMcpServers(List<McpServer> servers) async {
    _settings = _settings.copyWith(mcpServers: servers);
    await _storage.saveSettings(_settings);

    // Clean up stale entries for removed servers.
    final ids = servers.map((s) => s.id).toSet();
    _mcpServiceCache.removeWhere((k, _) => !ids.contains(k));
    _mcpToolsByServer.removeWhere((k, _) => !ids.contains(k));
    _fetchingByServer.removeWhere((k, _) => !ids.contains(k));
    _mcpErrorByServer.removeWhere((k, _) => !ids.contains(k));
    _serverUsingAway.removeWhere((k, _) => !ids.contains(k));
    _rebuildToolServiceMap();
    notifyListeners();
  }

  // ── Secret chats ──────────────────────────────────────────────────────────

  static String _hashPassword(String password) =>
      sha256.convert(utf8.encode(password)).toString();

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
    _persistConversations();
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
    _persistConversations();
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
    notifyListeners();
  }

  Future<void> fetchModels() async {
    _fetchingModels = true;
    _error = null;
    notifyListeners();
    try {
      await _autoDetectUrl();
      _availableModels =
          await ApiService(_settings, activeBaseUrl).fetchModels();
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

  void newConversation() {
    final conv = Conversation();
    _conversations.insert(0, conv);
    _activeConversation = conv;
    _persistConversations();
    notifyListeners();
  }

  void selectConversation(Conversation conv) {
    _activeConversation = conv;
    notifyListeners();
  }

  void deleteConversation(String id) {
    _conversations.removeWhere((c) => c.id == id);
    if (_activeConversation?.id == id) {
      _activeConversation = visibleConversations.isNotEmpty
          ? visibleConversations.first
          : null;
    }
    _persistConversations();
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  // ── Chat ──────────────────────────────────────────────────────────────────

  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty || _isStreaming) return;

    if (_activeConversation == null) newConversation();

    final userMsg = Message(role: Role.user, content: content.trim());
    _activeConversation!.messages.add(userMsg);

    if (_activeConversation!.title == 'New Chat') {
      final t = content.trim();
      _activeConversation!.title =
          t.length > 40 ? '${t.substring(0, 40)}…' : t;
    }

    _isStreaming = true;
    _error = null;
    notifyListeners();

    await StreamingKeepAlive.start();
    await _autoDetectUrl();

    if (mcpAvailable) {
      await _runAgenticLoop();
    } else {
      await _runStreamingChat();
    }
  }

  // ── Streaming (no tools) ──────────────────────────────────────────────────

  Future<void> _runStreamingChat() async {
    final assistantMsg = Message(
      role: Role.assistant,
      content: '',
      isStreaming: true,
    );
    _activeConversation!.messages.add(assistantMsg);
    _activeConversation!.updatedAt = DateTime.now();
    notifyListeners();

    try {
      final api = ApiService(_settings, activeBaseUrl);
      final history = _activeConversation!.messages
          .where((m) => m.id != assistantMsg.id)
          .toList();

      _streamSub = api.streamChat(history).listen(
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

  Future<void> _runAgenticLoop() async {
    final api = ApiService(_settings, activeBaseUrl);
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
    }
  }

  Future<void> cancelStream() async {
    await _streamSub?.cancel();
    _streamSub = null;
    if (_activeConversation != null) {
      final msgs = _activeConversation!.messages;
      if (msgs.isNotEmpty && msgs.last.isStreaming) {
        msgs.last.isStreaming = false;
      }
    }
    _isStreaming = false;
    StreamingKeepAlive.stop();
    notifyListeners();
  }

  Future<void> _persistConversations() =>
      _storage.saveConversations(_conversations);
}
