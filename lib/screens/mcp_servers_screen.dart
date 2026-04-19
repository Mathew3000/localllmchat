import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/mcp_server.dart';
import '../models/tool_call.dart';
import '../providers/app_provider.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

class McpServersScreen extends StatefulWidget {
  const McpServersScreen({super.key});

  @override
  State<McpServersScreen> createState() => _McpServersScreenState();
}

class _McpServersScreenState extends State<McpServersScreen> {
  late List<McpServer> _servers;

  @override
  void initState() {
    super.initState();
    // Work on a mutable copy; the list itself is immutable in settings.
    _servers = context
        .read<AppProvider>()
        .settings
        .mcpServers
        .map((s) => s.copyWith())
        .toList();
  }

  Future<void> _save() async {
    await context.read<AppProvider>().saveMcpServers(List.unmodifiable(_servers));
  }

  void _addServer() {
    setState(() => _servers.add(McpServer()));
    _save();
  }

  void _deleteServer(String id) {
    setState(() => _servers.removeWhere((s) => s.id == id));
    _save();
  }

  void _updateServer(McpServer updated) {
    setState(() {
      final idx = _servers.indexWhere((s) => s.id == updated.id);
      if (idx != -1) _servers[idx] = updated;
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.viewPaddingOf(context).bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP Servers'),
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addServer,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add server'),
      ),
      body: _servers.isEmpty
          ? _EmptyState(onAdd: _addServer)
          : Consumer<AppProvider>(
              builder: (_, provider, __) => ListView.separated(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 96 + bottomPad),
                itemCount: _servers.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, i) {
                  final server = _servers[i];
                  return _McpServerCard(
                    key: ValueKey(server.id),
                    server: server,
                    tools: provider.mcpToolsForServer(server.id),
                    fetching: provider.fetchingForServer(server.id),
                    error: provider.errorForServer(server.id),
                    usingAway: provider.serverUsingAway(server.id),
                    detectedTransport:
                        provider.detectedTransportForServer(server.id),
                    onChanged: _updateServer,
                    onDelete: () => _showDeleteConfirm(context, server),
                    onFetch: () => provider.fetchMcpToolsForServer(server),
                  );
                },
              ),
            ),
    );
  }

  Future<void> _showDeleteConfirm(
      BuildContext context, McpServer server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete server?'),
        content: Text(
          'Remove "${server.name}"? Loaded tools from this server will also be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) _deleteServer(server.id);
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.extension_outlined,
                size: 56, color: cs.primary.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(
              'No MCP servers',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap + Add server to connect your\nfirst MCP tool server.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Server card ───────────────────────────────────────────────────────────────

class _McpServerCard extends StatefulWidget {
  final McpServer server;
  final List<McpToolDef> tools;
  final bool fetching;
  final String? error;
  final bool usingAway;
  /// When transport is [McpTransport.auto], shows which protocol was detected.
  final String? detectedTransport;
  final ValueChanged<McpServer> onChanged;
  final VoidCallback onDelete;
  final VoidCallback onFetch;

  const _McpServerCard({
    super.key,
    required this.server,
    required this.tools,
    required this.fetching,
    required this.error,
    required this.usingAway,
    this.detectedTransport,
    required this.onChanged,
    required this.onDelete,
    required this.onFetch,
  });

  @override
  State<_McpServerCard> createState() => _McpServerCardState();
}

class _McpServerCardState extends State<_McpServerCard> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _homeCtrl;
  late final TextEditingController _awayCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.server.name);
    _homeCtrl = TextEditingController(text: widget.server.baseUrlHome);
    _awayCtrl = TextEditingController(text: widget.server.baseUrlAway);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _homeCtrl.dispose();
    _awayCtrl.dispose();
    super.dispose();
  }

  McpServer get _current => widget.server.copyWith(
        name: _nameCtrl.text.trim().isEmpty ? 'Server' : _nameCtrl.text.trim(),
        baseUrlHome: _homeCtrl.text.trim(),
        baseUrlAway: _awayCtrl.text.trim(),
      );

  void _commit() => widget.onChanged(_current);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header: enable toggle + name + delete ─────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Row(
              children: [
                Switch(
                  value: widget.server.enabled,
                  onChanged: (v) =>
                      widget.onChanged(widget.server.copyWith(enabled: v)),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: _nameCtrl,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    decoration: const InputDecoration(
                      hintText: 'Server name',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                    ),
                    onSubmitted: (_) => _commit(),
                    onTapOutside: (_) => _commit(),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 20, color: cs.error.withValues(alpha: 0.7)),
                  onPressed: widget.onDelete,
                  tooltip: 'Delete server',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // ── Home URL ──────────────────────────────────────────────────────
          _UrlField(
            label: 'Server URL',
            controller: _homeCtrl,
            hint: 'http://192.168.1.x:4242',
            helper: 'Home / local network',
            onCommit: _commit,
            trailing: widget.server.baseUrlAway.isNotEmpty && !widget.usingAway
                ? _ActiveBadge(label: 'active', cs: cs)
                : null,
          ),
          const Divider(height: 1),

          // ── Away URL ─────────────────────────────────────────────────────
          _UrlField(
            label: 'Away URL',
            controller: _awayCtrl,
            hint: 'http://100.x.x.x:4242',
            helper: 'VPN / remote — optional',
            onCommit: _commit,
            trailing: widget.usingAway
                ? _ActiveBadge(label: 'active', cs: cs)
                : null,
          ),
          const Divider(height: 1),

          // ── Transport selector ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Transport',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    if (widget.server.transport == McpTransport.auto &&
                        widget.detectedTransport != null)
                      Text(
                        'detected: ${widget.detectedTransport}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.primary,
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SegmentedButton<McpTransport>(
                    segments: const [
                      ButtonSegment(
                        value: McpTransport.auto,
                        label: Text('Auto'),
                        icon: Icon(Icons.auto_awesome_rounded),
                      ),
                      ButtonSegment(
                        value: McpTransport.streamableHttp,
                        label: Text('HTTP'),
                        icon: Icon(Icons.http_rounded),
                      ),
                      ButtonSegment(
                        value: McpTransport.sse,
                        label: Text('SSE'),
                        icon: Icon(Icons.stream_rounded),
                      ),
                    ],
                    selected: {widget.server.transport},
                    showSelectedIcon: false,
                    onSelectionChanged: (sel) => widget.onChanged(
                        widget.server.copyWith(transport: sel.first)),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // ── Status row ────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Row(
              children: [
                // Tool count chip — tappable when tools are loaded
                if (widget.fetching)
                  _StatusChip(
                    icon: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: cs.onSurfaceVariant),
                    ),
                    label: 'Loading…',
                    cs: cs,
                  )
                else if (widget.tools.isNotEmpty)
                  GestureDetector(
                    onTap: () => _showToolsSheet(context),
                    child: _StatusChip(
                      icon: Icon(Icons.extension_rounded,
                          size: 14, color: cs.primary),
                      label:
                          '${widget.tools.length} tool${widget.tools.length == 1 ? '' : 's'}',
                      cs: cs,
                      primary: true,
                    ),
                  )
                else
                  _StatusChip(
                    icon: Icon(Icons.extension_off_outlined,
                        size: 14, color: cs.onSurfaceVariant),
                    label: 'No tools',
                    cs: cs,
                  ),

                // Error message
                if (widget.error != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.error!.replaceFirst('Exception: ', ''),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: cs.error),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ] else
                  const Spacer(),

                // Fetch button
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: widget.fetching || !widget.server.enabled
                      ? null
                      : () {
                          // Persist the latest URL edits before fetching.
                          widget.onChanged(_current);
                          widget.onFetch();
                        },
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Fetch'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showToolsSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ToolsSheet(
        serverName: widget.server.name,
        tools: widget.tools,
      ),
    );
  }
}

// ── URL text field ────────────────────────────────────────────────────────────

class _UrlField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final String helper;
  final VoidCallback onCommit;
  final Widget? trailing;

  const _UrlField({
    required this.label,
    required this.controller,
    required this.hint,
    required this.helper,
    required this.onCommit,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 6),
                trailing!,
              ],
            ],
          ),
          TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: hint,
              helperText: helper,
              border: InputBorder.none,
              isDense: true,
            ),
            onSubmitted: (_) => onCommit(),
            onTapOutside: (_) => onCommit(),
          ),
        ],
      ),
    );
  }
}

// ── Small "active" badge ──────────────────────────────────────────────────────

class _ActiveBadge extends StatelessWidget {
  final String label;
  final ColorScheme cs;
  const _ActiveBadge({required this.label, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: cs.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Status chip ───────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final Widget icon;
  final String label;
  final ColorScheme cs;
  final bool primary;

  const _StatusChip({
    required this.icon,
    required this.label,
    required this.cs,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: primary
            ? cs.primaryContainer.withValues(alpha: 0.6)
            : cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: primary
              ? cs.primary.withValues(alpha: 0.3)
              : cs.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: primary ? cs.primary : cs.onSurfaceVariant,
              fontWeight: primary ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tools bottom sheet ────────────────────────────────────────────────────────

class _ToolsSheet extends StatelessWidget {
  final String serverName;
  final List<McpToolDef> tools;

  const _ToolsSheet({
    required this.serverName,
    required this.tools,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bottomPad = MediaQuery.viewPaddingOf(context).bottom;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      builder: (_, scrollCtrl) => Column(
        children: [
          // Handle
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: cs.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Title
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Row(
              children: [
                Icon(Icons.extension_rounded, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    serverName,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${tools.length} tool${tools.length == 1 ? '' : 's'}',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Tool list
          Expanded(
            child: ListView.builder(
              controller: scrollCtrl,
              padding:
                  EdgeInsets.fromLTRB(12, 8, 12, 12 + bottomPad),
              itemCount: tools.length,
              itemBuilder: (_, i) {
                final tool = tools[i];
                return ListTile(
                  dense: true,
                  leading: Icon(Icons.code_rounded,
                      size: 18, color: cs.primary.withValues(alpha: 0.7)),
                  title: Text(
                    tool.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: tool.description.isNotEmpty
                      ? Text(
                          tool.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        )
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
