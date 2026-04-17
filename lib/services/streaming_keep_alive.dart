import 'package:flutter/services.dart';

/// Thin wrapper around the Android foreground-service + wake-lock that keeps
/// the LLM stream alive when the screen turns off or the app is backgrounded.
///
/// On non-Android platforms the calls are silently ignored.
class StreamingKeepAlive {
  StreamingKeepAlive._();

  static const _channel =
      MethodChannel('com.local.local_llm_chat/streaming');

  /// Start the foreground service.  Call this just before opening the stream.
  static Future<void> start() async {
    try {
      await _channel.invokeMethod<void>('start');
    } on MissingPluginException {
      // Not on Android (e.g. running on desktop/web in tests) — ignore.
    } catch (_) {
      // Best-effort: don't let a service failure break the chat.
    }
  }

  /// Stop the foreground service.  Call this when streaming ends or is cancelled.
  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // ignore
    } catch (_) {
      // ignore
    }
  }
}
