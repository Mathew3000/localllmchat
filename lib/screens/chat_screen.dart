import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/conversation.dart';
import '../providers/app_provider.dart';
import '../widgets/message_bubble.dart';
import '../widgets/tool_bubble.dart';
import '../widgets/chat_input.dart';
import '../widgets/color_picker.dart';
import 'settings_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scrollController = ScrollController();
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
    final theme = Theme.of(context);
    return Consumer<AppProvider>(
      builder: (context, p, _) {
        final bgColor = p.settings.backgroundColor != null
            ? Color(p.settings.backgroundColor!)
            : null;
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
            title: Text(
              p.activeConversation?.title ?? 'LocalLLMChat',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            actions: [
              // Network indicator — only shown when an away URL is configured.
              if (p.settings.baseUrlAway.isNotEmpty)
                Tooltip(
                  message: p.usingAwayUrl
                      ? 'Away (VPN) — tap to recheck'
                      : 'Home — tap to recheck',
                  child: IconButton(
                    icon: Icon(
                      p.usingAwayUrl ? Icons.router_outlined : Icons.home_rounded,
                      color: p.usingAwayUrl ? theme.colorScheme.primary : null,
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
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
            elevation: 0,
            scrolledUnderElevation: 1,
          ),
          body: Column(
            children: [
              Expanded(child: _MessageList(scrollController: _scrollController)),
              Consumer<AppProvider>(
                builder: (_, p, __) {
                  if (p.error != null) {
                    return _ErrorBanner(
                      error: p.error!,
                      onDismiss: p.clearError,
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              Consumer<AppProvider>(
                builder: (_, p, __) => ChatInput(
                  isStreaming: p.isStreaming,
                  onSend: (text) {
                    p.sendMessage(text);
                    _scrollToBottom();
                  },
                  onCancel: p.cancelStream,
                ),
              ),
            ],
          ),
        );
      },
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
        // Fallback chain: per-chat override → global default → theme default (null)
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

// ── Drawer ────────────────────────────────────────────────────────────────────

class _ConversationDrawer extends StatelessWidget {
  const _ConversationDrawer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Drawer(
      child: Column(
        children: [
          _DrawerHeader(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
          Expanded(
            child: Consumer<AppProvider>(
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
                        Navigator.pop(context);
                      },
                      onDelete: () => p.deleteConversation(conv.id),
                      onToggleSecret: p.hasSecretPassword && p.secretsUnlocked
                          ? () => p.toggleConversationSecret(conv.id)
                          : null,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── Drawer header with hidden unlock trigger ──────────────────────────────────

class _DrawerHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Consumer<AppProvider>(
      builder: (_, p, __) {
        return GestureDetector(
          // ── Hidden trigger: long-press the header to unlock/lock secrets ──
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
                      'LocalLLMChat',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(color: cs.onPrimary),
                    ),
                  ],
                ),
                // Subtle unlocked indicator — only visible when secrets are open
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

  const _ConversationTile({
    required this.conv,
    required this.isActive,
    required this.showSecretBadge,
    required this.onTap,
    required this.onDelete,
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

  void _showContextSheet(BuildContext outerContext) {
    final cs = Theme.of(outerContext).colorScheme;
    final provider = outerContext.read<AppProvider>();

    showModalBottomSheet<void>(
      context: outerContext,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
            // ── User bubble colour ──────────────────────────────────────
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
            // ── AI bubble colour ────────────────────────────────────────
            ListTile(
              leading: Icon(Icons.auto_awesome_rounded, color: cs.primary),
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
            // Toggle secret
            if (onToggleSecret != null)
              ListTile(
                leading: Icon(
                  conv.isSecret
                      ? Icons.lock_open_rounded
                      : Icons.lock_outline_rounded,
                  color: cs.primary,
                ),
                title: Text(
                  conv.isSecret
                      ? 'Remove from secret chats'
                      : 'Move to secret chats',
                ),
                onTap: () {
                  Navigator.pop(outerContext);
                  onToggleSecret!();
                },
              ),
            // Delete
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: cs.error),
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
