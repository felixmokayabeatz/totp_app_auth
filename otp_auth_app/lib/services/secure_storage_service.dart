import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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



  static const localVaultSecretKey = 'local_vault_secret';

  static const List<String> _knownKeys = [
    accessTokenKey,
    refreshTokenKey,
    currentUserKey,
    localVaultUserKey,
    userEmailKey,
    userIdKey,
    encryptionKey,
    appPinHashKey,
    localVaultSecretKey,
  ];

  static final SecureStorageService _instance =
      SecureStorageService._internal();
  factory SecureStorageService() => _instance;
  SecureStorageService._internal();

  static const _prefix = 'bls1:';





















  static const _keychain = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock),
  );



  static bool? _keychainUsable;

  Future<bool> _keychainAvailable() async {
    if (_keychainUsable != null) return _keychainUsable!;
    try {


      const probeKey = 'beatzlock_keychain_probe';
      await _keychain.write(key: probeKey, value: 'ok');
      final readBack = await _keychain.read(key: probeKey);
      await _keychain.delete(key: probeKey);
      _keychainUsable = readBack == 'ok';
    } catch (e) {
      debugPrint('Platform keychain unavailable, using encrypted prefs: $e');
      _keychainUsable = false;
    }
    return _keychainUsable!;
  }

  @visibleForTesting
  static void resetKeychainProbeForTest() => _keychainUsable = null;

  Future<void> init() async {


    await Future.wait(_knownKeys.map(_migrateLegacyPreference));
  }


  Future<String> localVaultSecret() async {
    final existing = await read(localVaultSecretKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final random = Random.secure();
    final secret = List<int>.generate(32, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await write(localVaultSecretKey, secret);
    return secret;
  }

  Future<void> write(String key, String value) async {
    if (await _keychainAvailable()) {
      try {
        await _keychain.write(key: key, value: value);


        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(key);
        return;
      } catch (e) {
        debugPrint('Keychain write failed for $key, falling back: $e');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, _encrypt(value));
  }

  Future<String?> read(String key) async {
    if (await _keychainAvailable()) {
      try {
        final value = await _keychain.read(key: key);
        if (value != null) return value;
      } catch (e) {
        debugPrint('Keychain read failed for $key, falling back: $e');
      }
    }



    final legacyValue = await _migrateLegacyPreference(key);
    if (legacyValue == null) return null;

    if (await _keychainAvailable()) {
      try {
        await _keychain.write(key: key, value: legacyValue);
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(key);
        debugPrint('Moved $key into the platform keychain');
      } catch (e) {
        debugPrint('Could not move $key into the keychain: $e');
      }
    }
    return legacyValue;
  }

  Future<void> delete(String key) async {
    if (await _keychainAvailable()) {
      try {
        await _keychain.delete(key: key);
      } catch (e) {
        debugPrint('Keychain delete failed for $key: $e');
      }
    }
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
    List<int> input,
    List<int> keyBytes,
    List<int> nonce,
  ) {


    final prefix = <int>[...keyBytes, ...nonce];
    final output = Uint8List(input.length);
    var written = 0;
    var blockIndex = 0;

    while (written < input.length) {
      final keystreamBlock =
          sha256.convert([...prefix, ...utf8.encode(':$blockIndex')]).bytes;
      for (final byte in keystreamBlock) {
        if (written >= input.length) break;
        output[written] = input[written] ^ byte;
        written++;
      }
      blockIndex++;
    }

    return output;
  }

  static String? _cachedStorageKey;

  String _deriveStorageKey() {



    return _cachedStorageKey ??= _computeStorageKey();
  }

  String _computeStorageKey() {
    final username =
        Platform.environment['USERNAME'] ?? Platform.environment['USER'] ?? '';
    final homeDir = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    final seed =
        'beatzlock_secure_storage_v1|${Platform.operatingSystem}|${Platform.localHostname}|$username|$homeDir';
    return sha256.convert(utf8.encode(seed)).toString();
  }
}
