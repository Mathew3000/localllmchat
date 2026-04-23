import 'dart:io';

/// Singleton that writes raw HTTP traffic to a plain-text log file.
///
/// Enabled / disabled via Settings → Debug.  Each app session opens a new
/// timestamped file in the user-selected folder.  All writes are fire-and-
/// forget (async flush); the logger never throws — failures are swallowed
/// silently so a broken path doesn't crash the app.
class DebugLogger {
  DebugLogger._();
  static final DebugLogger instance = DebugLogger._();

  bool _enabled = false;
  String _folderPath = '';
  IOSink? _sink;
  String? _currentFile;

  bool get enabled => _enabled;
  String get folderPath => _folderPath;

  /// Base name of the currently-open log file, or null when not logging.
  String? get currentFile =>
      _currentFile?.split(Platform.pathSeparator).last;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  Future<void> init({required bool enabled, required String folderPath}) async {
    await _close();
    _enabled = enabled;
    _folderPath = folderPath;
    if (enabled && folderPath.isNotEmpty) await _open();
  }

  Future<void> _open() async {
    try {
      final dir = Directory(_folderPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final now = DateTime.now().toUtc();
      final stamp = '${now.year}${_p(now.month)}${_p(now.day)}'
          '_${_p(now.hour)}${_p(now.minute)}${_p(now.second)}';
      _currentFile = [_folderPath, 'localllmchat_$stamp.log']
          .join(Platform.pathSeparator);
      _sink = File(_currentFile!).openWrite();
      _w('LocalLLMChat Debug Log\n');
      _w('Session started: ${now.toIso8601String()}\n');
      _w('${'═' * 80}\n\n');
      await _sink!.flush();
    } catch (_) {
      _sink = null;
      _currentFile = null;
    }
  }

  Future<void> _close() async {
    if (_sink == null) return;
    try {
      _w('\nSession ended: ${_ts()}\n');
      await _sink!.flush();
      await _sink!.close();
    } catch (_) {}
    _sink = null;
    _currentFile = null;
  }

  // ── Public logging API ─────────────────────────────────────────────────────

  /// Log an outgoing HTTP request.
  void logRequest(String tag, String method, String url, String body) {
    if (_sink == null) return;
    _w('[${_ts()}] ──→ $tag  $method $url\n');
    _w('${'─' * 60}\n$body\n\n');
    _flush();
  }

  /// Log an HTTP response (or accumulated SSE stream).
  void logResponse(String tag, String url, int? statusCode, String body) {
    if (_sink == null) return;
    final sc = statusCode != null ? '  HTTP $statusCode' : '';
    _w('[${_ts()}] ←──$sc $tag  $url\n');
    _w('${'─' * 60}\n$body\n\n');
    _flush();
  }

  /// Log an error (e.g. connection failure, non-200 status).
  void logError(String tag, String url, Object error) {
    if (_sink == null) return;
    _w('[${_ts()}] ✕  $tag  $url\n');
    _w('${'─' * 60}\nERROR: $error\n\n');
    _flush();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _w(String s) {
    try {
      _sink?.write(s);
    } catch (_) {}
  }

  void _flush() {
    try {
      _sink?.flush();
    } catch (_) {}
  }

  String _ts() => DateTime.now().toIso8601String();
  static String _p(int n) => n.toString().padLeft(2, '0');
}
