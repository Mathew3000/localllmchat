import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/conversation.dart';
import '../models/mcp_server.dart';
import '../providers/app_provider.dart';
import '../widgets/message_bubble.dart';
import '../widgets/tool_bubble.dart';
import '../widgets/chat_input.dart';
import '../widgets/color_picker.dart';
import '../widgets/friendly.dart';
import 'mcp_servers_screen.dart';
import 'personality_settings_screen.dart';
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

  String? _lastActiveConvId;
  bool _sidebarVisible = true;

  @override
  void initState() {
    super.initState();
    // Schedule listener setup after the first frame so the provider is
    // available via context.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final p = context.read<AppProvider>();
      _lastActiveConvId = p.activeConversation?.id;
      p.addListener(_onProviderChanged);
      _pendingJump = true;
      _onProviderChanged();
    });
  }

  /// Set when a chat was opened; cleared once the list has reached its end.
  /// Messages may arrive later than the switch (backend loads them lazily),
  /// so the jump waits until there is something to show.
  bool _pendingJump = false;
  bool _jumpScheduled = false;

  void _onProviderChanged() {
    final conv = context.read<AppProvider>().activeConversation;
    if (conv != null && conv.id != _lastActiveConvId) {
      _lastActiveConvId = conv.id;
      _pendingJump = true;
    }
    if (_pendingJump && conv != null && conv.messages.isNotEmpty) {
      _jumpToEnd();
    }
  }

  /// Jumps to the bottom over a few frames: the list only measures messages
  /// as they are built, so the first jump can stop short of the real end.
  void _jumpToEnd([int tries = 0]) {
    if (_jumpScheduled && tries == 0) return;
    _jumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (pos.pixels >= pos.maxScrollExtent - 1 && tries > 0) {
        _pendingJump = false;
        return;
      }
      _scrollController.jumpTo(pos.maxScrollExtent);
      if (tries < 10) {
        _jumpToEnd(tries + 1);
      } else {
        _pendingJump = false;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    context.read<AppProvider>().removeListener(_onProviderChanged);
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
          const _ConnectionButton(),
          if (p.mcpConfigured) const _McpToggleButton(),
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
                // ── Collapsible sidebar ────────────────────────────────────
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOut,
                  child: SizedBox(
                    width: _sidebarVisible ? _kSidebarWidth : 0,
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: _kSidebarWidth,
                      maxWidth: _kSidebarWidth,
                      child: _DesktopSidebar(scrollToBottom: _scrollToBottom),
                    ),
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOut,
                  child: SizedBox(
                    width: _sidebarVisible ? 1 : 0,
                    child: const VerticalDivider(width: 1, thickness: 1),
                  ),
                ),
                // ── Chat area ─────────────────────────────────────────────
                Expanded(
                  child: Column(
                    children: [
                      _DesktopChatHeader(
                        title: p.activeConversation?.title ?? 'New chat',
                        actions: actions,
                        bgColor: bgColor,
                        sidebarVisible: _sidebarVisible,
                        onToggleSidebar: () => setState(
                            () => _sidebarVisible = !_sidebarVisible),
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
            titleSpacing: 0,
            title: _AppBarTitle(
              title: p.activeConversation?.title ?? 'New chat',
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
            fileMcpEnabled: p.fileMcpEnabled,
            fileMcpFolder: p.fileMcpFolder,
            onPickFolder: p.setFileMcpFolder,
            onClearFolder: () => p.setFileMcpFolder(null),
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
  Widget build(BuildContext context) => _ChatTitle(title: title);
}

/// Chat title with the active personality underneath. Tapping it lets the
/// user switch personality (only possible before the first message).
class _ChatTitle extends StatelessWidget {
  final String title;
  const _ChatTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final p = context.watch<AppProvider>();
    final personality = p.activePersonality;
    final conv = p.activeConversation;
    final canChange = conv == null || conv.messages.isEmpty;

    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    if (personality == null) return titleText;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        if (canChange) {
          showPersonalityPicker(context, p);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'This chat uses "${personality.name}". Start a new chat to pick a different personality.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            titleText,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.person_outline_rounded,
                    size: 13, color: cs.onSurfaceVariant),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    personality.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                if (canChange)
                  Icon(Icons.arrow_drop_down_rounded,
                      size: 16, color: cs.onSurfaceVariant),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Desktop chat header ───────────────────────────────────────────────────────

class _DesktopChatHeader extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  final Color? bgColor;
  final bool sidebarVisible;
  final VoidCallback onToggleSidebar;

  const _DesktopChatHeader({
    required this.title,
    required this.actions,
    required this.sidebarVisible,
    required this.onToggleSidebar,
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
            IconButton(
              icon: Icon(sidebarVisible
                  ? Icons.menu_open_rounded
                  : Icons.menu_rounded),
              tooltip: sidebarVisible ? 'Hide sidebar' : 'Show sidebar',
              onPressed: onToggleSidebar,
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _ChatTitle(title: title),
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
          return const _EmptyState();
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
              onRegenerate: p.isStreaming
                  ? null
                  : () => p.regenerateFrom(msg),
            );
          },
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  static const _suggestions = <(IconData, String, String)>[
    (
      Icons.mail_outline_rounded,
      'Write an email',
      'Help me write an email. First ask me who it is for and what it should say.'
    ),
    (
      Icons.lightbulb_outline_rounded,
      'Explain something',
      'Explain something to me in simple words. First ask me what I would like to understand.'
    ),
    (
      Icons.notes_rounded,
      'Summarize a text',
      'I would like you to summarize a text for me. I will paste it in my next message.'
    ),
    (
      Icons.checklist_rounded,
      'Plan something',
      'Help me plan something step by step. First ask me what I want to plan.'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Consumer<AppProvider>(
      builder: (context, p, _) {
        final personality = p.activePersonality;
        final personalities = p.settings.personalities;
        final conn = connectionState(p);

        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome_rounded,
                      size: 56, color: cs.primary.withValues(alpha: 0.7)),
                  const SizedBox(height: 16),
                  Text(
                    conn == ConnState.notSetUp
                        ? 'Welcome to LoomChat'
                        : 'How can I help you today?',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(color: cs.onSurface),
                  ),
                  const SizedBox(height: 16),

                  if (conn == ConnState.notSetUp) ...[
                    Text(
                      'LoomChat needs to be connected to an AI before you can chat.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const SettingsScreen()),
                      ),
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('Set up connection'),
                    ),
                  ] else ...[
                    // ── Personality picker ─────────────────────────────
                    if (personalities.isNotEmpty)
                      ActionChip(
                        avatar: Icon(Icons.person_outline_rounded,
                            size: 18, color: cs.primary),
                        label: Text(
                          personalities.length > 1
                              ? 'Personality: ${personality?.name ?? 'none'}  ▾'
                              : 'Personality: ${personality?.name ?? 'none'}',
                        ),
                        onPressed: () => showPersonalityPicker(context, p),
                      ),
                    const SizedBox(height: 24),
                    // ── Suggestions ────────────────────────────────────
                    // Max width fits two cards per row → a tidy 2×2 grid.
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final s in _suggestions)
                            _SuggestionCard(
                              icon: s.$1,
                              label: s.$2,
                              onTap: () => p.sendMessage(s.$3),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Or just type your question below.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SuggestionCard(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SizedBox(
      width: 150,
      child: Material(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: cs.primary),
                const SizedBox(height: 8),
                Text(label,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet for choosing the personality of the current (empty) chat.
void showPersonalityPicker(BuildContext context, AppProvider p) {
  final personalities = p.settings.personalities;
  final current = p.activePersonality?.id;

  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('Who should you talk to?',
                      style: Theme.of(ctx).textTheme.titleMedium),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const PersonalitySettingsScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit personalities'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final personality in personalities)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          Theme.of(ctx).colorScheme.primaryContainer,
                      radius: 18,
                      child: Text(
                        personality.name.isNotEmpty
                            ? personality.name[0].toUpperCase()
                            : '?',
                        style: TextStyle(
                          color: Theme.of(ctx).colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(personality.name),
                    subtitle: personality.systemPrompt.trim().isEmpty
                        ? null
                        : Text(
                            personality.systemPrompt,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: personality.id == current
                        ? Icon(Icons.check_circle_rounded,
                            color: Theme.of(ctx).colorScheme.primary)
                        : null,
                    onTap: () {
                      p.setConversationPersonality(personality.id);
                      Navigator.pop(ctx);
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

class _ErrorBanner extends StatefulWidget {
  final String error;
  final VoidCallback onDismiss;

  const _ErrorBanner({required this.error, required this.onDismiss});

  @override
  State<_ErrorBanner> createState() => _ErrorBannerState();
}

class _ErrorBannerState extends State<_ErrorBanner> {
  bool _showDetails = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fe = friendlyError(widget.error);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      color: cs.errorContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.error_outline,
                    color: cs.onErrorContainer, size: 18),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  fe.message,
                  style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                icon: Icon(Icons.close, color: cs.onErrorContainer, size: 18),
                onPressed: widget.onDismiss,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 18),
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: cs.onErrorContainer,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => setState(() => _showDetails = !_showDetails),
              child: Text(_showDetails ? 'Hide details' : 'Show details'),
            ),
          ),
          if (_showDetails)
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 0, 8, 4),
              child: SelectableText(
                fe.details,
                style: TextStyle(
                  color: cs.onErrorContainer.withValues(alpha: 0.8),
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Connection status button (only shown when something needs attention) ────

class _ConnectionButton extends StatelessWidget {
  const _ConnectionButton();

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final cs = Theme.of(context).colorScheme;
    final conn = connectionState(p);
    if (conn == ConnState.ok) return const SizedBox.shrink();

    final (IconData icon, Color color) = switch (conn) {
      ConnState.away => (Icons.travel_explore_rounded, cs.primary),
      ConnState.offline => (Icons.cloud_off_rounded, cs.error),
      _ => (Icons.link_off_rounded, cs.error),
    };

    return IconButton(
      tooltip: connectionTitle(conn, backend: p.settings.useBackend),
      icon: Icon(icon, color: color),
      onPressed: () => _showSheet(context, p, conn),
    );
  }

  void _showSheet(BuildContext context, AppProvider p, ConnState conn) {
    final backend = p.settings.useBackend;
    final String explanation = switch (conn) {
      ConnState.away =>
        "You're away from your home network, so LoomChat is using your "
            'away-from-home address. Everything works as usual.',
      ConnState.offline =>
        "LoomChat can't reach your server right now. Check that you're "
            'online and that the server is running.',
      _ => 'LoomChat is not connected to an AI yet. Open the settings to set it up.',
    };

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(connectionTitle(conn, backend: backend),
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(explanation),
              const SizedBox(height: 20),
              if (conn != ConnState.notSetUp)
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    if (backend) {
                      p.backendReconnect();
                    } else {
                      p.recheckNetwork();
                    }
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Check again'),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                },
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Open settings'),
              ),
            ],
          ),
        ),
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

class _ConversationListView extends StatefulWidget {
  /// When true, tapping a conversation calls Navigator.pop to close the drawer.
  final bool closeDrawer;
  const _ConversationListView({required this.closeDrawer});

  @override
  State<_ConversationListView> createState() => _ConversationListViewState();
}

class _ConversationListViewState extends State<_ConversationListView> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Consumer<AppProvider>(
      builder: (_, p, __) {
        final allVisible = p.visibleConversations;
        final q = _query.trim().toLowerCase();
        final visible = q.isEmpty
            ? allVisible
            : allVisible
                .where((c) => c.title.toLowerCase().contains(q))
                .toList();

        // Interleave date headings ("Today", "Yesterday", …) with chats.
        final entries = <Object>[];
        String? lastGroup;
        for (final c in visible) {
          final g = _dateGroup(c.updatedAt);
          if (g != lastGroup) {
            entries.add(g);
            lastGroup = g;
          }
          entries.add(c);
        }

        return Column(
          children: [
            // ── Search field ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: TextField(
                controller: _searchController,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Search chats…',
                  hintStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: cs.surfaceContainerHigh,
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            // ── Conversation list ──────────────────────────────────────────
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Text(
                        q.isEmpty ? 'No conversations yet' : 'No results',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: entries.length,
                      itemBuilder: (_, i) {
                        final entry = entries[i];
                        if (entry is String) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
                            child: Text(
                              entry,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(
                                    color: cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          );
                        }
                        final conv = entry as Conversation;
                        final isActive = conv.id == p.activeConversation?.id;
                        return _ConversationTile(
                          conv: conv,
                          isActive: isActive,
                          showSecretBadge: p.secretsUnlocked && conv.isSecret,
                          onTap: () {
                            p.selectConversation(conv);
                            if (widget.closeDrawer) Navigator.pop(context);
                          },
                          onDelete: () => p.deleteConversation(conv.id),
                          onRename: (title) =>
                              p.renameConversation(conv.id, title),
                          onToggleSecret: p.hasSecretPassword &&
                                  p.secretsUnlocked
                              ? () => p.toggleConversationSecret(conv.id)
                              : null,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

String _dateGroup(DateTime utcOrLocal) {
  final t = utcOrLocal.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return 'Previous 7 days';
  if (diff < 30) return 'Previous 30 days';
  return 'Older';
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
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) => onDelete(),
      child: GestureDetector(
        onSecondaryTap: () => _showContextSheet(context),
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
          tooltip: 'More options',
          icon: Icon(Icons.more_horiz_rounded,
              size: 20, color: cs.onSurfaceVariant),
          onPressed: () => _showContextSheet(context),
          visualDensity: VisualDensity.compact,
        ),
      ),
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this chat?'),
        content: Text('"${conv.title}" will be removed permanently.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _showRenameDialog(BuildContext context) async {
    final ctrl = TextEditingController(text: conv.title);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename chat'),
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
              title: const Text('Colour of my messages'),
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
              title: const Text('Colour of AI messages'),
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
              title: Text('Delete chat', style: TextStyle(color: cs.error)),
              onTap: () async {
                Navigator.pop(outerContext);
                if (await _confirmDelete(outerContext)) onDelete();
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

// ── Tools button ──────────────────────────────────────────────────────────────
//
// Tap → a small menu with one main switch ("Use tools") and a switch per
// tool server, plus a link to the tools settings.

class _McpToggleButton extends StatelessWidget {
  const _McpToggleButton();

  void _showServerMenu(BuildContext context) {
    final p = context.read<AppProvider>();
    final servers = p.settings.mcpServers
        .where((s) => s.baseUrlHome.isNotEmpty)
        .toList();

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
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 340),
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
        return IconButton(
          tooltip: p.mcpActive ? 'Tools are on' : 'Tools are off',
          icon: Icon(
            p.mcpActive ? Icons.handyman_rounded : Icons.handyman_outlined,
            color: p.mcpActive
                ? cs.primary
                : cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          onPressed: () => _showServerMenu(context),
        );
      },
    );
  }
}

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

  @override
  double get height => servers.length * 48.0 + 140;

  @override
  bool represents(Never? value) => false;

  @override
  State<_McpServersMenuEntry> createState() => _McpServersMenuEntryState();
}

class _McpServersMenuEntryState extends State<_McpServersMenuEntry> {
  late List<McpServer> _servers;
  late bool _active;

  @override
  void initState() {
    super.initState();
    _servers = List.of(widget.servers);
    _active = widget.provider.mcpActive;
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
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('Use tools'),
          subtitle: const Text('Let the AI search the web, remember things and more'),
          value: _active,
          onChanged: (v) {
            setState(() => _active = v);
            if (widget.provider.mcpActive != v) widget.provider.toggleMcp();
          },
        ),
        if (_servers.isNotEmpty) ...[
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.6)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Text(
              'Available tools',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          for (final server in _servers)
            SwitchListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Text(
                server.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _active ? null : cs.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              value: server.enabled,
              onChanged: _active ? (v) => _toggle(server.id, v) : null,
            ),
        ],
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.6)),
        ListTile(
          dense: true,
          leading: const Icon(Icons.settings_outlined, size: 20),
          title: const Text('Manage tools…'),
          onTap: () {
            final nav = Navigator.of(context);
            nav.pop();
            nav.push(
              MaterialPageRoute(builder: (_) => const McpServersScreen()),
            );
          },
        ),
      ],
    );
  }
}
