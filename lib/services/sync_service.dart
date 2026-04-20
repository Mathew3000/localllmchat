import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

// ── Sync status ───────────────────────────────────────────────────────────────

enum SyncStatus { idle, syncing, error }

// ── Crypto ────────────────────────────────────────────────────────────────────

/// Per-session AES-256-GCM cipher for sync payloads.
///
/// The key is derived once at login via [SyncCrypto.deriveKey] (PBKDF2-SHA256,
/// 100 000 iterations) and kept in memory — never written to disk.
///
/// Each blob is encrypted with a fresh random nonce; the compact wire format is:
/// `{"v":1,"n":"<base64-nonce>","m":"<base64-mac>","c":"<base64-ciphertext>"}`
class SyncCrypto {
  final Uint8List keyBytes;

  const SyncCrypto._(this.keyBytes);

  /// Constructs a [SyncCrypto] from a previously derived key (e.g., restored
  /// from in-memory storage by [AppProvider]).
  factory SyncCrypto.fromKey(Uint8List key) => SyncCrypto._(key);

  // ── Key derivation ─────────────────────────────────────────────────────────

  /// Derives the auth hash sent to the server on register/login.
  /// The server bcrypt's this — plaintext never touches the wire.
  static Future<String> deriveAuthHash(
      String password, String username) async {
    final key = await _pbkdf2(
      password: password,
      salt: utf8.encode('$username:auth:v1'),
    );
    return base64Encode(key);
  }

  /// Derives the in-memory encryption key for sync blobs.
  /// Uses a different context string than [deriveAuthHash] so the two keys
  /// are independent even when the same password is used.
  static Future<SyncCrypto> fromCredentials(
      String password, String username) async {
    final key = await _pbkdf2(
      password: password,
      salt: utf8.encode('$username:enc:v1'),
    );
    return SyncCrypto._(Uint8List.fromList(key));
  }

  static Future<List<int>> _pbkdf2({
    required String password,
    required List<int> salt,
    int iterations = 100000,
  }) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final dk = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return dk.extractBytes();
  }

  // ── Encrypt / decrypt ──────────────────────────────────────────────────────

  Future<String> encrypt(String plaintext) async {
    final algo = AesGcm.with256bits();
    final sk = await algo.newSecretKeyFromBytes(keyBytes);
    final nonce = _randomBytes(12);
    final box = await algo.encrypt(
      utf8.encode(plaintext),
      secretKey: sk,
      nonce: nonce,
    );
    return jsonEncode({
      'v': 1,
      'n': base64Encode(box.nonce),
      'm': base64Encode(box.mac.bytes),
      'c': base64Encode(box.cipherText),
    });
  }

  Future<String> decrypt(String blobJson) async {
    late Map<String, dynamic> data;
    try {
      data = jsonDecode(blobJson) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Sync blob is not valid JSON');
    }
    final nonce = base64Decode(data['n'] as String);
    final mac = Mac(base64Decode(data['m'] as String));
    final ciphertext = base64Decode(data['c'] as String);

    final algo = AesGcm.with256bits();
    final sk = await algo.newSecretKeyFromBytes(keyBytes);
    final box = SecretBox(ciphertext, nonce: nonce, mac: mac);
    try {
      final plain = await algo.decrypt(box, secretKey: sk);
      return utf8.decode(plain);
    } on SecretBoxAuthenticationError {
      throw ArgumentError('wrong_key');
    }
  }

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  }
}

// ── Response models ───────────────────────────────────────────────────────────

class AuthResult {
  final String userId;
  final String accessToken;
  final String refreshToken;

  const AuthResult({
    required this.userId,
    required this.accessToken,
    required this.refreshToken,
  });

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        userId: j['user_id'] as String,
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
      );
}

class ConvMeta {
  final String id;
  final DateTime updatedAt;
  final bool deleted;

  const ConvMeta(
      {required this.id, required this.updatedAt, required this.deleted});

  factory ConvMeta.fromJson(Map<String, dynamic> j) => ConvMeta(
        id: j['id'] as String,
        updatedAt: DateTime.parse(j['updated_at'] as String),
        deleted: j['deleted'] as bool? ?? false,
      );
}

class SyncStateResult {
  final List<ConvMeta> conversations;
  final DateTime? settingsUpdatedAt;

  const SyncStateResult(
      {required this.conversations, this.settingsUpdatedAt});

  factory SyncStateResult.fromJson(Map<String, dynamic> j) => SyncStateResult(
        conversations: (j['conversations'] as List<dynamic>)
            .map((e) => ConvMeta.fromJson(e as Map<String, dynamic>))
            .toList(),
        settingsUpdatedAt:
            (j['settings_updated_at'] as String?)?.isNotEmpty == true
                ? DateTime.parse(j['settings_updated_at'] as String)
                : null,
      );
}

class ConvBlobResult {
  final String id;
  final String encryptedBlob;
  final DateTime updatedAt;

  const ConvBlobResult(
      {required this.id,
      required this.encryptedBlob,
      required this.updatedAt});

  factory ConvBlobResult.fromJson(Map<String, dynamic> j) => ConvBlobResult(
        id: j['id'] as String,
        encryptedBlob: j['encrypted_blob'] as String,
        updatedAt: DateTime.parse(j['updated_at'] as String),
      );
}

class SettingsBlobResult {
  final String encryptedBlob;
  final DateTime updatedAt;

  const SettingsBlobResult(
      {required this.encryptedBlob, required this.updatedAt});

  factory SettingsBlobResult.fromJson(Map<String, dynamic> j) =>
      SettingsBlobResult(
        encryptedBlob: j['encrypted_blob'] as String,
        updatedAt: DateTime.parse(j['updated_at'] as String),
      );
}

// ── Service ───────────────────────────────────────────────────────────────────

/// HTTP client for the LocalLLMChat sync server.
///
/// Tokens are refreshed automatically when an access token expires.
/// [onTokensRefreshed] is called whenever new tokens are issued so the caller
/// can persist them.
class SyncService {
  final String serverUrl;
  String _accessToken;
  String _refreshToken;
  final Future<void> Function(String access, String refresh) onTokensRefreshed;

  SyncService({
    required this.serverUrl,
    required String accessToken,
    required String refreshToken,
    required this.onTokensRefreshed,
  })  : _accessToken = accessToken,
        _refreshToken = refreshToken;

  // ── Static auth ───────────────────────────────────────────────────────────

  /// Registers a new account. Derives [authHash] from [password] before sending
  /// — the plaintext password never leaves the device.
  static Future<AuthResult> register(
      String serverUrl, String username, String password) async {
    final authHash = await SyncCrypto.deriveAuthHash(password, username);
    final resp = await http.post(
      Uri.parse('$serverUrl/api/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'auth_hash': authHash}),
    );
    _checkStatus(resp, 201);
    return AuthResult.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Logs in to an existing account.
  static Future<AuthResult> login(
      String serverUrl, String username, String password) async {
    final authHash = await SyncCrypto.deriveAuthHash(password, username);
    final resp = await http.post(
      Uri.parse('$serverUrl/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'auth_hash': authHash}),
    );
    _checkStatus(resp, 200);
    return AuthResult.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  // ── Sync API ──────────────────────────────────────────────────────────────

  Future<SyncStateResult> getState() async {
    final resp = await _get('/api/sync/state');
    return SyncStateResult.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<ConvBlobResult> getConversation(String id) async {
    final resp = await _get('/api/sync/conversations/$id');
    return ConvBlobResult.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> putConversation(
      String id, String encryptedBlob, DateTime updatedAt) async {
    await _put('/api/sync/conversations/$id', {
      'encrypted_blob': encryptedBlob,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    });
  }

  Future<void> deleteConversation(String id) async {
    await _delete('/api/sync/conversations/$id');
  }

  /// Returns null when no settings have been synced yet.
  Future<SettingsBlobResult?> getSettings() async {
    try {
      final resp = await _get('/api/sync/settings');
      return SettingsBlobResult.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>);
    } on SyncException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> putSettings(String encryptedBlob, DateTime updatedAt) async {
    await _put('/api/sync/settings', {
      'encrypted_blob': encryptedBlob,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    });
  }

  // ── HTTP helpers ──────────────────────────────────────────────────────────

  Future<http.Response> _get(String path) async {
    var resp = await http.get(
      Uri.parse('$serverUrl$path'),
      headers: _authHeaders(),
    );
    if (resp.statusCode == 401) {
      await _refreshTokens();
      resp = await http.get(
        Uri.parse('$serverUrl$path'),
        headers: _authHeaders(),
      );
    }
    _checkStatus(resp, 200);
    return resp;
  }

  Future<http.Response> _put(String path, Map<String, dynamic> body) async {
    var resp = await http.put(
      Uri.parse('$serverUrl$path'),
      headers: _authHeaders()..['Content-Type'] = 'application/json',
      body: jsonEncode(body),
    );
    if (resp.statusCode == 401) {
      await _refreshTokens();
      resp = await http.put(
        Uri.parse('$serverUrl$path'),
        headers: _authHeaders()..['Content-Type'] = 'application/json',
        body: jsonEncode(body),
      );
    }
    _checkStatus(resp, 200);
    return resp;
  }

  Future<void> _delete(String path) async {
    var resp = await http.delete(
      Uri.parse('$serverUrl$path'),
      headers: _authHeaders(),
    );
    if (resp.statusCode == 401) {
      await _refreshTokens();
      resp = await http.delete(
        Uri.parse('$serverUrl$path'),
        headers: _authHeaders(),
      );
    }
    if (resp.statusCode != 204 && resp.statusCode != 200) {
      throw SyncException(resp.statusCode,
          _errorMessage(resp) ?? 'HTTP ${resp.statusCode}');
    }
  }

  Future<void> _refreshTokens() async {
    final resp = await http.post(
      Uri.parse('$serverUrl/api/auth/refresh'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': _refreshToken}),
    );
    if (resp.statusCode != 200) {
      throw const SyncAuthExpiredException();
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    _accessToken = data['access_token'] as String;
    _refreshToken = data['refresh_token'] as String;
    await onTokensRefreshed(_accessToken, _refreshToken);
  }

  Map<String, String> _authHeaders() =>
      {'Authorization': 'Bearer $_accessToken'};

  static void _checkStatus(http.Response resp, int expected) {
    if (resp.statusCode != expected) {
      throw SyncException(
          resp.statusCode, _errorMessage(resp) ?? 'HTTP ${resp.statusCode}');
    }
  }

  static String? _errorMessage(http.Response resp) {
    try {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return body['error'] as String?;
    } catch (_) {
      return null;
    }
  }
}

// ── Exceptions ────────────────────────────────────────────────────────────────

class SyncException implements Exception {
  final int statusCode;
  final String message;
  const SyncException(this.statusCode, this.message);
  @override
  String toString() => 'SyncException($statusCode): $message';
}

/// Thrown when the refresh token has expired; the user must log in again.
class SyncAuthExpiredException implements Exception {
  const SyncAuthExpiredException();
  @override
  String toString() => 'Sync session expired — please log in again.';
}
