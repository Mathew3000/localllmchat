import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/conversation.dart';
import '../models/mcp_server.dart';
import '../providers/app_provider.dart';
import '../widgets/message_bubble.dart';
import '../widgets/tool_bubble.dart';
import '../widgets/chat_input.dart';
import '../widgets/color_picker.dart';
import 'settings_screen.dart';

// Width threshold above which the permanent sidebar is shown instead of a drawer.
const double _kSidebarBreakpoint = 720;
const double _kSidebarWidth = 300;

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scrollController = ScrollController();
  // Only used on mobile (drawer trigger).
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      if (animated) {
        _scrollController.animateTo(max,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut);
      } else {
        _scrollController.jumpTo(max);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Mobile platforms always use the drawer regardless of screen width.
    final platform = Theme.of(context).platform;
    final isMobile = platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS;
    final isDesktop = !isMobile &&
        MediaQuery.sizeOf(context).width >= _kSidebarBreakpoint;

    return Consumer<AppProvider>(
      builder: (context, p, _) {
        final bgColor = p.settings.backgroundColor != null
            ? Color(p.settings.backgroundColor!)
            : null;

        // ── Shared action buttons ──────────────────────────────────────────
        final actions = <Widget>[
          if (p.mcpConfigured) const _McpToggleButton(),
          if (p.settings.baseUrlAway.isNotEmpty)
            Tooltip(
              message: p.usingAwayUrl
                  ? 'Away (VPN) — tap to recheck'
                  : 'Home — tap to recheck',
              child: IconButton(
                icon: Icon(
                  p.usingAwayUrl
                      ? Icons.router_outlined
                      : Icons.home_rounded,
                  color: p.usingAwayUrl
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                onPressed: p.recheckNetwork,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'New chat',
            onPressed: () {
              p.newConversation();
              _scrollToBottom(animated: false);
            },
          ),
          // Settings only in AppBar on mobile; on desktop it lives in the sidebar.
          if (!isDesktop)
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
            ),
        ];

        // ── Chat panel content (shared between layouts) ────────────────────
        Widget chatPanel = _buildChatPanel(p, bgColor);

        if (isDesktop) {
          return Scaffold(
            backgroundColor: bgColor,
            body: Row(
              children: [
                // ── Permanent sidebar ──────────────────────────────────────
                SizedBox(
                  width: _kSidebarWidth,
                  child: _DesktopSidebar(scrollToBottom: _scrollToBottom),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                // ── Chat area ─────────────────────────────────────────────
                Expanded(
                  child: Column(
                    children: [
                      _DesktopChatHeader(
                        title: p.activeConversation?.title ?? 'LoomChat',
                        actions: actions,
                        bgColor: bgColor,
                      ),
                      Expanded(child: chatPanel),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        // ── Mobile layout ─────────────────────────────────────────────────
        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: bgColor,
          drawer: const _ConversationDrawer(),
          appBar: AppBar(
            backgroundColor: bgColor,
            leading: IconButton(
              icon: const Icon(Icons.menu_rounded),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            title: _AppBarTitle(
              title: p.activeConversation?.title ?? 'LoomChat',
            ),
            actions: actions,
            elevation: 0,
            scrolledUnderElevation: 1,
          ),
          body: chatPanel,
        );
      },
    );
  }

  /// The message list + error banner + input, used by both layouts.
  Widget _buildChatPanel(AppProvider p, Color? bgColor) {
    return Column(
      children: [
        Expanded(
          child: _MessageList(scrollController: _scrollController),
        ),
        Consumer<AppProvider>(
          builder: (_, p, __) {
            if (p.error != null) {
              return _ErrorBanner(
                  error: p.error!, onDismiss: p.clearError);
            }
            return const SizedBox.shrink();
          },
        ),
        Consumer<AppProvider>(
          builder: (_, p, __) => ChatInput(
            isStreaming: p.isStreaming,
            onSend: (text, images) {
              p.sendMessage(text, images: images);
              _scrollToBottom();
            },
            onCancel: p.cancelStream,
            messageQueue: p.messageQueue,
            onRemoveFromQueue: p.removeFromQueue,
            onClearQueue: p.clearQueue,
            promptTokens: p.activePromptTokens,
            contextWindowTokens: p.settings.contextWindowTokens,
          ),
        ),
      ],
    );
  }
}

// ── Desktop: permanent sidebar ────────────────────────────────────────────────

class _DesktopSidebar extends StatelessWidget {
  final void Function({bool animated}) scrollToBottom;
  const _DesktopSidebar({required this.scrollToBottom});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerLow,
      child: Column(
        children: [
          // ── Header ──────────────────────────────────────────────────────
          _SidebarHeader(),
          // ── New chat ─────────────────────────────────────────────────────
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Consumer<AppProvider>(
              builder: (_, p, __) => FilledButton.tonalIcon(
                onPressed: () => p.newConversation(),
                icon: const Icon(Icons.add_rounded),
                label: const Text('New Chat'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 44),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          // ── Conversation list ─────────────────────────────────────────
          const Expanded(
            child: _ConversationListView(closeDrawer: false),
          ),
          const Divider(height: 1),
          // ── Settings ──────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          SizedBox(height: MediaQuery.viewPaddingOf(context).bottom),
        ],
      ),
    );
  }
}

// ── Desktop: thin header bar above the chat panel ─────────────────────────────

// ── Shared token-count formatter ──────────────────────────────────────────────

// ── Mobile app bar title ──────────────────────────────────────────────────────

class _AppBarTitle extends StatelessWidget {
  final String title;

  const _AppBarTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      title,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}

// ── Desktop chat header ───────────────────────────────────────────────────────

class _DesktopChatHeader extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  final Color? bgColor;

  const _DesktopChatHeader({
    required this.title,
    required this.actions,
    this.bgColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: bgColor ?? cs.surface,
      elevation: 0,
      child: Container(
        height: kToolbarHeight,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.5), width: 1),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

// ── Shared sidebar header (app name + secret unlock trigger) ──────────────────

class _SidebarHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Consumer<AppProvider>(
      builder: (_, p, __) => GestureDetector(
        onLongPress: p.hasSecretPassword
            ? () => p.secretsUnlocked
                ? _confirmLock(context, p)
                : _showUnlockDialog(context, p)
            : null,
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(
              16, 16 + MediaQuery.viewPaddingOf(context).top, 16, 16),
          color: cs.primary,
          child: Row(
            children: [
              Icon(Icons.auto_awesome_rounded,
                  color: cs.onPrimary, size: 28),
              const SizedBox(width: 10),
              Text(
                'LoomChat',
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: cs.onPrimary),
              ),
              if (p.secretsUnlocked) ...[
                const Spacer(),
                Icon(Icons.lock_open_rounded,
                    color: cs.onPrimary.withValues(alpha: 0.5), size: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showUnlockDialog(BuildContext context, AppProvider provider) {
    showDialog<void>(
        context: context,
        builder: (_) => _UnlockDialog(provider: provider));
  }

  void _confirmLock(BuildContext context, AppProvider provider) {
    provider.lockSecrets();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Secret chats locked'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 1),
      ),
    );
  }
}

// ── Message list ──────────────────────────────────────────────────────────────

class _MessageList extends StatelessWidget {
  final ScrollController scrollController;
  const _MessageList({required this.scrollController});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (_, p, __) {
        final conv = p.activeConversation;
        if (conv == null || conv.messages.isEmpty) {
          return _EmptyState(activeUrl: p.activeBaseUrl);
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!scrollController.hasClients) return;
          final pos = scrollController.position;
          if (pos.maxScrollExtent - pos.pixels < 80) {
            scrollController.animateTo(
              pos.maxScrollExtent,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
            );
          }
        });

        final userColor = conv.userBubbleColor != null
            ? Color(conv.userBubbleColor!)
            : p.settings.defaultUserBubbleColor != null
                ? Color(p.settings.defaultUserBubbleColor!)
                : null;
        final aiColor = conv.assistantBubbleColor != null
            ? Color(conv.assistantBubbleColor!)
            : p.settings.defaultAssistantBubbleColor != null
                ? Color(p.settings.defaultAssistantBubbleColor!)
                : null;

        return ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.symmetric(vertical: 12),
          itemCount: conv.messages.length,
          itemBuilder: (_, i) {
            final msg = conv.messages[i];
            if (msg.hasToolCalls || msg.isToolResult) {
              return ToolBubble(message: msg);
            }
            return MessageBubble(
              message: msg,
              userBubbleColor: userColor,
              assistantBubbleColor: aiColor,
              highlightColor: p.settings.highlightColor != null
                  ? Color(p.settings.highlightColor!)
                  : null,
              onDelete: p.isStreaming
                  ? null // disable during streaming
                  : (withResponse) => p.deleteMessage(
                        msg.id,
                        andFollowingResponse: withResponse,
                      ),
            );
          },
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String activeUrl;
  const _EmptyState({required this.activeUrl});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_rounded,
                size: 64, color: cs.primary.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            Text(
              'Start a conversation',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(color: cs.onSurface),
            ),
            const SizedBox(height: 8),
            Text(
              'Connected to:\n$activeUrl',
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

class _ErrorBanner extends StatelessWidget {
  final String error;
  final VoidCallback onDismiss;

  const _ErrorBanner({required this.error, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: cs.errorContainer,
      child: Row(
        children: [
          Icon(Icons.error_outline, color: cs.onErrorContainer, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, color: cs.onErrorContainer, size: 18),
            onPressed: onDismiss,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

// ── Mobile drawer ─────────────────────────────────────────────────────────────

class _ConversationDrawer extends StatelessWidget {
  const _ConversationDrawer();

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          _DrawerHeader(),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Consumer<AppProvider>(
              builder: (_, p, __) => FilledButton.tonalIcon(
                onPressed: () {
                  p.newConversation();
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.add_rounded),
                label: const Text('New Chat'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 44),
                ),
              ),
            ),
          ),
          const Divider(),
          const Expanded(
            child: _ConversationListView(closeDrawer: true),
          ),
        ],
      ),
    );
  }
}

// ── Shared conversation list (used in both drawer and desktop sidebar) ─────────

class _ConversationListView extends StatelessWidget {
  /// When true, tapping a conversation calls Navigator.pop to close the drawer.
  final bool closeDrawer;
  const _ConversationListView({required this.closeDrawer});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Consumer<AppProvider>(
      builder: (_, p, __) {
        final visible = p.visibleConversations;
        if (visible.isEmpty) {
          return Center(
            child: Text(
              'No conversations yet',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: visible.length,
          itemBuilder: (_, i) {
            final conv = visible[i];
            final isActive = conv.id == p.activeConversation?.id;
            return _ConversationTile(
              conv: conv,
              isActive: isActive,
              showSecretBadge: p.secretsUnlocked && conv.isSecret,
              onTap: () {
                p.selectConversation(conv);
                if (closeDrawer) Navigator.pop(context);
              },
              onDelete: () => p.deleteConversation(conv.id),
              onRename: (title) => p.renameConversation(conv.id, title),
              onToggleSecret:
                  p.hasSecretPassword && p.secretsUnlocked
                      ? () => p.toggleConversationSecret(conv.id)
                      : null,
            );
          },
        );
      },
    );
  }
}

// ── Mobile drawer header with hidden unlock trigger ───────────────────────────

class _DrawerHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Consumer<AppProvider>(
      builder: (_, p, __) {
        return GestureDetector(
          onLongPress: p.hasSecretPassword
              ? () => p.secretsUnlocked
                  ? _confirmLock(context, p)
                  : _showUnlockDialog(context, p)
              : null,
          child: DrawerHeader(
            decoration: BoxDecoration(color: cs.primary),
            margin: EdgeInsets.zero,
            child: Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.auto_awesome_rounded,
                        color: cs.onPrimary, size: 32),
                    const SizedBox(width: 12),
                    Text(
                      'LoomChat',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(color: cs.onPrimary),
                    ),
                  ],
                ),
                if (p.secretsUnlocked)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Icon(
                      Icons.lock_open_rounded,
                      color: cs.onPrimary.withValues(alpha: 0.45),
                      size: 16,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showUnlockDialog(BuildContext context, AppProvider provider) {
    showDialog<void>(
      context: context,
      builder: (_) => _UnlockDialog(provider: provider),
    );
  }

  void _confirmLock(BuildContext context, AppProvider provider) {
    provider.lockSecrets();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Secret chats locked'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 1),
      ),
    );
  }
}

// ── Unlock dialog ─────────────────────────────────────────────────────────────

class _UnlockDialog extends StatefulWidget {
  final AppProvider provider;
  const _UnlockDialog({required this.provider});

  @override
  State<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<_UnlockDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _wrong = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final ok = widget.provider.unlockSecrets(_controller.text);
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() {
        _wrong = true;
        _controller.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Unlock'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            obscureText: _obscure,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              border: const OutlineInputBorder(),
              errorText: _wrong ? 'Incorrect password' : null,
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
            child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Unlock')),
      ],
    );
  }
}

// ── Conversation tile ─────────────────────────────────────────────────────────

class _ConversationTile extends StatelessWidget {
  final Conversation conv;
  final bool isActive;
  final bool showSecretBadge;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onToggleSecret;
  final void Function(String newTitle) onRename;

  const _ConversationTile({
    required this.conv,
    required this.isActive,
    required this.showSecretBadge,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
    this.onToggleSecret,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Dismissible(
      key: Key(conv.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: cs.errorContainer,
        child: Icon(Icons.delete_outline, color: cs.onErrorContainer),
      ),
      onDismissed: (_) => onDelete(),
      child: ListTile(
        selected: isActive,
        selectedTileColor: cs.primaryContainer.withValues(alpha: 0.5),
        onTap: onTap,
        onLongPress: () => _showContextSheet(context),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        leading: Icon(
          showSecretBadge
              ? Icons.lock_rounded
              : Icons.chat_bubble_outline_rounded,
          color: showSecretBadge
              ? cs.primary.withValues(alpha: 0.7)
              : isActive
                  ? cs.primary
                  : cs.onSurfaceVariant,
          size: 20,
        ),
        title: Text(
          conv.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
            fontSize: 14,
          ),
        ),
        subtitle: Text(
          conv.preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        trailing: IconButton(
          icon: Icon(Icons.delete_outline,
              size: 18, color: cs.onSurfaceVariant),
          onPressed: onDelete,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  Future<void> _showRenameDialog(BuildContext context) async {
    final ctrl = TextEditingController(text: conv.title);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename conversation'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Name',
            border: OutlineInputBorder(),
            counterText: '',
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('Rename')),
        ],
      ),
    );
    ctrl.dispose();
    if (result != null && result.trim().isNotEmpty) {
      onRename(result.trim());
    }
  }

  void _showContextSheet(BuildContext outerContext) {
    final cs = Theme.of(outerContext).colorScheme;
    final provider = outerContext.read<AppProvider>();

    showModalBottomSheet<void>(
      context: outerContext,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                conv.title,
                style: Theme.of(outerContext)
                    .textTheme
                    .titleSmall
                    ?.copyWith(color: cs.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(),
            ListTile(
              leading: Icon(Icons.person_rounded, color: cs.primary),
              title: const Text('User bubble color'),
              trailing: conv.userBubbleColor != null
                  ? _ColorDot(color: Color(conv.userBubbleColor!))
                  : null,
              onTap: () => showColorPickerDialog(
                context: outerContext,
                title: 'User Bubble Color',
                current: conv.userBubbleColor,
                onPick: (c) => provider.setConversationColors(
                  conv.id,
                  userBubbleColor: c,
                  assistantBubbleColor: conv.assistantBubbleColor,
                ),
              ),
            ),
            ListTile(
              leading:
                  Icon(Icons.auto_awesome_rounded, color: cs.primary),
              title: const Text('AI bubble color'),
              trailing: conv.assistantBubbleColor != null
                  ? _ColorDot(color: Color(conv.assistantBubbleColor!))
                  : null,
              onTap: () => showColorPickerDialog(
                context: outerContext,
                title: 'AI Bubble Color',
                current: conv.assistantBubbleColor,
                onPick: (c) => provider.setConversationColors(
                  conv.id,
                  userBubbleColor: conv.userBubbleColor,
                  assistantBubbleColor: c,
                ),
              ),
            ),
            const Divider(),
            if (onToggleSecret != null)
              ListTile(
                leading: Icon(
                  conv.isSecret
                      ? Icons.lock_open_rounded
                      : Icons.lock_outline_rounded,
                  color: cs.primary,
                ),
                title: Text(conv.isSecret
                    ? 'Remove from secret chats'
                    : 'Move to secret chats'),
                onTap: () {
                  Navigator.pop(outerContext);
                  onToggleSecret!();
                },
              ),
            ListTile(
              leading: Icon(Icons.edit_outlined, color: cs.primary),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(outerContext);
                _showRenameDialog(outerContext);
              },
            ),
            ListTile(
              leading:
                  Icon(Icons.delete_outline_rounded, color: cs.error),
              title: Text('Delete', style: TextStyle(color: cs.error)),
              onTap: () {
                Navigator.pop(outerContext);
                onDelete();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ── Small colour dot shown as a ListTile trailing ─────────────────────────────

class _ColorDot extends StatelessWidget {
  final Color color;
  const _ColorDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 1.5,
        ),
      ),
    );
  }
}

// ── MCP toggle button ─────────────────────────────────────────────────────────
//
// Short tap  → toggle all MCP tools on/off.
// Long press → show a popup anchored to the button with per-server switches.

class _McpToggleButton extends StatelessWidget {
  const _McpToggleButton();

  void _showServerMenu(BuildContext context) {
    final p = context.read<AppProvider>();
    final servers = p.settings.mcpServers
        .where((s) => s.baseUrlHome.isNotEmpty)
        .toList();
    if (servers.isEmpty) return;

    final btn = context.findRenderObject() as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final pos = RelativeRect.fromRect(
      Rect.fromPoints(
        btn.localToGlobal(Offset.zero, ancestor: overlay),
        btn.localToGlobal(btn.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    showMenu<void>(
      context: context,
      position: pos,
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        _McpServersMenuEntry(servers: servers, provider: p),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, p, _) {
        final cs = Theme.of(context).colorScheme;
        return Tooltip(
          message: p.mcpActive
              ? 'Tools on — hold for per-server'
              : 'Tools off — hold for per-server',
          child: GestureDetector(
            onLongPress: () => _showServerMenu(context),
            child: IconButton(
              icon: Icon(
                p.mcpActive
                    ? Icons.extension_rounded
                    : Icons.extension_off_rounded,
                color: p.mcpActive
                    ? cs.primary
                    : cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              onPressed: p.toggleMcp,
            ),
          ),
        );
      },
    );
  }
}

// ── Per-server menu entry ─────────────────────────────────────────────────────
//
// A PopupMenuEntry subclass (not PopupMenuItem) so the Switch widgets are
// fully interactive — PopupMenuItem wraps its child in IgnorePointer when
// enabled:false, which would swallow touch events.

class _McpServersMenuEntry extends PopupMenuEntry<Never> {
  final List<McpServer> servers;
  final AppProvider provider;

  const _McpServersMenuEntry({
    required this.servers,
    required this.provider,
  });

  // height is used by showMenu for scroll physics; approximate per-row height.
  @override
  double get height => servers.length * 48.0 + 36;

  @override
  bool represents(Never? value) => false;

  @override
  State<_McpServersMenuEntry> createState() => _McpServersMenuEntryState();
}

class _McpServersMenuEntryState extends State<_McpServersMenuEntry> {
  late List<McpServer> _servers;

  @override
  void initState() {
    super.initState();
    _servers = List.of(widget.servers);
  }

  void _toggle(String id, bool value) {
    setState(() {
      final i = _servers.indexWhere((s) => s.id == id);
      if (i >= 0) _servers[i] = _servers[i].copyWith(enabled: value);
    });
    // Merge back into the full server list (preserves servers not shown here).
    final allServers = widget.provider.settings.mcpServers.map((s) {
      try {
        return _servers.firstWhere((u) => u.id == s.id);
      } catch (_) {
        return s;
      }
    }).toList();
    widget.provider.saveMcpServers(List.unmodifiable(allServers));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            'MCP Servers',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        for (int i = 0; i < _servers.length; i++) ...[
          if (i > 0)
            Divider(
                height: 1,
                indent: 16,
                endIndent: 16,
                color: cs.outlineVariant.withValues(alpha: 0.5)),
          SwitchListTile(
            dense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
            title: Text(
              _servers[i].name,
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
            value: _servers[i].enabled,
            onChanged: (v) => _toggle(_servers[i].id, v),
          ),
        ],
        const SizedBox(height: 6),
      ],
    );
  }
}
