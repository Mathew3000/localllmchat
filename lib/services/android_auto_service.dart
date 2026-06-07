import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges Flutter ↔ native Android Auto notification logic.
///
/// On non-Android platforms (or when [isSupported] is false) every call
/// is a no-op so callers don't need platform guards.
class AndroidAutoService {
  AndroidAutoService({
    MethodChannel? channel,
    void Function(String reply)? onReply,
  })  : _channel = channel ??
            const MethodChannel('com.local.local_llm_chat/android_auto'),
        _onReply = onReply;

  final MethodChannel _channel;
  final void Function(String reply)? _onReply;

  bool _initialised = false;

  /// True on Android only.
  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Call once after creating the service to start receiving voice replies.
  void init() {
    if (!isSupported || _initialised) return;
    _initialised = true;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  /// Releases the channel handler; call from [dispose].
  void dispose() {
    if (!isSupported) return;
    _channel.setMethodCallHandler(null);
    _initialised = false;
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Posts a MessagingStyle notification that Android Auto will read aloud.
  ///
  /// [senderName]  Display name of the human sender (shown as context).
  /// [userText]    The user's last message (shown in the conversation bubble).
  /// [replyText]   The LLM's reply — the car TTS reads this out loud.
  /// [timestamp]   Defaults to now.
  Future<void> postMessage({
    required String senderName,
    required String userText,
    required String replyText,
    DateTime? timestamp,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('postMessage', {
        'senderName': senderName,
        'userText': userText,
        'replyText': replyText,
        'timestamp':
            (timestamp ?? DateTime.now()).millisecondsSinceEpoch,
      });
    } on PlatformException catch (e) {
      debugPrint('[AndroidAutoService] postMessage error: $e');
    }
  }

  /// Cancels any active Auto notification.
  Future<void> cancel() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('cancel');
    } on PlatformException catch (e) {
      debugPrint('[AndroidAutoService] cancel error: $e');
    }
  }

  // ── Native → Flutter ──────────────────────────────────────────────────────

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onAutoReply':
        final text = call.arguments as String? ?? '';
        if (text.isNotEmpty) _onReply?.call(text);
      default:
        debugPrint('[AndroidAutoService] Unknown method: ${call.method}');
    }
  }
}
