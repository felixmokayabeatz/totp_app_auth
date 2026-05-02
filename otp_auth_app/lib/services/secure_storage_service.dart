import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SecureStorageService {
  static const accessTokenKey = 'access_token';
  static const refreshTokenKey = 'refresh_token';
  static const currentUserKey = 'current_user';
  static const localVaultUserKey = 'local_vault_user';
  static const userEmailKey = 'user_email';
  static const userIdKey = 'user_id';
  static const encryptionKey = 'encryption_key';
  static const appPinHashKey = 'app_pin_hash';

  static const List<String> _knownKeys = [
    accessTokenKey,
    refreshTokenKey,
    currentUserKey,
    localVaultUserKey,
    userEmailKey,
    userIdKey,
    encryptionKey,
    appPinHashKey,
  ];

  static final SecureStorageService _instance =
      SecureStorageService._internal();
  factory SecureStorageService() => _instance;
  SecureStorageService._internal();

  static const _prefix = 'bls1:';

  Future<void> init() async {
    for (final key in _knownKeys) {
      await _migrateLegacyPreference(key);
    }
  }

  Future<void> write(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, _encrypt(value));
  }

  Future<String?> read(String key) async {
    return _migrateLegacyPreference(key);
  }

  Future<void> delete(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  Future<void> deleteAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in _knownKeys) {
      await prefs.remove(key);
    }
  }

  Future<void> deleteSessionData({
    bool preserveAppPin = true,
    bool preserveLocalVault = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in _knownKeys) {
      if (preserveAppPin && key == appPinHashKey) {
        continue;
      }
      if (preserveLocalVault && key == localVaultUserKey) {
        continue;
      }
      await prefs.remove(key);
    }
  }

  Future<String?> _migrateLegacyPreference(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final storedValue = prefs.getString(key);

    if (storedValue == null) {
      return null;
    }

    if (storedValue.startsWith(_prefix)) {
      try {
        return _decrypt(storedValue);
      } catch (_) {
        await prefs.remove(key);
        return null;
      }
    }

    await prefs.setString(key, _encrypt(storedValue));
    return storedValue;
  }

  String _encrypt(String plainText) {
    final plainBytes = utf8.encode(plainText);
    final nonce = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final keyBytes = utf8.encode(_deriveStorageKey());
    final encrypted = _xorWithKeystream(plainBytes, keyBytes, nonce);
    return '$_prefix${base64Encode([...nonce, ...encrypted])}';
  }

  String _decrypt(String cipherText) {
    final payload = cipherText.substring(_prefix.length);
    final bytes = base64Decode(payload);
    if (bytes.length < 17) {
      throw FormatException('Invalid secure storage payload');
    }

    final nonce = bytes.sublist(0, 16);
    final encrypted = bytes.sublist(16);
    final keyBytes = utf8.encode(_deriveStorageKey());
    final plainBytes = _xorWithKeystream(encrypted, keyBytes, nonce);
    return utf8.decode(plainBytes);
  }

  List<int> _xorWithKeystream(
      List<int> input, List<int> keyBytes, List<int> nonce) {
    final output = <int>[];
    var blockIndex = 0;

    while (output.length < input.length) {
      final keystreamBlock = sha256
          .convert([...keyBytes, ...nonce, ...utf8.encode(':$blockIndex')])
          .bytes;
      for (final byte in keystreamBlock) {
        if (output.length >= input.length) break;
        output.add(input[output.length] ^ byte);
      }
      blockIndex++;
    }

    return output;
  }

  String _deriveStorageKey() {
    final username =
        Platform.environment['USERNAME'] ?? Platform.environment['USER'] ?? '';
    final homeDir =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
    final seed =
        'beatzlock_secure_storage_v1|${Platform.operatingSystem}|${Platform.localHostname}|$username|$homeDir';
    return sha256.convert(utf8.encode(seed)).toString();
  }
}
