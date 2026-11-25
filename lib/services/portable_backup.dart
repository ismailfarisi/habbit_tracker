import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';

/// Version 1 is Argon2id (v19, 19 MiB, two iterations, one lane, 32 bytes)
/// and AES-256-GCM. The box is nonce || ciphertext || 16-byte tag. No
/// user-controlled KDF parameters; a new salt and nonce are generated per file.
class PortableBackup {
  static const _app = 'daily-discipline-encrypted';
  static const _version = 1;
  static final _aad = utf8.encode('$_app/$_version');
  static final _cipher = AesGcm.with256bits();

  static bool isEncrypted(String raw) {
    try {
      final value = jsonDecode(raw);
      return value is Map && value['app'] == _app;
    } on FormatException {
      return false;
    }
  }

  static Future<SecretKey> _key(String password, List<int> salt) async {
    final secret = SecretKeyData(utf8.encode(password), overwriteWhenDestroyed: true);
    try {
      return await Argon2id(
        memory: 19 * 1024,
        iterations: 2,
        parallelism: 1,
        hashLength: 32,
      ).deriveKey(secretKey: secret, nonce: salt);
    } finally {
      secret.destroy();
    }
  }

  static Future<String> encrypt(String raw, String password) => Isolate.run(() async {
    if (password.trim().length < 10) throw const FormatException('Use a password of at least 10 characters.');
    final salt = SecretKeyData.random(length: 16).bytes;
    final key = await _key(password, salt);
    try {
      final box = await _cipher.encrypt(utf8.encode(raw), secretKey: key, aad: _aad);
      return jsonEncode({
        'app': _app,
        'version': _version,
        'salt': base64Encode(salt),
        'box': base64Encode(box.concatenation()),
      });
    } finally {
      key.destroy();
    }
  });

  static Future<String> decrypt(String raw, String password) => Isolate.run(() async {
    final j = jsonDecode(raw);
    if (j is! Map || j['app'] != _app || j['version'] != _version) {
      throw const FormatException('Unsupported encrypted backup version.');
    }
    try {
      final salt = base64Decode(j['salt'] as String);
      if (salt.length != 16) throw const FormatException();
      final box = SecretBox.fromConcatenation(
        base64Decode(j['box'] as String),
        nonceLength: _cipher.nonceLength,
        macLength: _cipher.macAlgorithm.macLength,
      );
      final key = await _key(password, salt);
      try {
        return utf8.decode(await _cipher.decrypt(box, secretKey: key, aad: _aad));
      } finally {
        key.destroy();
      }
    } on SecretBoxAuthenticationError {
      throw const FormatException('Check the password or choose another copy of the file.');
    } on Object {
      throw const FormatException('The encrypted backup is damaged. Choose another copy.');
    }
  });
}
