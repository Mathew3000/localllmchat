import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/settings.dart';
import '../providers/app_provider.dart';
import '../widgets/color_picker.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _baseUrlHomeController;
  late TextEditingController _baseUrlAwayController;
  late TextEditingController _apiKeyController;
  late TextEditingController _systemPromptController;
  late double _temperature;
  late int _maxTokens;
  String? _selectedModel;
  bool _apiKeyVisible = false;
  late TextEditingController _mcpUrlController;
  bool _mcpEnabled = false;
  late int _requestTimeoutSeconds;
  int? _globalBgColor;
  int? _defaultUserBubbleColor;
  int? _defaultAssistantBubbleColor;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppProvider>().settings;
    _baseUrlHomeController = TextEditingController(text: s.baseUrlHome);
    _baseUrlAwayController = TextEditingController(text: s.baseUrlAway);
    _apiKeyController = TextEditingController(text: s.apiKey);
    _systemPromptController = TextEditingController(text: s.systemPrompt);
    _temperature = s.temperature;
    _maxTokens = s.maxTokens;
    _selectedModel = s.selectedModel.isEmpty ? null : s.selectedModel;
    _mcpUrlController = TextEditingController(text: s.mcpBaseUrl);
    _mcpEnabled = s.mcpEnabled;
    _requestTimeoutSeconds = s.requestTimeoutSeconds;
    _globalBgColor = s.backgroundColor;
    _defaultUserBubbleColor = s.defaultUserBubbleColor;
    _defaultAssistantBubbleColor = s.defaultAssistantBubbleColor;
  }

  @override
  void dispose() {
    _baseUrlHomeController.dispose();
    _baseUrlAwayController.dispose();
    _apiKeyController.dispose();
    _mcpUrlController.dispose();
    _systemPromptController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final provider = context.read<AppProvider>();
    // Preserve secretPasswordHash — it's managed separately via dialogs.
    await provider.updateSettings(
      AppSettings(
        baseUrlHome: _baseUrlHomeController.text.trim(),
        baseUrlAway: _baseUrlAwayController.text.trim(),
        apiKey: _apiKeyController.text.trim(),
        selectedModel: _selectedModel ?? '',
        systemPrompt: _systemPromptController.text,
        temperature: _temperature,
        maxTokens: _maxTokens,
        secretPasswordHash: provider.settings.secretPasswordHash,
        backgroundColor: _globalBgColor,
        defaultUserBubbleColor: _defaultUserBubbleColor,
        defaultAssistantBubbleColor: _defaultAssistantBubbleColor,
        mcpBaseUrl: _mcpUrlController.text.trim(),
        mcpEnabled: _mcpEnabled,
        requestTimeoutSeconds: _requestTimeoutSeconds,
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings saved'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              'Save',
              style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader(title: 'Connection'),
          _SettingsCard(
            children: [
              _LabeledField(
                label: 'Home URL',
                child: TextField(
                  controller: _baseUrlHomeController,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    hintText: 'http://192.168.1.100:5000/v1',
                    helperText: 'Local / Wi-Fi address',
                  ),
                ),
              ),
              const Divider(height: 1),
              _LabeledField(
                label: 'Away URL',
                child: TextField(
                  controller: _baseUrlAwayController,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    hintText: 'http://100.x.x.x:5000/v1',
                    helperText: 'WireGuard / Tailscale — optional',
                  ),
                ),
              ),
              const Divider(height: 1),
              _LabeledField(
                label: 'API Key',
                child: TextField(
                  controller: _apiKeyController,
                  obscureText: !_apiKeyVisible,
                  decoration: InputDecoration(
                    hintText: 'Optional',
                    suffixIcon: IconButton(
                      icon: Icon(_apiKeyVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined),
                      onPressed: () =>
                          setState(() => _apiKeyVisible = !_apiKeyVisible),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Model'),
          _SettingsCard(
            children: [
              Consumer<AppProvider>(
                builder: (_, provider, __) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _LabeledField(
                            label: 'Selected Model',
                            child: provider.availableModels.isEmpty
                                ? TextField(
                                    decoration: InputDecoration(
                                      hintText: _selectedModel ??
                                          'Fetch models first',
                                    ),
                                    onChanged: (v) =>
                                        setState(() => _selectedModel = v),
                                    controller: TextEditingController(
                                        text: _selectedModel ?? ''),
                                  )
                                : DropdownButtonFormField<String>(
                                    initialValue: provider.availableModels
                                            .contains(_selectedModel)
                                        ? _selectedModel
                                        : provider.availableModels.first,
                                    items: provider.availableModels
                                        .map((m) => DropdownMenuItem(
                                            value: m,
                                            child: Text(m,
                                                overflow:
                                                    TextOverflow.ellipsis)))
                                        .toList(),
                                    onChanged: (v) =>
                                        setState(() => _selectedModel = v),
                                    decoration: const InputDecoration(
                                        border: InputBorder.none),
                                  ),
                          ),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: provider.fetchingModels
                              ? null
                              : () {
                                  provider.updateSettings(
                                    provider.settings.copyWith(
                                      baseUrlHome:
                                          _baseUrlHomeController.text.trim(),
                                      baseUrlAway:
                                          _baseUrlAwayController.text.trim(),
                                      apiKey:
                                          _apiKeyController.text.trim(),
                                    ),
                                  );
                                  provider.fetchModels();
                                },
                          icon: provider.fetchingModels
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.refresh_rounded),
                          label: Text(
                              provider.fetchingModels ? 'Loading…' : 'Fetch'),
                        ),
                      ],
                    ),
                    if (provider.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          provider.error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Generation'),
          _SettingsCard(
            children: [
              _SliderField(
                label: 'Temperature',
                value: _temperature,
                min: 0,
                max: 2,
                displayValue: _temperature.toStringAsFixed(2),
                onChanged: (v) => setState(() => _temperature = v),
              ),
              const Divider(height: 1),
              _MaxTokensField(
                value: _maxTokens,
                onChanged: (v) => setState(() => _maxTokens = v),
              ),
              const Divider(height: 1),
              _TimeoutField(
                value: _requestTimeoutSeconds,
                onChanged: (v) => setState(() => _requestTimeoutSeconds = v),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'System Prompt'),
          _SettingsCard(
            children: [
              TextField(
                controller: _systemPromptController,
                maxLines: 6,
                minLines: 3,
                decoration: const InputDecoration(
                  hintText:
                      'You are a helpful, harmless, and honest AI assistant.',
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'MCP Tools'),
          _McpCard(
            urlController: _mcpUrlController,
            enabled: _mcpEnabled,
            onEnabledChanged: (v) => setState(() => _mcpEnabled = v),
          ),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Appearance'),
          _SettingsCard(
            children: [
              _ColorSection(
                icon: Icons.format_paint_outlined,
                label: 'Chat background',
                current: _globalBgColor,
                onPick: (c) => setState(() => _globalBgColor = c),
              ),
              const Divider(height: 1),
              _ColorSection(
                icon: Icons.person_rounded,
                label: 'User bubbles (default)',
                current: _defaultUserBubbleColor,
                onPick: (c) => setState(() => _defaultUserBubbleColor = c),
              ),
              const Divider(height: 1),
              _ColorSection(
                icon: Icons.auto_awesome_rounded,
                label: 'AI bubbles (default)',
                current: _defaultAssistantBubbleColor,
                onPick: (c) => setState(() => _defaultAssistantBubbleColor = c),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Privacy'),
          const _SecretChatsCard(),
          const SizedBox(height: 32),
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
  static double _toSlider(int v) =>
      (v.clamp(_min, _max) - _min) / (_max - _min);

  static int _fromSlider(double s) =>
      (_min + (s * (_max - _min))).round().clamp(_min, _max);

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
                child: Text('Max Tokens',
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
                child: Text('Request Timeout',
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

// ── MCP tools settings card ───────────────────────────────────────────────────

class _McpCard extends StatelessWidget {
  final TextEditingController urlController;
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;

  const _McpCard({
    required this.urlController,
    required this.enabled,
    required this.onEnabledChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Consumer<AppProvider>(
      builder: (_, provider, __) {
        final toolCount = provider.mcpTools.length;
        final fetching = provider.fetchingMcpTools;
        final hasError = provider.error?.startsWith('MCP:') == true;

        return Card(
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Enable toggle row
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.extension_outlined,
                        size: 20, color: cs.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Enable MCP tools',
                          style: theme.textTheme.bodyMedium),
                    ),
                    Switch(value: enabled, onChanged: onEnabledChanged),
                  ],
                ),
              ),
              const Divider(height: 1),
              // URL field
              _LabeledField(
                label: 'MCP Server URL',
                child: TextField(
                  controller: urlController,
                  enabled: enabled,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    hintText: 'http://192.168.1.x:4242',
                    helperText: 'Base URL or full /mcp endpoint',
                  ),
                ),
              ),
              const Divider(height: 1),
              // Fetch button + status
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fetching
                                ? 'Fetching tools…'
                                : toolCount > 0
                                    ? '$toolCount tool${toolCount == 1 ? '' : 's'} loaded'
                                    : 'No tools loaded',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: toolCount > 0 && !fetching
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                            ),
                          ),
                          if (hasError)
                            Text(
                              provider.error!,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: cs.error),
                            ),
                        ],
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: fetching || !enabled
                          ? null
                          : () {
                              provider.updateSettings(
                                provider.settings.copyWith(
                                  mcpBaseUrl: urlController.text.trim(),
                                  mcpEnabled: enabled,
                                ),
                              );
                              provider.fetchMcpTools();
                            },
                      icon: fetching
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded),
                      label: Text(fetching ? 'Loading…' : 'Fetch tools'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
