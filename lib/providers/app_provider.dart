import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/conversation.dart';
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

  // ── Network auto-detection ────────────────────────────────────────────────

  bool _usingAway = false;
  DateTime? _lastNetworkCheck;
  static const _networkCacheDuration = Duration(seconds: 60);

  // ── MCP ───────────────────────────────────────────────────────────────────

  // Single long-lived instance so the MCP session ID is preserved.
  McpService? _mcpService;
  List<McpToolDef> _mcpTools = [];
  bool _fetchingMcpTools = false;
  // Runtime override — lets the user toggle tools on/off without touching settings.
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
  List<McpToolDef> get mcpTools => _mcpTools;
  bool get fetchingMcpTools => _fetchingMcpTools;
  bool get mcpActive => _mcpActive;
  /// True when MCP is configured, tools are loaded, AND the user hasn't toggled it off.
  bool get mcpAvailable => _settings.mcpEnabled && _mcpTools.isNotEmpty && _mcpActive;
  /// Whether MCP is configured at all (ignoring the runtime toggle).
  bool get mcpConfigured => _settings.mcpEnabled && _mcpTools.isNotEmpty;

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
    if (_settings.mcpEnabled && _settings.mcpBaseUrl.isNotEmpty) {
      fetchMcpTools();
    }
  }

  // ── Network auto-detect ───────────────────────────────────────────────────

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

  // ── MCP tools ─────────────────────────────────────────────────────────────

  /// Returns the shared [McpService], creating it if the URL changed.
  McpService _mcp() {
    final url = _settings.mcpBaseUrl;
    if (_mcpService == null || _mcpService!.baseUrl != url) {
      _mcpService = McpService(url);
    }
    return _mcpService!;
  }

  Future<void> fetchMcpTools() async {
    if (!_settings.mcpEnabled || _settings.mcpBaseUrl.isEmpty) {
      _mcpTools = [];
      notifyListeners();
      return;
    }
    _fetchingMcpTools = true;
    _error = null;
    notifyListeners();
    try {
      _mcpTools = await _mcp().listTools();
    } catch (e) {
      _mcpTools = [];
      _error = 'MCP: $e';
    } finally {
      _fetchingMcpTools = false;
      notifyListeners();
    }
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
    if (_settings.mcpEnabled && _settings.mcpBaseUrl.isNotEmpty) {
      fetchMcpTools();
    } else {
      _mcpTools = [];
      notifyListeners();
    }
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

  // ── Agentic loop (with MCP tools) ─────────────────────────────────────────

  Future<void> _runAgenticLoop() async {
    final mcp = _mcp();
    final api = ApiService(_settings, activeBaseUrl);
    const maxIterations = 10;

    // Temporary typing-indicator placeholder shown while waiting for the LLM.
    final loadingMsg = Message(
        role: Role.assistant, content: '', isStreaming: true);
    _activeConversation!.messages.add(loadingMsg);
    _activeConversation!.updatedAt = DateTime.now();
    notifyListeners();

    try {
      for (int i = 0; i < maxIterations; i++) {
        // Build history excluding the loading placeholder.
        final history = _activeConversation!.messages
            .where((m) => m.id != loadingMsg.id)
            .toList();

        final response =
            await api.chatWithTools(history, _mcpTools);

        if (response.hasToolCalls) {
          // Replace the loading indicator with the tool-call message.
          _activeConversation!.messages.remove(loadingMsg);
          _activeConversation!.messages.add(Message(
            role: Role.assistant,
            toolCalls: response.toolCalls,
          ));
          notifyListeners();

          // Execute each tool via MCP and add the result message.
          for (final call in response.toolCalls!) {
            List<McpContent> content;
            try {
              content = await mcp.callTool(call.name, call.arguments);
            } catch (e) {
              content = [McpContent(type: 'text', text: 'Tool error: $e')];
            }
            _activeConversation!.messages.add(Message(
              role: Role.tool,
              content: content.map((c) => c.toApiText()).join('\n'),
              toolCallId: call.id,
              toolName: call.name,
              toolContent: content,
            ));
            notifyListeners();
          }

          // Re-add the loading indicator for the next LLM round.
          _activeConversation!.messages.add(loadingMsg);
          notifyListeners();
        } else {
          // Final text — replace loading indicator with the real response.
          _activeConversation!.messages.remove(loadingMsg);
          _activeConversation!.messages.add(Message(
            role: Role.assistant,
            content: response.content ?? '',
          ));
          notifyListeners();
          break;
        }
      }
    } catch (e) {
      _activeConversation!.messages.remove(loadingMsg);
      _error = e.toString();
      _activeConversation!.messages.add(
        Message(role: Role.assistant, content: '[Error: $e]'),
      );
    } finally {
      // Safety: ensure the loading placeholder is gone.
      _activeConversation!.messages.remove(loadingMsg);
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
