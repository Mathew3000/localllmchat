import 'package:uuid/uuid.dart';
import 'message.dart';

class Conversation {
  final String id;
  String title;
  final List<Message> messages;
  final DateTime createdAt;
  DateTime updatedAt;
  bool isSecret;
  /// Bubble colour for user messages (ARGB int). Null = theme default.
  int? userBubbleColor;
  /// Bubble colour for assistant messages (ARGB int). Null = theme default.
  int? assistantBubbleColor;
  /// Last known prompt-token count for this conversation.  Persisted so the
  /// context-usage ring survives restarts and syncs across devices.
  int? lastPromptTokens;

  Conversation({
    String? id,
    String? title,
    List<Message>? messages,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isSecret = false,
    this.userBubbleColor,
    this.assistantBubbleColor,
    this.lastPromptTokens,
  })  : id = id ?? const Uuid().v4(),
        title = title ?? 'New Chat',
        messages = messages ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'messages': messages.map((m) => m.toStorageJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'isSecret': isSecret,
        'userBubbleColor': userBubbleColor,
        'assistantBubbleColor': assistantBubbleColor,
        'lastPromptTokens': lastPromptTokens,
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String,
        title: json['title'] as String,
        messages: (json['messages'] as List<dynamic>)
            .map((m) => Message.fromStorageJson(m as Map<String, dynamic>))
            .toList(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        isSecret: json['isSecret'] as bool? ?? false,
        userBubbleColor: json['userBubbleColor'] as int?,
        assistantBubbleColor: json['assistantBubbleColor'] as int?,
        lastPromptTokens: json['lastPromptTokens'] as int?,
      );

  String get preview {
    final userMessages = messages.where((m) => m.role == Role.user);
    if (userMessages.isEmpty) return 'Empty chat';
    final first = userMessages.first.content;
    return first.length > 60 ? '${first.substring(0, 60)}…' : first;
  }
}
