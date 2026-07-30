import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/personality.dart';
import '../providers/app_provider.dart';

// ── Personality list screen ───────────────────────────────────────────────────

class PersonalitySettingsScreen extends StatelessWidget {
  const PersonalitySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Personalities'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New personality',
            onPressed: () => _openEditor(context, null),
          ),
        ],
      ),
      body: Consumer<AppProvider>(
        builder: (context, p, _) {
          final personalities = p.settings.personalities;
          final defaultId = p.settings.defaultPersonalityId;
          if (personalities.isEmpty) {
            return const Center(child: Text('No personalities yet'));
          }
          return ListView.builder(
            itemCount: personalities.length,
            itemBuilder: (context, i) {
              final personality = personalities[i];
              final isDefault = personality.id == defaultId;
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  child: Text(
                    personality.name.isNotEmpty
                        ? personality.name[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                      color:
                          Theme.of(context).colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                title: Text(personality.name),
                subtitle: Text(
                  personality.systemPrompt,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isDefault)
                      Tooltip(
                        message: 'Default for new chats',
                        child: Icon(
                          Icons.star_rounded,
                          color: Theme.of(context).colorScheme.primary,
                          size: 18,
                        ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: 'Edit',
                      onPressed: () => _openEditor(context, personality),
                    ),
                    if (personalities.length > 1)
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete',
                        onPressed: () =>
                            _confirmDelete(context, p, personality.id),
                      ),
                  ],
                ),
                onLongPress: isDefault
                    ? null
                    : () async {
                        await p.setDefaultPersonality(personality.id);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  '"${personality.name}" set as default'),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      },
              );
            },
          );
        },
      ),
    );
  }

  void _openEditor(BuildContext context, Personality? existing) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PersonalityEditScreen(existing: existing),
      ),
    );
  }

  void _confirmDelete(
      BuildContext context, AppProvider p, String personalityId) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete personality?'),
        content: const Text(
            'This will not affect existing conversations — they keep their '
            'assigned personality in read-only mode.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () {
              Navigator.pop(ctx);
              p.deletePersonality(personalityId);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

// ── Personality edit / create screen ─────────────────────────────────────────

class _PersonalityEditScreen extends StatefulWidget {
  final Personality? existing;
  const _PersonalityEditScreen({this.existing});

  @override
  State<_PersonalityEditScreen> createState() => _PersonalityEditScreenState();
}

class _PersonalityEditScreenState extends State<_PersonalityEditScreen> {
  late TextEditingController _nameCtrl;
  late TextEditingController _promptCtrl;
  late Set<String> _activeMcpIds;
  bool _isDefault = false;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    final provider = context.read<AppProvider>();
    _nameCtrl = TextEditingController(text: p?.name ?? '');
    _promptCtrl = TextEditingController(text: p?.systemPrompt ?? '');
    _activeMcpIds = p != null
        ? Set.of(p.activeMcpServerIds)
        // New personalities start with no servers selected (per user preference)
        : {};
    _isDefault = p != null &&
        p.id == provider.settings.defaultPersonalityId;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name cannot be empty')),
      );
      return;
    }
    final provider = context.read<AppProvider>();
    if (widget.existing == null) {
      final created = Personality(
        name: name,
        systemPrompt: _promptCtrl.text,
        activeMcpServerIds: _activeMcpIds,
      );
      await provider.addPersonality(created);
      if (_isDefault) await provider.setDefaultPersonality(created.id);
    } else {
      final updated = widget.existing!.copyWith(
        name: name,
        systemPrompt: _promptCtrl.text,
        activeMcpServerIds: _activeMcpIds,
      );
      await provider.updatePersonality(updated);
      if (_isDefault &&
          provider.settings.defaultPersonalityId != updated.id) {
        await provider.setDefaultPersonality(updated.id);
      }
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final allServers = provider.settings.mcpServers
        .where((s) => s.enabled)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null
            ? 'New personality'
            : 'Edit personality'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Name ────────────────────────────────────────────────────────
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 16),

          // ── System prompt ────────────────────────────────────────────────
          TextField(
            controller: _promptCtrl,
            decoration: const InputDecoration(
              labelText: 'System prompt',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            maxLines: 6,
            minLines: 4,
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 16),

          // ── Default flag ─────────────────────────────────────────────────
          SwitchListTile(
            title: const Text('Default for new chats'),
            subtitle: const Text(
                'Pre-select this personality when creating a new conversation'),
            value: _isDefault,
            onChanged: (v) => setState(() => _isDefault = v),
            contentPadding: EdgeInsets.zero,
          ),
          const Divider(height: 32),

          // ── MCP servers ──────────────────────────────────────────────────
          Text(
            'MCP Servers',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Select which globally-configured servers are active for this '
            'personality. The built-in file MCP (folder picker) is always '
            'available regardless.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          if (allServers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No MCP servers configured. Add them in Settings → MCP Servers.',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            )
          else
            ...allServers.map((server) {
              final checked = _activeMcpIds.contains(server.id);
              return CheckboxListTile(
                title: Text(server.name),
                subtitle: Text(
                  server.baseUrlHome,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                value: checked,
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _activeMcpIds.add(server.id);
                    } else {
                      _activeMcpIds.remove(server.id);
                    }
                  });
                },
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              );
            }),
        ],
      ),
    );
  }
}
