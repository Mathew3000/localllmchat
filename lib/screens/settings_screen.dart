import 'dart:async' show Timer, TimeoutException;
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
// dart:typed_data provided transitively via flutter/services;
import 'package:file_picker/file_picker.dart';
import '../services/backup_crypto.dart';
import '../services/backend_service.dart';
import '../services/debug_logger.dart';
import '../services/sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/settings.dart';
import '../providers/app_provider.dart';
import '../version.dart';
import '../widgets/color_picker.dart';
import '../widgets/friendly.dart';
import 'mcp_servers_screen.dart';
import 'personality_settings_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _baseUrlHomeController;
  late TextEditingController _baseUrlAwayController;
  late TextEditingController _apiKeyController;
  late TextEditingController _modelController;
  late double _temperature;
  late int _maxTokens;
  late int _contextWindowTokens;
  String? _selectedModel;
  bool _apiKeyVisible = false;
  late bool _allowSelfSigned;
  late int _requestTimeoutSeconds;
  int? _globalBgColor;
  int? _defaultUserBubbleColor;
  int? _defaultAssistantBubbleColor;
  int? _highlightColor;

  AppSettings? _lastKnownSettings;
  late AppProvider _provider;

  /// Pending auto-save. Changes are saved shortly after the user stops
  /// editing, and immediately when the screen is closed.
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _provider = context.read<AppProvider>();
    _baseUrlHomeController = TextEditingController();
    _baseUrlAwayController = TextEditingController();
    _apiKeyController = TextEditingController();
    _modelController = TextEditingController();
    _temperature = 0.7;
    _maxTokens = 2048;
    _contextWindowTokens = 32768;
    _allowSelfSigned = false;
    _requestTimeoutSeconds = 300;
    _loadFromSettings(_provider.settings);
    _provider.addListener(_onProviderChanged);

    // Load the model list automatically so the user doesn't have to know
    // about the "Fetch" button.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = _provider.settings;
      final canFetch = s.useBackend
          ? _provider.backendConnected
          : s.baseUrlHome.isNotEmpty;
      if (mounted &&
          canFetch &&
          _provider.availableModels.isEmpty &&
          !_provider.fetchingModels) {
        _provider.fetchModels();
      }
    });
  }

  void _setText(TextEditingController c, String v) {
    if (c.text != v) c.text = v;
  }

  void _loadFromSettings(AppSettings s) {
    _lastKnownSettings = s;
    _setText(_baseUrlHomeController, s.baseUrlHome);
    _setText(_baseUrlAwayController, s.baseUrlAway);
    _setText(_apiKeyController, s.apiKey);
    _setText(_modelController, s.selectedModel);
    _temperature = s.temperature;
    _maxTokens = s.maxTokens;
    _contextWindowTokens = s.contextWindowTokens;
    _selectedModel = s.selectedModel.isEmpty ? null : s.selectedModel;
    _allowSelfSigned = s.allowSelfSigned;
    _requestTimeoutSeconds = s.requestTimeoutSeconds;
    _globalBgColor = s.backgroundColor;
    _defaultUserBubbleColor = s.defaultUserBubbleColor;
    _defaultAssistantBubbleColor = s.defaultAssistantBubbleColor;
    _highlightColor = s.highlightColor;
  }

  void _onProviderChanged() {
    if (!mounted) return;
    // Don't overwrite edits that are still waiting to be saved.
    if (_saveTimer?.isActive ?? false) return;
    final s = _provider.settings;
    if (!identical(s, _lastKnownSettings)) {
      setState(() => _loadFromSettings(s));
    }
  }

  /// Apply a form change and schedule an auto-save.
  void _changed(VoidCallback fn) {
    setState(fn);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), _persist);
  }

  Future<void> _persist() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    // Use copyWith so any fields not managed by this form (personalities,
    // mcpServers, sync tokens, backend credentials, etc.) are preserved.
    final updated = _provider.settings.copyWith(
      baseUrlHome: _baseUrlHomeController.text.trim(),
      baseUrlAway: _baseUrlAwayController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      selectedModel: _selectedModel ?? '',
      temperature: _temperature,
      maxTokens: _maxTokens,
      backgroundColor: _globalBgColor,
      defaultUserBubbleColor: _defaultUserBubbleColor,
      defaultAssistantBubbleColor: _defaultAssistantBubbleColor,
      highlightColor: _highlightColor,
      requestTimeoutSeconds: _requestTimeoutSeconds,
      contextWindowTokens: _contextWindowTokens,
      allowSelfSigned: _allowSelfSigned,
    );
    _lastKnownSettings = updated;
    await _provider.updateSettings(updated);
  }

  @override
  void dispose() {
    _provider.removeListener(_onProviderChanged);
    // Flush unsaved edits (reads the controllers synchronously).
    if (_saveTimer?.isActive ?? false) _persist();
    _baseUrlHomeController.dispose();
    _baseUrlAwayController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  // ── Presets shown to everyday users ──────────────────────────────────────
  static const _creativityPresets = <(String, double)>[
    ('Precise', 0.2),
    ('Balanced', 0.7),
    ('Creative', 1.1),
  ];
  static const _lengthPresets = <(String, int)>[
    ('Short', 1024),
    ('Normal', 4096),
    ('Long', 8192),
    ('Very long', 16384),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Consumer<AppProvider>(
        builder: (context, provider, _) {
          final s = provider.settings;
          final conn = connectionState(provider);
          return ListView(
            padding: EdgeInsets.fromLTRB(
              16, 8, 16,
              16 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            children: [
              _StatusCard(conn: conn),
              const SizedBox(height: 20),

              // ── Everyday chat options ──────────────────────────────────
              const _SectionHeader(title: 'Chat'),
              _SettingsCard(children: [
                _buildModelPicker(provider),
                const Divider(height: 1),
                _PresetChoice<double>(
                  icon: Icons.palette_outlined,
                  title: 'Creativity',
                  subtitle: 'Precise sticks to facts, Creative is more imaginative',
                  options: _creativityPresets,
                  isSelected: (v) => (v - _temperature).abs() < 0.05,
                  onSelected: (v) => _changed(() => _temperature = v),
                ),
                const Divider(height: 1),
                _PresetChoice<int>(
                  icon: Icons.short_text_rounded,
                  title: 'Reply length',
                  subtitle: 'The longest a single answer can be',
                  options: _lengthPresets,
                  isSelected: (v) => v == _maxTokens,
                  onSelected: (v) => _changed(() => _maxTokens = v),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  secondary: const Icon(Icons.calendar_today_outlined),
                  title: const Text("Tell the AI today's date"),
                  subtitle: const Text('Helps with questions like "what day is it?"'),
                  value: s.injectDateTime,
                  onChanged: (v) =>
                      provider.updateSettings(s.copyWith(injectDateTime: v)),
                ),
              ]),
              const SizedBox(height: 12),
              const _PersonalitiesNavTile(),
              const SizedBox(height: 8),
              const _McpNavTile(),
              const SizedBox(height: 8),
              const _FileMcpTile(),
              const SizedBox(height: 20),

              // ── Look & feel ───────────────────────────────────────────
              _ExpandableSection(
                key: const ValueKey('sec-appearance'),
                icon: Icons.color_lens_outlined,
                title: 'Appearance',
                subtitle: 'Colours of the chat and message bubbles',
                children: [
                  _ColorSection(
                    icon: Icons.format_paint_outlined,
                    label: 'Chat background',
                    current: _globalBgColor,
                    onPick: (c) => _changed(() => _globalBgColor = c),
                  ),
                  const Divider(height: 1),
                  _ColorSection(
                    icon: Icons.person_rounded,
                    label: 'Your messages',
                    current: _defaultUserBubbleColor,
                    onPick: (c) => _changed(() => _defaultUserBubbleColor = c),
                  ),
                  const Divider(height: 1),
                  _ColorSection(
                    icon: Icons.auto_awesome_rounded,
                    label: 'AI messages',
                    current: _defaultAssistantBubbleColor,
                    onPick: (c) =>
                        _changed(() => _defaultAssistantBubbleColor = c),
                  ),
                  const Divider(height: 1),
                  _ColorSection(
                    icon: Icons.highlight_rounded,
                    label: 'Highlighted text',
                    current: _highlightColor,
                    onPick: (c) => _changed(() => _highlightColor = c),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Privacy & data ────────────────────────────────────────
              const _SectionHeader(title: 'Privacy & data'),
              const _SecretChatsCard(),
              if (!s.useBackend) ...[
                const SizedBox(height: 8),
                const _SyncCard(),
              ],
              const SizedBox(height: 8),
              const _BackupCard(),
              const SizedBox(height: 20),

              // ── Setup & expert options ────────────────────────────────
              const _SectionHeader(title: 'Setup'),
              _ExpandableSection(
                key: const ValueKey('sec-connection'),
                icon: Icons.dns_outlined,
                title: 'Connection',
                subtitle: 'Where your AI runs and how to reach it',
                initiallyExpanded: conn == ConnState.notSetUp,
                children: [
                  const _BackendCard(),
                  const Divider(height: 1),
                  _buildDirectConnection(s),
                ],
              ),
              const SizedBox(height: 8),
              _ExpandableSection(
                key: const ValueKey('sec-advanced'),
                icon: Icons.tune_rounded,
                title: 'Advanced',
                subtitle: 'Exact values for experienced users',
                children: _buildAdvanced(provider),
              ),
              const SizedBox(height: 8),
              const _ExpandableSection(
                key: ValueKey('sec-debug'),
                icon: Icons.bug_report_outlined,
                title: 'Troubleshooting',
                subtitle: 'Record a log file to help find problems',
                children: [_DebugCard()],
              ),
              const SizedBox(height: 32),
              Center(
                child: Text(
                  'LoomChat $kAppVersion · changes are saved automatically',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withValues(alpha: 0.6),
                      ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }

  Widget _buildModelPicker(AppProvider provider) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final models = provider.availableModels;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.memory_rounded, color: cs.onSurfaceVariant),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('AI model', style: theme.textTheme.bodyLarge),
                    if (models.isEmpty)
                      TextField(
                        controller: _modelController,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: provider.fetchingModels
                              ? 'Loading models…'
                              : 'Type a model name or tap refresh',
                        ),
                        onChanged: (v) => _changed(() =>
                            _selectedModel = v.trim().isEmpty ? null : v.trim()),
                      )
                    else
                      DropdownButton<String>(
                        isExpanded: true,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        value: models.contains(_selectedModel)
                            ? _selectedModel
                            : null,
                        hint: const Text('Choose a model'),
                        items: models
                            .map((m) => DropdownMenuItem(
                                  value: m,
                                  child: Text(friendlyModelName(m),
                                      overflow: TextOverflow.ellipsis),
                                ))
                            .toList(),
                        onChanged: (v) => _changed(() => _selectedModel = v),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Reload model list',
                onPressed: provider.fetchingModels
                    ? null
                    : () async {
                        await _persist();
                        provider.fetchModels();
                      },
                icon: provider.fetchingModels
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          if (provider.error != null)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 6, right: 8),
              child: Text(
                friendlyError(provider.error!).message,
                style: TextStyle(color: cs.error, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDirectConnection(AppSettings s) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Text(
            s.useBackend ? 'AI server (used by your LoomChat server)' : 'AI server',
            style: theme.textTheme.titleSmall,
          ),
        ),
        _LabeledField(
          label: 'AI server address',
          child: TextField(
            controller: _baseUrlHomeController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              hintText: 'http://192.168.1.100:5000/v1',
              helperText: 'The address of the computer running your AI model',
            ),
            onChanged: (_) => _changed(() {}),
          ),
        ),
        if (!s.useBackend)
          _LabeledField(
            label: 'Address when away from home (optional)',
            child: TextField(
              controller: _baseUrlAwayController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'http://100.x.x.x:5000/v1',
                helperText: 'Used automatically when the home address cannot be reached (e.g. via VPN)',
              ),
              onChanged: (_) => _changed(() {}),
            ),
          ),
        _LabeledField(
          label: 'API key (optional)',
          child: TextField(
            controller: _apiKeyController,
            obscureText: !_apiKeyVisible,
            decoration: InputDecoration(
              hintText: 'Only needed if your AI server asks for one',
              suffixIcon: IconButton(
                tooltip: _apiKeyVisible ? 'Hide' : 'Show',
                icon: Icon(_apiKeyVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
                onPressed: () =>
                    setState(() => _apiKeyVisible = !_apiKeyVisible),
              ),
            ),
            onChanged: (_) => _changed(() {}),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  List<Widget> _buildAdvanced(AppProvider provider) {
    final s = provider.settings;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tooLong = _maxTokens >= _contextWindowTokens;
    return [
      _SliderField(
        label: 'Temperature',
        value: _temperature.clamp(0.0, 2.0),
        min: 0,
        max: 2,
        displayValue: _temperature.toStringAsFixed(2),
        onChanged: (v) => _changed(() => _temperature = v),
      ),
      const Divider(height: 1),
      _MaxTokensField(
        value: _maxTokens,
        onChanged: (v) => _changed(() => _maxTokens = v),
      ),
      if (tooLong || _maxTokens > 32768)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: cs.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tooLong
                      ? 'Max tokens is as large as the whole context window. '
                          'Many servers reject or crash on this — use 4096–16384.'
                      : 'Very large values make some servers drop the connection. '
                          '4096–16384 is usually plenty.',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
                ),
              ),
            ],
          ),
        ),
      const Divider(height: 1),
      _ContextWindowField(
        value: _contextWindowTokens,
        onChanged: (v) => _changed(() => _contextWindowTokens = v),
      ),
      const Divider(height: 1),
      _TimeoutField(
        value: _requestTimeoutSeconds,
        onChanged: (v) => _changed(() => _requestTimeoutSeconds = v),
      ),
      const Divider(height: 1),
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        title: const Text('Preserve thinking history'),
        subtitle: const Text(
            'Send the model its earlier reasoning again (Qwen3, DeepSeek-R1)'),
        value: s.preserveThinking,
        onChanged: (v) =>
            provider.updateSettings(s.copyWith(preserveThinking: v)),
      ),
      const Divider(height: 1),
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        title: const Text('Allow self-signed certificate (AI server)'),
        subtitle: const Text(
            'Skip TLS certificate checks for the AI server. Private networks only.'),
        value: _allowSelfSigned,
        onChanged: (v) => _changed(() => _allowSelfSigned = v),
      ),
    ];
  }
}

// ── Status card at the top of settings ───────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final ConnState conn;
  const _StatusCard({required this.conn});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final p = context.watch<AppProvider>();
    final s = p.settings;
    final good = conn == ConnState.ok || conn == ConnState.away;
    final model = friendlyModelName(s.selectedModel);

    final String detail;
    if (conn == ConnState.notSetUp) {
      detail = 'Open "Connection" below to connect LoomChat to your AI.';
    } else if (conn == ConnState.offline) {
      detail = p.backendConnectError != null
          ? friendlyError(p.backendConnectError!).message
          : 'Check that the server is running and you are online.';
    } else {
      detail = model.isEmpty ? 'No AI model chosen yet' : 'Using $model';
    }

    final bg = good ? cs.primaryContainer : cs.errorContainer;
    final fg = good ? cs.onPrimaryContainer : cs.onErrorContainer;

    return Card(
      margin: EdgeInsets.zero,
      color: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              good ? Icons.check_circle_rounded : Icons.error_outline_rounded,
              color: fg,
              size: 32,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connectionTitle(conn, backend: s.useBackend),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: fg, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(detail,
                      style: theme.textTheme.bodySmall?.copyWith(color: fg)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Row of preset chips ("Short / Normal / Long") ────────────────────────────

class _PresetChoice<T> extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<(String, T)> options;
  final bool Function(T) isSelected;
  final ValueChanged<T> onSelected;

  const _PresetChoice({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.options,
    required this.isSelected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final anySelected = options.any((o) => isSelected(o.$2));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: cs.onSurfaceVariant),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyLarge),
                Text(subtitle,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final o in options)
                      ChoiceChip(
                        label: Text(o.$1),
                        selected: isSelected(o.$2),
                        onSelected: (_) => onSelected(o.$2),
                      ),
                    if (!anySelected)
                      Chip(
                        label: const Text('Custom'),
                        avatar: const Icon(Icons.tune_rounded, size: 16),
                        backgroundColor: cs.secondaryContainer,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Secret chats settings card ────────────────────────────────────────────────

class _SecretChatsCard extends StatelessWidget {
  const _SecretChatsCard();

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (_, provider, __) {
        final hasPassword = provider.hasSecretPassword;
        final cs = Theme.of(context).colorScheme;

        return Card(
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status row
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Icon(
                      hasPassword
                          ? Icons.lock_outline_rounded
                          : Icons.lock_open_rounded,
                      color: hasPassword ? cs.primary : cs.onSurfaceVariant,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasPassword ? 'Password protected' : 'Not protected',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: hasPassword
                                        ? cs.primary
                                        : cs.onSurface),
                          ),
                          Text(
                            hasPassword
                                ? 'Secret chats are hidden until unlocked'
                                : 'Set a password to enable secret chats',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Action buttons
              Padding(
                padding: const EdgeInsets.all(12),
                child: hasPassword
                    ? Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () =>
                                  _showChangePasswordDialog(context, provider),
                              icon: const Icon(Icons.edit_outlined, size: 16),
                              label: const Text('Change'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () =>
                                  _showRemovePasswordDialog(context, provider),
                              icon: const Icon(Icons.no_encryption_outlined,
                                  size: 16),
                              label: const Text('Remove'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: cs.error,
                                side: BorderSide(color: cs.error),
                              ),
                            ),
                          ),
                        ],
                      )
                    : FilledButton.icon(
                        onPressed: () =>
                            _showSetPasswordDialog(context, provider),
                        icon: const Icon(Icons.lock_outlined, size: 16),
                        label: const Text('Set password'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(double.infinity, 44),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showSetPasswordDialog(
      BuildContext context, AppProvider provider) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => const _NewPasswordDialog(),
    );
    if (result != null && result.isNotEmpty) {
      await provider.setSecretPassword(result);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Secret chat password set'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _showChangePasswordDialog(
      BuildContext context, AppProvider provider) async {
    final result = await showDialog<_PasswordChange>(
      context: context,
      builder: (_) => const _ChangePasswordDialog(),
    );
    if (result != null) {
      final ok =
          await provider.changeSecretPassword(result.current, result.next);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok ? 'Password updated' : 'Current password is wrong'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  Future<void> _showRemovePasswordDialog(
      BuildContext context, AppProvider provider) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _ConfirmPasswordDialog(
        title: 'Remove protection',
        body:
            'All secret chats will become visible to anyone. Enter your current password to confirm.',
        actionLabel: 'Remove',
        destructive: true,
      ),
    );
    if (password != null) {
      final ok = await provider.removeSecretPassword(password);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(ok ? 'Password removed' : 'Incorrect password'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }
}

// ── Password dialogs ──────────────────────────────────────────────────────────

class _NewPasswordDialog extends StatefulWidget {
  const _NewPasswordDialog();

  @override
  State<_NewPasswordDialog> createState() => _NewPasswordDialogState();
}

class _NewPasswordDialogState extends State<_NewPasswordDialog> {
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _pw1.dispose();
    _pw2.dispose();
    super.dispose();
  }

  void _submit() {
    if (_pw1.text.isEmpty) {
      setState(() => _error = 'Password cannot be empty');
      return;
    }
    if (_pw1.text != _pw2.text) {
      setState(() => _error = 'Passwords do not match');
      return;
    }
    Navigator.pop(context, _pw1.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set secret chat password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PwField(
              controller: _pw1,
              label: 'New password',
              obscure: _obscure,
              onToggle: () => setState(() => _obscure = !_obscure)),
          const SizedBox(height: 12),
          _PwField(
              controller: _pw2,
              label: 'Confirm password',
              obscure: _obscure,
              onToggle: () => setState(() => _obscure = !_obscure),
              onSubmit: _submit),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12)),
          ],
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Set')),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────

class _PasswordChange {
  final String current;
  final String next;
  _PasswordChange(this.current, this.next);
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _pw1.dispose();
    _pw2.dispose();
    super.dispose();
  }

  void _submit() {
    if (_current.text.isEmpty || _pw1.text.isEmpty) {
      setState(() => _error = 'All fields are required');
      return;
    }
    if (_pw1.text != _pw2.text) {
      setState(() => _error = 'New passwords do not match');
      return;
    }
    Navigator.pop(context, _PasswordChange(_current.text, _pw1.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PwField(
              controller: _current,
              label: 'Current password',
              obscure: _obscure,
              onToggle: () => setState(() => _obscure = !_obscure)),
          const SizedBox(height: 12),
          _PwField(
              controller: _pw1,
              label: 'New password',
              obscure: _obscure,
              onToggle: () => setState(() => _obscure = !_obscure)),
          const SizedBox(height: 12),
          _PwField(
              controller: _pw2,
              label: 'Confirm new password',
              obscure: _obscure,
              onToggle: () => setState(() => _obscure = !_obscure),
              onSubmit: _submit),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12)),
          ],
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Update')),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────

class _ConfirmPasswordDialog extends StatefulWidget {
  final String title;
  final String body;
  final String actionLabel;
  final bool destructive;

  const _ConfirmPasswordDialog({
    required this.title,
    required this.body,
    required this.actionLabel,
    this.destructive = false,
  });

  @override
  State<_ConfirmPasswordDialog> createState() => _ConfirmPasswordDialogState();
}

class _ConfirmPasswordDialogState extends State<_ConfirmPasswordDialog> {
  final _pw = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.body,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          _PwField(
              controller: _pw,
              label: 'Password',
              obscure: _obscure,
              onToggle: () => setState(() => _obscure = !_obscure),
              onSubmit: () => Navigator.pop(context, _pw.text)),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _pw.text),
          style: widget.destructive
              ? FilledButton.styleFrom(backgroundColor: cs.error)
              : null,
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

// ── Shared password text field ────────────────────────────────────────────────

class _PwField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool obscure;
  final VoidCallback onToggle;
  final VoidCallback? onSubmit;

  const _PwField({
    required this.controller,
    required this.label,
    required this.obscure,
    required this.onToggle,
    this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      autofocus: true,
      textInputAction:
          onSubmit != null ? TextInputAction.done : TextInputAction.next,
      onSubmitted: onSubmit != null ? (_) => onSubmit!() : null,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon:
              Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
          onPressed: onToggle,
        ),
      ),
    );
  }
}

// ── Shared section helpers ────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _ExpandableSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final bool initiallyExpanded;
  const _ExpandableSection({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
    this.subtitle,
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Remove ExpansionTile's own top/bottom divider lines.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(icon, color: cs.primary),
          title: Text(title),
          subtitle: subtitle == null
              ? null
              : Text(subtitle!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant)),
          initiallyExpanded: initiallyExpanded,
          childrenPadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Divider(height: 1, color: cs.outlineVariant),
            ...children,
          ],
        ),
      ),
    );
  }
}

// ── Appearance colour section ─────────────────────────────────────────────────

class _ColorSection extends StatelessWidget {
  final IconData icon;
  final String label;
  final int? current;
  final ValueChanged<int?> onPick;
  const _ColorSection({
    required this.icon,
    required this.label,
    required this.current,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(label, style: theme.textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: 12),
          ColorGrid(current: current, onPick: onPick),
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;
  const _LabeledField({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          child,
        ],
      ),
    );
  }
}

class _SliderField extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final String displayValue;
  final ValueChanged<double> onChanged;

  const _SliderField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.displayValue,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,

              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              displayValue,
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

// Logarithmic slider mapping so small values get as much room as large ones.
double _logToSlider(int v, int min, int max) {
  final c = v.clamp(min, max);
  return (math.log(c) - math.log(min)) / (math.log(max) - math.log(min));
}

int _logFromSlider(double s, int min, int max) {
  final raw = math.exp(math.log(min) + s * (math.log(max) - math.log(min)));
  // Snap to multiples of 256 (or 128 at the very low end) for tidy numbers.
  final step = raw < 1024 ? 128 : 256;
  return ((raw / step).round() * step).clamp(min, max);
}

// ── Max tokens: slider + editable text field ──────────────────────────────────

class _MaxTokensField extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _MaxTokensField({required this.value, required this.onChanged});

  @override
  State<_MaxTokensField> createState() => _MaxTokensFieldState();
}

class _MaxTokensFieldState extends State<_MaxTokensField> {
  static const int _min = 128;
  static const int _max = 262144;

  late final TextEditingController _textController;

  // Slider uses a log scale so the low end isn't squished into nothing.
  // We map the slider's 0‥1 range → 128‥262144 logarithmically.
  static double _toSlider(int v) => _logToSlider(v, _min, _max);
  static int _fromSlider(double s) => _logFromSlider(s, _min, _max);

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.value.toString());
  }

  @override
  void didUpdateWidget(_MaxTokensField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      // Keep the text in sync when parent rebuilds (e.g. slider moved).
      final cursor = _textController.selection;
      _textController.text = widget.value.toString();
      _textController.selection = cursor;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _applyText(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return;
    widget.onChanged(parsed.clamp(_min, _max));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Label row + text input
          Row(
            children: [
              Expanded(
                child: Text('Max tokens (reply length)',
                    style: theme.textTheme.bodyMedium),
              ),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _textController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontFeatures: const []),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    suffix: Text('  ',
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant)),
                  ),
                  onChanged: _applyText,
                  onSubmitted: _applyText,
                  onTapOutside: (_) =>
                      _applyText(_textController.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // Slider
          Slider(
            value: _toSlider(widget.value),
            min: 0,
            max: 1,
            onChanged: (s) {
              final v = _fromSlider(s);
              widget.onChanged(v);
            },
          ),
          // Range hint
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('$_min',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              Text('$_max',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Context window size: log-scale slider + text field ───────────────────────

class _ContextWindowField extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _ContextWindowField({required this.value, required this.onChanged});

  @override
  State<_ContextWindowField> createState() => _ContextWindowFieldState();
}

class _ContextWindowFieldState extends State<_ContextWindowField> {
  static const int _min = 1024;
  static const int _max = 262144;

  late final TextEditingController _textController;

  static double _toSlider(int v) => _logToSlider(v, _min, _max);
  static int _fromSlider(double s) => _logFromSlider(s, _min, _max);

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.value.toString());
  }

  @override
  void didUpdateWidget(_ContextWindowField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      final cursor = _textController.selection;
      _textController.text = widget.value.toString();
      _textController.selection = cursor;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _applyText(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return;
    widget.onChanged(parsed.clamp(_min, _max));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Context window (memory)', style: theme.textTheme.bodyMedium)),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _textController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                  onSubmitted: _applyText,
                  onEditingComplete: () => _applyText(_textController.text),
                ),
              ),
            ],
          ),
          Slider(
            value: _toSlider(widget.value),
            onChanged: (s) {
              final v = _fromSlider(s);
              widget.onChanged(v);
            },
          ),
          Text(
            'Model\'s total context window in tokens. Used for the context usage indicator.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Request timeout: editable seconds field ───────────────────────────────────

class _TimeoutField extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _TimeoutField({required this.value, required this.onChanged});

  @override
  State<_TimeoutField> createState() => _TimeoutFieldState();
}

class _TimeoutFieldState extends State<_TimeoutField> {
  static const int _min = 10;
  static const int _max = 3600; // 1 hour

  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.value.toString());
  }

  @override
  void didUpdateWidget(_TimeoutField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      final cursor = _textController.selection;
      _textController.text = widget.value.toString();
      _textController.selection = cursor;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _apply(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return;
    widget.onChanged(parsed.clamp(_min, _max));
  }

  String _label(int s) {
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    final rem = s % 60;
    return rem == 0 ? '${m}m' : '${m}m ${rem}s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Wait time for a reply',
                    style: theme.textTheme.bodyMedium),
              ),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _textController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6)),
                    suffix: Text(' s',
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
                  ),
                  onChanged: _apply,
                  onSubmitted: _apply,
                  onTapOutside: (_) => _apply(_textController.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // Quick-pick chips
          Wrap(
            spacing: 6,
            children: [30, 60, 120, 300, 600, 1800].map((s) {
              final selected = widget.value == s;
              return ChoiceChip(
                label: Text(_label(s)),
                selected: selected,
                onSelected: (_) => widget.onChanged(s),
                labelStyle: theme.textTheme.labelSmall?.copyWith(
                  color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant,
                ),
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
          const SizedBox(height: 2),
          Text(
            '${_min}s – ${_label(_max)} • affects streaming connect + tool calls',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ── Sync card ─────────────────────────────────────────────────────────────────

class _SyncCard extends StatelessWidget {
  const _SyncCard();

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (_, provider, __) {
        final s = provider.settings;
        final configured = provider.syncConfigured;
        final ready = provider.syncReady;
        final status = provider.syncStatus;

        return Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              // Status / login tile
              ListTile(
                leading: Icon(
                  ready
                      ? Icons.cloud_done_outlined
                      : configured
                          ? Icons.cloud_off_outlined
                          : Icons.cloud_outlined,
                  color: ready
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(configured
                    ? 'Sync: ${s.syncUsername}'
                    : 'Sync: not configured'),
                subtitle: Text(
                  ready
                      ? (s.syncLastAt.isNotEmpty
                          ? 'Last synced ${_formatSyncTime(s.syncLastAt)}'
                          : 'Ready — tap Sync Now')
                      : configured
                          ? 'Key not loaded — log in to sync'
                          : 'Set up a sync server in Setup',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: status == SyncStatus.syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
              if (provider.syncError != null) ...[
                const Divider(height: 1),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    provider.syncError!,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
              // ── Auto-sync controls (only when logged in) ─────────────────
              if (ready) ...[
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.sync_outlined),
                  title: const Text('Auto-sync'),
                  subtitle: Text(
                    s.autoSyncEnabled
                        ? 'Every ${_formatInterval(s.autoSyncIntervalMinutes)}'
                        : 'Sync automatically in the background',
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: s.autoSyncEnabled,
                  onChanged: (v) => provider.saveAutoSyncSettings(
                    enabled: v,
                    intervalMinutes: s.autoSyncIntervalMinutes,
                  ),
                ),
                if (s.autoSyncEnabled) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Interval',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [5, 10, 15, 30, 60, 120].map((mins) {
                            final selected =
                                s.autoSyncIntervalMinutes == mins;
                            return ChoiceChip(
                              label: Text(_formatInterval(mins)),
                              selected: selected,
                              onSelected: (_) =>
                                  provider.saveAutoSyncSettings(
                                enabled: true,
                                intervalMinutes: mins,
                              ),
                              visualDensity: VisualDensity.compact,
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
              const Divider(height: 1),
              // Action row
              OverflowBar(
                alignment: MainAxisAlignment.end,
                children: [
                  if (configured)
                    TextButton(
                      onPressed: () => _confirmLogout(context, provider),
                      child: const Text('Log out'),
                    ),
                  if (ready)
                    FilledButton.tonal(
                      onPressed: status == SyncStatus.syncing
                          ? null
                          : () => provider.syncNow(),
                      child: const Text('Sync Now'),
                    ),
                  if (!configured)
                    FilledButton.tonal(
                      onPressed: () => _showSetupDialog(context, provider),
                      child: const Text('Setup'),
                    )
                  else if (!ready)
                    FilledButton.tonal(
                      onPressed: () =>
                          _showLoginDialog(context, provider, isSetup: false),
                      child: const Text('Unlock'),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatInterval(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  String _formatSyncTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return '${diff.inDays}d ago';
    } catch (_) {
      return '';
    }
  }

  Future<void> _showSetupDialog(
      BuildContext context, AppProvider provider) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _SyncSetupDialog(provider: provider),
    );
  }

  Future<void> _showLoginDialog(BuildContext context, AppProvider provider,
      {required bool isSetup}) async {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _SyncSetupDialog(provider: provider, loginOnly: !isSetup),
    );
  }

  Future<void> _confirmLogout(
      BuildContext context, AppProvider provider) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Log out of sync?'),
        content: const Text(
            'Your local chats are unaffected. You can log back in at any time.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Log out')),
        ],
      ),
    );
    if (ok == true) await provider.syncLogout();
  }
}

// ── Sync setup / login dialog ─────────────────────────────────────────────────

class _SyncSetupDialog extends StatefulWidget {
  final AppProvider provider;
  /// True when the user is already configured and just needs to re-enter their
  /// password to load the encryption key for this session.
  final bool loginOnly;

  const _SyncSetupDialog({required this.provider, this.loginOnly = false});

  @override
  State<_SyncSetupDialog> createState() => _SyncSetupDialogState();
}

class _SyncSetupDialogState extends State<_SyncSetupDialog> {
  final _serverCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _isRegister = false;
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final s = widget.provider.settings;
    if (widget.loginOnly) {
      _serverCtrl.text = s.syncUrl;
      _userCtrl.text = s.syncUsername;
    }
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _serverCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;

    if ((!widget.loginOnly && url.isEmpty) || user.isEmpty || pass.isEmpty) {
      setState(() => _error = 'All fields are required.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (_isRegister) {
        await widget.provider.syncRegister(url, user, pass);
      } else {
        await widget.provider.syncLogin(
          widget.loginOnly ? widget.provider.settings.syncUrl : url,
          user,
          pass,
        );
      }
      if (mounted) Navigator.pop(context);
      // Kick off an initial sync in the background.
      widget.provider.syncNow();
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.loginOnly
          ? 'Unlock sync'
          : _isRegister
              ? 'Create sync account'
              : 'Log in to sync'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.loginOnly) ...[
              TextField(
                controller: _serverCtrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'http://192.168.1.10:8080',
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _userCtrl,
              decoration: const InputDecoration(labelText: 'Username'),
              enabled: !widget.loginOnly,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passCtrl,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Password',
                helperText: 'Derives the encryption key — not stored anywhere.',
                helperMaxLines: 2,
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12)),
            ],
            if (!widget.loginOnly) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('No account yet?'),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () =>
                            setState(() => _isRegister = !_isRegister),
                    child: Text(_isRegister ? 'Log in instead' : 'Register'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(widget.loginOnly
                  ? 'Unlock'
                  : _isRegister
                      ? 'Register'
                      : 'Log in'),
        ),
      ],
    );
  }
}

// ── Backup & Restore card ─────────────────────────────────────────────────────

class _BackupCard extends StatelessWidget {
  const _BackupCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.upload_outlined),
            title: const Text('Export backup'),
            subtitle: const Text('Save all chats & settings to a file'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _export(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Import backup'),
            subtitle: const Text('Restore from a previously exported file'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _import(context),
          ),
        ],
      ),
    );
  }

  // ── Export ──────────────────────────────────────────────────────────────────

  Future<void> _export(BuildContext context) async {
    final provider = context.read<AppProvider>();
    final plainJson = provider.buildBackupJson();

    // If a secret-chat password is set, require it to encrypt the backup.
    String outputJson;
    if (provider.hasSecretPassword) {
      final password = await showDialog<String>(
        context: context,
        builder: (_) => const _PasswordPromptDialog(
          title: 'Encrypt backup',
          body:
              'Enter your secret chat password. The backup will be encrypted '
              'with AES-256-GCM so secret chats stay private.',
          actionLabel: 'Encrypt & save',
        ),
      );
      if (password == null || !context.mounted) return; // cancelled

      if (!provider.verifySecretPassword(password)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Wrong password — backup not saved'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      // Derive key + encrypt — show spinner while PBKDF2 runs.
      outputJson = await _withSpinner(
        context,
        'Encrypting…',
        () => BackupCrypto.encrypt(plainJson, password),
      );
      if (!context.mounted) return;
    } else {
      outputJson = plainJson;
    }

    // Write to user-chosen location.
    final now = DateTime.now();
    final stamp =
        '${now.year}${_p(now.month)}${_p(now.day)}_${_p(now.hour)}${_p(now.minute)}${_p(now.second)}';
    final fileBytes = Uint8List.fromList(utf8.encode(outputJson));
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save LoomChat backup',
        fileName: 'localllmchat_$stamp.json',
        // bytes is used on Web; on desktop we write the file manually below.
        bytes: fileBytes,
      );
      if (!context.mounted) return;
      if (path != null) {
        // On desktop platforms the file picker only returns the chosen path —
        // it does NOT write anything. Write the bytes ourselves.
        await File(path).writeAsBytes(fileBytes, flush: true);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Backup saved'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export failed: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ── Import ──────────────────────────────────────────────────────────────────

  Future<void> _import(BuildContext context) async {
    // 1. Pick the file.
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open file picker: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null) return;

    final rawJson = utf8.decode(bytes);

    // 2. Decrypt if needed.
    String plainJson;
    if (BackupCrypto.isEncrypted(rawJson)) {
      if (!context.mounted) return;
      final password = await showDialog<String>(
        context: context,
        builder: (_) => const _PasswordPromptDialog(
          title: 'Encrypted backup',
          body: 'This backup is encrypted. Enter the password that was used '
              'when the backup was created.',
          actionLabel: 'Decrypt',
        ),
      );
      if (password == null || !context.mounted) return;

      try {
        plainJson = await _withSpinner(
          context,
          'Decrypting…',
          () => BackupCrypto.decrypt(rawJson, password),
        );
      } on ArgumentError {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Wrong password — could not decrypt backup'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Decryption failed: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      if (!context.mounted) return;
    } else {
      plainJson = rawJson;
    }

    // 3. Validate & count conversations.
    int convCount;
    try {
      final data = jsonDecode(plainJson) as Map<String, dynamic>;
      convCount = (data['conversations'] as List<dynamic>).length;
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Not a valid LoomChat backup file'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (!context.mounted) return;

    // 4. Confirm.
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import backup?'),
        content: Text(
          'This will replace all current conversations and settings with '
          '$convCount conversation${convCount == 1 ? '' : 's'} from the backup.\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: cs.error,
              foregroundColor: cs.onError,
            ),
            child: const Text('Import & overwrite'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    // 5. Apply.
    final provider = context.read<AppProvider>();
    final error = await provider.applyBackupJson(plainJson);
    if (!context.mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), behavior: SnackBarBehavior.floating),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '$convCount conversation${convCount == 1 ? '' : 's'} imported'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.pop(context);
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// Shows a non-dismissible spinner dialog while [work] runs, then pops it.
  Future<T> _withSpinner<T>(
    BuildContext context,
    String label,
    Future<T> Function() work,
  ) async {
    // Kick off both concurrently; the dialog outlasts the work only when work
    // is faster than the first frame render — harmless because we pop anyway.
    T? result;
    Object? error;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5)),
              const SizedBox(width: 16),
              Text(label),
            ],
          ),
        ),
      ),
    );
    try {
      result = await work();
    } catch (e) {
      error = e;
    }
    if (context.mounted) Navigator.pop(context);
    if (error != null) throw error;
    return result as T;
  }

  String _p(int n) => n.toString().padLeft(2, '0');
}

// ── Debug card ────────────────────────────────────────────────────────────────

class _DebugCard extends StatefulWidget {
  const _DebugCard();

  @override
  State<_DebugCard> createState() => _DebugCardState();
}

class _DebugCardState extends State<_DebugCard> {
  bool _busy = false;

  Future<String?> _pickFolder() async {
    if (Platform.isAndroid) {
      // On Android let file_picker resolve a writable directory via SAF.
      return FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select debug log folder',
      );
    } else {
      return FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select debug log folder',
      );
    }
  }

  Future<void> _toggle(AppProvider provider, bool enabled) async {
    if (enabled) {
      final current = provider.settings.debugLogPath;
      final path = current.isNotEmpty ? current : await _pickFolder();
      if (path == null || path.isEmpty) return; // user cancelled
      await _apply(provider, enabled: true, path: path);
    } else {
      await _apply(provider, enabled: false, path: provider.settings.debugLogPath);
    }
  }

  Future<void> _changeFolder(AppProvider provider) async {
    final path = await _pickFolder();
    if (path == null || path.isEmpty) return;
    await _apply(provider, enabled: provider.settings.debugLogging, path: path);
  }

  Future<void> _apply(AppProvider provider,
      {required bool enabled, required String path}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await provider.saveDebugSettings(enabled: enabled, path: path);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, _) {
        final theme = Theme.of(context);
        final cs = theme.colorScheme;
        final s = provider.settings;
        final logFile = DebugLogger.instance.currentFile;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Warning banner ──────────────────────────────────────────────
            if (s.debugLogging)
              Container(
                margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.errorContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 16, color: cs.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Logs contain all message content, API keys, MCP '
                        'auth headers, and tokens in plain text. '
                        'Disable when not debugging.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),

            // ── Toggle ──────────────────────────────────────────────────────
            SwitchListTile(
              title: const Text('Debug logging'),
              subtitle: Text(
                'Write raw HTTP traffic to a log file',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              value: s.debugLogging,
              onChanged: _busy ? null : (v) => _toggle(provider, v),
            ),

            // ── Folder + active file (only when enabled) ─────────────────────
            if (s.debugLogging) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Folder row
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Log folder',
                                style: theme.textTheme.labelSmall
                                    ?.copyWith(color: cs.onSurfaceVariant),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                s.debugLogPath.isEmpty ? '—' : s.debugLogPath,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontFamily: 'monospace',
                                  color: s.debugLogPath.isEmpty
                                      ? cs.error
                                      : cs.onSurface,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed:
                              _busy ? null : () => _changeFolder(provider),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          child: const Text('Change'),
                        ),
                      ],
                    ),

                    // Active log file
                    if (logFile != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(Icons.fiber_manual_record_rounded,
                              size: 8, color: cs.primary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              logFile,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: cs.primary,
                                fontFamily: 'monospace',
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

// ── Password prompt dialog ────────────────────────────────────────────────────

class _PasswordPromptDialog extends StatefulWidget {
  final String title;
  final String body;
  final String actionLabel;

  const _PasswordPromptDialog({
    required this.title,
    required this.body,
    required this.actionLabel,
  });

  @override
  State<_PasswordPromptDialog> createState() => _PasswordPromptDialogState();
}

class _PasswordPromptDialogState extends State<_PasswordPromptDialog> {
  final _ctrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.body, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            obscureText: _obscure,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => Navigator.pop(context, _ctrl.text),
            decoration: InputDecoration(
              labelText: 'Password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          style: FilledButton.styleFrom(backgroundColor: cs.primary),
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

// ── File MCP toggle tile ──────────────────────────────────────────────────────

class _FileMcpTile extends StatelessWidget {
  const _FileMcpTile();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Consumer<AppProvider>(
      builder: (_, provider, __) {
        final enabled = provider.settings.fileMcpEnabled;
        return Card(
          margin: EdgeInsets.zero,
          child: SwitchListTile.adaptive(
            secondary: Icon(
              Icons.folder_open_outlined,
              color: enabled ? cs.tertiary : cs.onSurfaceVariant,
            ),
            title: const Text('Let the AI read a folder'),
            subtitle: Text(
              enabled
                  ? 'A folder button appears next to the message box. The AI can only see the folder you pick.'
                  : 'Adds a folder button next to the message box so the AI can look at your files.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            value: enabled,
            onChanged: (v) {
              provider.updateSettings(
                  provider.settings.copyWith(fileMcpEnabled: v));
              // Clear any active folder when the feature is disabled.
              if (!v) provider.setFileMcpFolder(null);
            },
          ),
        );
      },
    );
  }
}

// ── Personalities nav tile ────────────────────────────────────────────────────

class _PersonalitiesNavTile extends StatelessWidget {
  const _PersonalitiesNavTile();

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (_, provider, __) {
        final count = provider.settings.personalities.length;
        final defaultId = provider.settings.defaultPersonalityId;
        final defaultName = provider.settings.personalities
            .where((p) => p.id == defaultId)
            .map((p) => p.name)
            .firstOrNull;

        final subtitle = count == 0
            ? 'No personalities'
            : '$count personalit${count == 1 ? 'y' : 'ies'}${defaultName != null ? ' · default: $defaultName' : ''}';

        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: Icon(
              Icons.person_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: const Text('Personalities'),
            subtitle: Text('Assistants with their own instructions and tools · $subtitle'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const PersonalitySettingsScreen()),
            ),
          ),
        );
      },
    );
  }
}

// ── MCP nav tile — navigates to the dedicated McpServersScreen ────────────────

class _McpNavTile extends StatelessWidget {
  const _McpNavTile();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Consumer<AppProvider>(
      builder: (_, provider, __) {
        final serverCount = provider.settings.mcpServers.length;
        final toolCount = provider.mcpTools.length;
        final loading = provider.fetchingMcpTools;

        final names = provider.settings.mcpServers
            .where((s) => s.enabled)
            .map((s) => s.name)
            .toList();
        String subtitle;
        if (serverCount == 0) {
          subtitle = 'Give the AI extra abilities, like web search';
        } else if (loading) {
          subtitle = 'Loading…';
        } else if (names.isEmpty) {
          subtitle = 'All tools are switched off';
        } else {
          final shown = names.take(3).join(', ');
          subtitle = names.length > 3
              ? '$shown and ${names.length - 3} more'
              : shown;
        }

        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: Icon(
              Icons.extension_outlined,
              color: toolCount > 0 ? cs.primary : cs.onSurfaceVariant,
            ),
            title: const Text('Tools'),
            subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: loading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.primary,
                    ),
                  )
                : const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const McpServersScreen()),
            ),
          ),
        );
      },
    );
  }
}

// ── Backend card ──────────────────────────────────────────────────────────────

class _BackendCard extends StatefulWidget {
  const _BackendCard();

  @override
  State<_BackendCard> createState() => _BackendCardState();
}

class _BackendCardState extends State<_BackendCard> {
  final _urlCtrl = TextEditingController();
  final _awayUrlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _passwordVisible = false;
  bool _busy = false;
  String? _error;

  // 2FA management state (only relevant when logged in)
  bool? _totpEnabled; // null = not yet fetched
  bool _totp2faFetching = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppProvider>().settings;
    _urlCtrl.text = s.backendUrl;
    _awayUrlCtrl.text = s.backendAwayUrl;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _awayUrlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _saveAwayUrl() {
    context.read<AppProvider>().setBackendAwayUrl(_awayUrlCtrl.text.trim());
  }

  Future<void> _fetchTotpStatus() async {
    final svc = context.read<AppProvider>().backendService;
    if (svc == null) return;
    setState(() => _totp2faFetching = true);
    try {
      final enabled = await svc.get2faStatus();
      if (mounted) setState(() => _totpEnabled = enabled);
    } catch (_) {
      // silently ignore — 2FA section is non-critical
    } finally {
      if (mounted) setState(() => _totp2faFetching = false);
    }
  }

  /// Shows the "Set up 2FA" dialog with QR code + confirmation code entry.
  Future<void> _showSetup2faDialog() async {
    final svc = context.read<AppProvider>().backendService;
    if (svc == null) return;

    // Step 1: Request a new TOTP secret from the backend.
    TotpSetup? setup;
    try {
      setState(() => _busy = true);
      setup = await svc.setup2fa();
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted) return;

    final codeCtrl = TextEditingController();
    String? dialogError;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          Future<void> confirm() async {
            final code = codeCtrl.text.trim();
            if (code.length != 6) {
              setDlg(() => dialogError = 'Enter the 6-digit code.');
              return;
            }
            setDlg(() => dialogError = null);
            // Capture messenger before async gap to avoid BuildContext lint.
            final messenger = ScaffoldMessenger.of(context);
            try {
              await svc.confirm2fa(code);
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
                if (mounted) setState(() => _totpEnabled = true);
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Two-factor authentication enabled.'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            } catch (e) {
              setDlg(() =>
                  dialogError = e.toString().replaceFirst('Exception: ', ''));
            }
          }

          return AlertDialog(
            title: const Text('Set up 2FA'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Scan this QR code with your authenticator app '
                    '(Google Authenticator, Aegis, etc.), '
                    'then enter the 6-digit code to confirm.',
                  ),
                  const SizedBox(height: 16),
                  QrImageView(
                    data: setup!.uri,
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: Colors.white,
                  ),
                  const SizedBox(height: 8),
                  // Show secret as text for manual entry
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          setup.secret,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: 'Copy secret',
                        onPressed: () => Clipboard.setData(
                            ClipboardData(text: setup!.secret)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: codeCtrl,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Confirm with 6-digit code',
                      counterText: '',
                      errorText: dialogError,
                    ),
                    onSubmitted: (_) => confirm(),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: confirm,
                child: const Text('Enable 2FA'),
              ),
            ],
          );
        },
      ),
    );
    codeCtrl.dispose();
  }

  /// Shows the "Disable 2FA" confirmation dialog.
  Future<void> _showDisable2faDialog() async {
    final svc = context.read<AppProvider>().backendService;
    if (svc == null) return;
    final codeCtrl = TextEditingController();
    String? dialogError;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          Future<void> disable() async {
            final code = codeCtrl.text.trim();
            if (code.length != 6) {
              setDlg(() => dialogError = 'Enter the 6-digit code.');
              return;
            }
            setDlg(() => dialogError = null);
            // Capture messenger before async gap to avoid BuildContext lint.
            final messenger = ScaffoldMessenger.of(context);
            try {
              await svc.disable2fa(code);
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
                if (mounted) setState(() => _totpEnabled = false);
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Two-factor authentication disabled.'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            } catch (e) {
              setDlg(() =>
                  dialogError = e.toString().replaceFirst('Exception: ', ''));
            }
          }

          return AlertDialog(
            title: const Text('Disable 2FA'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                    'Enter your current authenticator code to disable 2FA.'),
                const SizedBox(height: 16),
                TextField(
                  controller: codeCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: '6-digit code',
                    counterText: '',
                    errorText: dialogError,
                  ),
                  onSubmitted: (_) => disable(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor:
                        Theme.of(ctx).colorScheme.error),
                onPressed: disable,
                child: const Text('Disable'),
              ),
            ],
          );
        },
      ),
    );
    codeCtrl.dispose();
  }

  Future<void> _doLogin(bool register) async {
    final p = context.read<AppProvider>();
    final url = _urlCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;
    if (url.isEmpty || user.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Please fill in the server address, username and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (register) {
        await p.backendRegister(url, user, pass);
      } else {
        final result = await p.backendLogin(url, user, pass);
        if (result.requires2fa && result.partialToken != null) {
          // Show the 2FA code dialog before continuing.
          if (mounted) {
            await _show2faLoginDialog(p, result.partialToken!);
          }
          return; // dialog handles its own errors / busy state
        }
      }
      _userCtrl.clear();
      _passCtrl.clear();
    } catch (e) {
      setState(() => _error = _friendlyAuthError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Convert raw exceptions from the auth flow into human-readable messages.
  static String _friendlyAuthError(Object e) {
    if (e is TimeoutException) {
      return 'Connection timed out. The server took too long to respond — '
          'check the URL and your network connection, then try again.';
    }
    if (e is SocketException) {
      return 'Cannot reach the server (${e.message}). '
          'Check the URL and make sure the server is running.';
    }
    final msg = e.toString();
    // Strip the "Exception: " prefix that Dart adds to plain Exception objects.
    return msg.startsWith('Exception: ') ? msg.substring(11) : msg;
  }

  Future<void> _show2faLoginDialog(AppProvider p, String partialToken) async {
    setState(() => _busy = false); // release spinner while dialog is open
    final codeCtrl = TextEditingController();
    String? dialogError;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          Future<void> submit() async {
            final code = codeCtrl.text.trim();
            if (code.length != 6) {
              setDlg(() => dialogError = 'Enter the 6-digit code from your authenticator app.');
              return;
            }
            setDlg(() => dialogError = null);
            try {
              await p.backendComplete2fa(partialToken, code);
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
                _userCtrl.clear();
                _passCtrl.clear();
              }
            } catch (e) {
              setDlg(() => dialogError = e.toString().replaceFirst('Exception: ', ''));
            }
          }

          return AlertDialog(
            title: const Text('Two-Factor Authentication'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Enter the 6-digit code from your authenticator app.'),
                const SizedBox(height: 16),
                TextField(
                  controller: codeCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'TOTP code',
                    counterText: '',
                    errorText: dialogError,
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submit,
                child: const Text('Verify'),
              ),
            ],
          );
        },
      ),
    );
    codeCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Consumer<AppProvider>(
      builder: (context, p, _) {
        final s = p.settings;
        final loggedIn = s.backendToken.isNotEmpty;

        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // ── Enable toggle ────────────────────────────────────────────────
          SwitchListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            title: const Text('Use my LoomChat server'),
            subtitle: Text(loggedIn
                ? 'Replies keep coming even if you close the app or lose Wi-Fi'
                : 'Sign in below first'),
            value: s.useBackend,
            onChanged: loggedIn
                ? (v) async {
                    await p.updateSettings(s.copyWith(useBackend: v));
                    if (v && !p.backendConnected) {
                      await p.backendReconnect();
                    }
                  }
                : null, // disabled until logged in
          ),

          const Divider(height: 1),

          // ── URL + self-signed ────────────────────────────────────────────
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _urlCtrl,
                  keyboardType: TextInputType.url,
                  enabled: !loggedIn,
                  decoration: const InputDecoration(
                    labelText: 'LoomChat server address',
                    hintText: 'https://192.168.1.50',
                    helperText: 'Ask whoever set up your server if unsure',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _awayUrlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Address when away from home (optional)',
                    hintText: 'https://vpn.example.com',
                    helperText: 'Used automatically when the main address cannot be reached',
                  ),
                  onSubmitted: (_) => _saveAwayUrl(),
                  onTapOutside: (_) => _saveAwayUrl(),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow self-signed certificate'),
                  subtitle: const Text(
                      'Turn on if your server uses its own certificate'),
                  value: s.backendAllowSelfSigned,
                  onChanged: (v) => p.setBackendAllowSelfSigned(v),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // ── Auth section ─────────────────────────────────────────────────
          if (!loggedIn) ...[
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _userCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Username'),
                    autofillHints: const [AutofillHints.username],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _passCtrl,
                    obscureText: !_passwordVisible,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      suffixIcon: IconButton(
                        icon: Icon(_passwordVisible
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                        onPressed: () => setState(
                            () => _passwordVisible = !_passwordVisible),
                      ),
                    ),
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _doLogin(false),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(
                          color: cs.error, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _busy ? null : () => _doLogin(false),
                          child: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white),
                                )
                              : const Text('Sign in'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy ? null : () => _doLogin(true),
                          child: const Text('Create account'),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Only use "Create account" the first time you set up a new server.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            // ── Connected state ──────────────────────────────────────────
            ListTile(
              leading: Icon(
                p.backendConnected
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
                color: p.backendConnected ? cs.primary : cs.error,
              ),
              title: Text(p.backendConnected
                  ? 'Signed in'
                  : 'Signed in, but not connected'),
              subtitle: p.backendConnectError != null
                  ? Text(friendlyError(p.backendConnectError!).message,
                      style: TextStyle(color: cs.error, fontSize: 12))
                  : Text(
                      p.backendUsingAway && s.backendAwayUrl.isNotEmpty
                          ? 'Using the away-from-home address'
                          : s.backendUrl,
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 12)),
              trailing: TextButton(
                onPressed: p.backendLogout,
                child: const Text('Sign out'),
              ),
            ),

            const Divider(height: 1),

            // ── 2FA management ───────────────────────────────────────────
            Builder(builder: (ctx) {
              // Fetch status once when we first render this section.
              if (_totpEnabled == null && !_totp2faFetching) {
                WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _fetchTotpStatus());
              }
              return ListTile(
                leading: const Icon(Icons.security_outlined),
                title: const Text('Two-step verification'),
                subtitle: _totp2faFetching
                    ? const Text('Checking status…')
                    : _totpEnabled == null
                        ? null
                        : Text(
                            _totpEnabled! ? 'Enabled' : 'Disabled',
                            style: TextStyle(
                              color: _totpEnabled! ? cs.primary : cs.onSurfaceVariant,
                            ),
                          ),
                trailing: _totp2faFetching
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : _totpEnabled == null
                        ? null
                        : _totpEnabled!
                            ? OutlinedButton(
                                onPressed: _showDisable2faDialog,
                                style: OutlinedButton.styleFrom(
                                    foregroundColor: cs.error,
                                    side: BorderSide(color: cs.error)),
                                child: const Text('Disable'),
                              )
                            : FilledButton.tonal(
                                onPressed: _showSetup2faDialog,
                                child: const Text('Set up'),
                              ),
              );
            }),
          ],
        ]);
      },
    );
  }
}
