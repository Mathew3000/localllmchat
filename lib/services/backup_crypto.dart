import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// AES-256-GCM backup encryption with PBKDF2-SHA256 key derivation.
///
/// Wire format (a JSON envelope):
/// ```json
/// {
///   "encrypted": true,
///   "version":   1,
///   "kdf":       "pbkdf2-sha256",
///   "iterations": 100000,
///   "salt":      "<base64-16-bytes>",
///   "nonce":     "<base64-12-bytes>",
///   "mac":       "<base64-16-bytes>",
///   "ciphertext":"<base64>"
/// }
/// ```
class BackupCrypto {
  BackupCrypto._();

  static const int _iterations = 100000;
  static const int _saltLen = 16;

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Returns true when [json] is an encrypted backup envelope.
  static bool isEncrypted(String json) {
    try {
      final data = jsonDecode(json);
      return data is Map && data['encrypted'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Encrypts [plainJson] with [password], returning the envelope JSON.
  static Future<String> encrypt(String plainJson, String password) async {
    final salt = _randomBytes(_saltLen);
    final key = await _deriveKey(password, salt);
    final algo = AesGcm.with256bits();
    final sk = await algo.newSecretKeyFromBytes(key);
    final box = await algo.encrypt(utf8.encode(plainJson), secretKey: sk);
    return jsonEncode({
      'encrypted': true,
      'version': 1,
      'kdf': 'pbkdf2-sha256',
      'iterations': _iterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'ciphertext': base64Encode(box.cipherText),
    });
  }

  /// Decrypts an encrypted backup envelope using [password].
  ///
  /// Throws [ArgumentError] with message `'wrong_password'` on auth failure,
  /// or [FormatException] if the envelope is malformed.
  static Future<String> decrypt(String envelopeJson, String password) async {
    late Map<String, dynamic> data;
    try {
      data = jsonDecode(envelopeJson) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Invalid backup file format');
    }

    final salt = base64Decode(data['salt'] as String);
    final nonce = base64Decode(data['nonce'] as String);
    final mac = Mac(base64Decode(data['mac'] as String));
    final ciphertext = base64Decode(data['ciphertext'] as String);
    final iters = data['iterations'] as int? ?? _iterations;

    final key = await _deriveKey(password, salt, iterations: iters);
    final algo = AesGcm.with256bits();
    final sk = await algo.newSecretKeyFromBytes(key);
    final box = SecretBox(ciphertext, nonce: nonce, mac: mac);

    try {
      final plain = await algo.decrypt(box, secretKey: sk);
      return utf8.decode(plain);
    } on SecretBoxAuthenticationError {
      throw ArgumentError('wrong_password');
    }
  }

  // ── Internals ───────────────────────────────────────────────────────────────

  static Future<List<int>> _deriveKey(
    String password,
    List<int> salt, {
    int iterations = _iterations,
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

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  }
}
