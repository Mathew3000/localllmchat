// Plain-language helpers: turn technical state (raw exceptions, model file
// names, connection flags) into text a non-technical user can understand.

import '../providers/app_provider.dart';

/// A user-facing explanation of an error, plus the raw text for "Details".
class FriendlyError {
  final String message;
  final String details;
  const FriendlyError(this.message, this.details);
}

FriendlyError friendlyError(String raw) {
  final s = raw.toLowerCase();
  bool has(List<String> needles) => needles.any(s.contains);

  String msg;
  if (has(['peer closed connection', 'incomplete chunked', 'connection closed',
      'remoteprotocolerror'])) {
    msg = 'The AI server stopped in the middle of its reply. '
        'If this keeps happening, choose a shorter reply length in Settings.';
  } else if (has(['timeoutexception', 'timed out', 'timeout'])) {
    msg = 'The AI took too long to answer. Try again, or allow more '
        'waiting time in Settings → Advanced.';
  } else if (has(['certificate', 'handshakeexception', 'ssl', 'tls'])) {
    msg = 'A secure connection to the server could not be made. If your '
        'server uses its own certificate, allow it in Settings → Connection.';
  } else if (has(['socketexception', 'connection refused', 'failed host lookup',
      'network is unreachable', 'no route to host', 'connection failed',
      'connecterror', 'cannot reach'])) {
    msg = "Can't reach the AI server. Check that it is running and that "
        "you're connected to the right network.";
  } else if (has(['401', '403', 'unauthorized', 'forbidden', 'api key',
      'invalid token', 'not authenticated'])) {
    msg = 'The server refused access. Check your sign-in or API key in Settings.';
  } else if (has(['context length', 'context window', 'maximum context',
      'too many tokens', 'context_length'])) {
    msg = 'This chat has become too long for the AI to remember. '
        'Start a new chat to continue.';
  } else if (has(['model not found', 'no such model', 'model_not_found'])) {
    msg = "The selected AI model isn't available. Pick another one in Settings.";
  } else if (has(['404'])) {
    msg = "The server address doesn't look right. Check it in Settings → Connection.";
  } else if (has(['500', '502', '503', 'internal server error', 'bad gateway',
      'service unavailable'])) {
    msg = 'The AI server ran into a problem. Please try again in a moment.';
  } else {
    msg = 'Something went wrong while talking to the AI.';
  }
  return FriendlyError(msg, raw);
}

/// Pulls the raw error out of an assistant message like "[Error: …]".
/// Returns null if the message is not an error message.
String? extractInlineError(String content) {
  final m = RegExp(r'^\s*\[Error: ([\s\S]*)\]\s*$').firstMatch(content);
  return m?.group(1);
}

/// "Qwen/Qwen3-30B-A3B-Instruct-Q4_K_M.gguf" → "Qwen3-30B-A3B-Instruct-Q4_K_M"
String friendlyModelName(String model) {
  if (model.isEmpty) return '';
  var name = model.split(RegExp(r'[\\/]')).last;
  name = name.replaceAll(RegExp(r'\.(gguf|bin|safetensors)$', caseSensitive: false), '');
  return name;
}

enum ConnState { ok, away, offline, notSetUp }

/// One simple answer to "is the app able to reach the AI right now?".
ConnState connectionState(AppProvider p) {
  final s = p.settings;
  if (s.useBackend) {
    if (s.backendToken.isEmpty) return ConnState.notSetUp;
    if (!p.backendConnected) return ConnState.offline;
    return p.backendUsingAway && s.backendAwayUrl.isNotEmpty
        ? ConnState.away
        : ConnState.ok;
  }
  if (s.baseUrlHome.isEmpty) return ConnState.notSetUp;
  return p.usingAwayUrl && s.baseUrlAway.isNotEmpty
      ? ConnState.away
      : ConnState.ok;
}

String connectionTitle(ConnState c, {required bool backend}) {
  switch (c) {
    case ConnState.ok:
      return backend ? 'Connected to your LoomChat server' : 'Connected to your AI server';
    case ConnState.away:
      return 'Connected (away from home)';
    case ConnState.offline:
      return "Can't reach your LoomChat server";
    case ConnState.notSetUp:
      return 'Not set up yet';
  }
}
