

import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

class EncryptionService {
  static String generateKey(String password, String salt) {
    final key = sha256.convert(utf8.encode(password + salt)).toString();
    return key.substring(0, 32);
  }

  static String simpleEncrypt(String plainText, String key) {
    if (plainText.isEmpty) return '';
    final plainBytes = utf8.encode(plainText);
    final keyBytes = utf8.encode(key);
    final encrypted = <int>[];
    for (int i = 0; i < plainBytes.length; i++) {
      encrypted.add(plainBytes[i] ^ keyBytes[i % keyBytes.length]);
    }
    return base64.encode(encrypted);
  }

  static String simpleDecrypt(String cipherText, String key) {
    if (cipherText.isEmpty) return '';
    final encrypted = base64.decode(cipherText);
    final keyBytes = utf8.encode(key);
    final decrypted = <int>[];
    for (int i = 0; i < encrypted.length; i++) {
      decrypted.add(encrypted[i] ^ keyBytes[i % keyBytes.length]);
    }
    return utf8.decode(decrypted);
  }















  static String? _localVaultSecret;

  static void configureLocalVaultSecret(String secret) {
    _localVaultSecret = secret.isEmpty ? null : secret;
  }

  @visibleForTesting
  static void resetLocalVaultSecretForTest() => _localVaultSecret = null;

  static bool get localVaultSecretConfigured => _localVaultSecret != null;

  static String legacyLocalKeyFor(String userId) =>
      generateKey(userId, 'otp_local_encryption_salt');

  static String _localKeyFor(String userId) {
    final secret = _localVaultSecret;
    if (secret == null) return legacyLocalKeyFor(userId);
    return generateKey('$userId|$secret', 'otp_local_encryption_salt_v2');
  }

  static String encryptSecret(String secret, String userId) {
    if (_localVaultSecret == null) {

      return simpleEncrypt(secret, legacyLocalKeyFor(userId));
    }
    return authenticatedEncrypt(
      secret,
      _localKeyFor(userId),
      context: localVaultContext,
    );
  }





  static String decryptSecret(String encryptedSecret, String userId) {



    if (isAuthenticatedPayload(encryptedSecret)) {
      return authenticatedDecrypt(
        encryptedSecret,
        _localKeyFor(userId),
        context: localVaultContext,
      );
    }
    return simpleDecrypt(encryptedSecret, legacyLocalKeyFor(userId));
  }














  static const int passwordKdfIterations = 210000;

  static List<int> pbkdf2(
    List<int> password,
    List<int> salt,
    int iterations,
    int keyLengthBytes,
  ) {
    if (iterations < 1) throw ArgumentError.value(iterations, 'iterations');
    final hmac = Hmac(sha256, password);
    final output = <int>[];

    for (var block = 1; output.length < keyLengthBytes; block++) {

      var u = hmac.convert([
        ...salt,
        (block >> 24) & 0xff,
        (block >> 16) & 0xff,
        (block >> 8) & 0xff,
        block & 0xff,
      ]).bytes;
      final accumulator = List<int>.from(u);

      for (var round = 1; round < iterations; round++) {
        u = hmac.convert(u).bytes;
        for (var i = 0; i < accumulator.length; i++) {
          accumulator[i] ^= u[i];
        }
      }
      output.addAll(accumulator);
    }

    return output.sublist(0, keyLengthBytes);
  }



  static String deriveKeyFromPassword(
    String password,
    String salt, {
    int iterations = passwordKdfIterations,
  }) {
    final bytes = pbkdf2(
      utf8.encode(password),
      utf8.encode(salt),
      iterations,
      16,
    );
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }





















  static const String otpAccountsSyncContext = 'otp-accounts-sync';
  static const String snapshotSyncContext = 'otp-vault-snapshots';
  static const String localVaultContext = 'local-vault';

  static const String _dataKeyPasswordContext = 'vault-datakey-password';
  static const String _dataKeyCodeContext = 'vault-datakey-code';



  static String generateVaultDataKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .substring(0, 32);
  }





  static String generateKeyringSalt() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }




  static String _passwordWrappingKey(
    String password,
    String salt, {
    required int iterations,
  }) {
    if (iterations <= 0) {
      return generateKey(password, 'vault_keyring|$salt');
    }
    return deriveKeyFromPassword(
      password,
      'vault_keyring|$salt',
      iterations: iterations,
    );
  }

  static String wrapDataKeyWithPassword(
    String dataKey,
    String password,
    String salt, {
    int iterations = passwordKdfIterations,
  }) {
    return authenticatedEncrypt(
      dataKey,
      _passwordWrappingKey(password, salt, iterations: iterations),
      context: _dataKeyPasswordContext,
    );
  }


  static String? unwrapDataKeyWithPassword(
    String wrapped,
    String password,
    String salt, {
    int iterations = passwordKdfIterations,
  }) {
    try {
      final key = authenticatedDecrypt(
        wrapped,
        _passwordWrappingKey(password, salt, iterations: iterations),
        context: _dataKeyPasswordContext,
      );
      return key.isEmpty ? null : key;
    } catch (_) {
      return null;
    }
  }

  static String wrapDataKeyWithRecoveryCode(String dataKey, String code) {
    return authenticatedEncrypt(
      dataKey,
      _escrowKeyFor(code),
      context: _dataKeyCodeContext,
    );
  }

  static String? unwrapDataKeyWithRecoveryCode(String wrapped, String code) {
    try {
      final key = authenticatedDecrypt(
        wrapped,
        _escrowKeyFor(code),
        context: _dataKeyCodeContext,
      );
      return key.isEmpty ? null : key;
    } catch (_) {
      return null;
    }
  }











  static const String vaultEscrowContext = 'vault-key-escrow';

  static String normalizeRecoveryCode(String rawCode) {
    return rawCode.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  static String _escrowKeyFor(String recoveryCode) {
    return generateKey(
      normalizeRecoveryCode(recoveryCode),
      'vault_key_escrow_salt',
    );
  }

  static String wrapVaultKey(String vaultKey, String recoveryCode) {
    return authenticatedEncrypt(
      vaultKey,
      _escrowKeyFor(recoveryCode),
      context: vaultEscrowContext,
    );
  }



  static String? unwrapVaultKey(String wrapped, String recoveryCode) {
    try {
      final key = authenticatedDecrypt(
        wrapped,
        _escrowKeyFor(recoveryCode),
        context: vaultEscrowContext,
      );
      return key.isEmpty ? null : key;
    } catch (_) {
      return null;
    }
  }



  static String chainVaultKey(String newKey, String previousKey) {
    return authenticatedEncrypt(
      newKey,
      previousKey,
      context: 'vault-key-chain',
    );
  }

  static String? unchainVaultKey(String wrapped, String previousKey) {
    try {
      final key = authenticatedDecrypt(
        wrapped,
        previousKey,
        context: 'vault-key-chain',
      );
      return key.isEmpty ? null : key;
    } catch (_) {
      return null;
    }
  }

  static String encryptSensitiveSyncPayload(
    String plainText,
    String key, {
    required String context,
  }) {
    return authenticatedEncrypt(plainText, key, context: context);
  }

  static String decryptSensitiveSyncPayload(
    String cipherText,
    String key, {
    required String context,
    bool allowLegacyPlaintextFallback = false,
  }) {
    return authenticatedDecrypt(
      cipherText,
      key,
      context: context,
      allowLegacyPlaintextFallback: allowLegacyPlaintextFallback,
    );
  }













  static const String _aesPrefix = 'bl3:';




  static bool isAuthenticatedPayload(String value) =>
      value.startsWith(_aesPrefix) || value.startsWith(_legacyMacPrefix);

  static const String _legacyMacPrefix = 'bl2:';
  static const int _gcmNonceBytes = 12;
  static const int _gcmMacBits = 128;



  static Uint8List _aesKeyFor(String key, String context) {
    return Uint8List.fromList(
      sha256.convert(utf8.encode('$key|aes256gcm|$context')).bytes,
    );
  }

  static GCMBlockCipher _gcm(
    Uint8List key,
    Uint8List nonce,
    String context, {
    required bool forEncryption,
  }) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        forEncryption,
        AEADParameters(
          KeyParameter(key),
          _gcmMacBits,
          nonce,



          Uint8List.fromList(utf8.encode(context)),
        ),
      );
    return cipher;
  }

  static String _aesEncrypt(String plainText, String key, String context) {
    final random = Random.secure();
    final nonce = Uint8List.fromList(
      List<int>.generate(_gcmNonceBytes, (_) => random.nextInt(256)),
    );
    final sealed = _gcm(
      _aesKeyFor(key, context),
      nonce,
      context,
      forEncryption: true,
    ).process(Uint8List.fromList(utf8.encode(plainText)));

    return '$_aesPrefix${base64Encode([...nonce, ...sealed])}';
  }

  static String _aesDecrypt(String cipherText, String key, String context) {
    final payload = base64.decode(cipherText.substring(_aesPrefix.length));
    if (payload.length <= _gcmNonceBytes) {
      throw const FormatException('Invalid encrypted payload');
    }

    final nonce = Uint8List.fromList(payload.sublist(0, _gcmNonceBytes));
    final sealed = Uint8List.fromList(payload.sublist(_gcmNonceBytes));

    try {
      final plain = _gcm(
        _aesKeyFor(key, context),
        nonce,
        context,
        forEncryption: false,
      ).process(sealed);
      return utf8.decode(plain);
    } on InvalidCipherTextException {


      throw const FormatException('Encrypted payload authentication failed');
    }
  }

  static String authenticatedEncrypt(
    String plainText,
    String key, {
    required String context,
  }) {
    if (plainText.isEmpty) return '';
    return _aesEncrypt(plainText, key, context);
  }

  static String authenticatedDecrypt(
    String cipherText,
    String key, {
    required String context,
    bool allowLegacyPlaintextFallback = false,
  }) {
    if (cipherText.isEmpty) return '';
    if (cipherText.startsWith(_aesPrefix)) {
      return _aesDecrypt(cipherText, key, context);
    }
    if (!cipherText.startsWith(_legacyMacPrefix)) {




      if (!allowLegacyPlaintextFallback) {
        throw const FormatException('Refusing to read unauthenticated payload');
      }
      return simpleDecrypt(cipherText, key);
    }



    final payload =
        base64.decode(cipherText.substring(_legacyMacPrefix.length));
    if (payload.length < 48) {
      throw const FormatException('Invalid encrypted payload');
    }

    final nonce = payload.sublist(0, 16);
    final mac = payload.sublist(16, 48);
    final encrypted = payload.sublist(48);
    final encryptionKey =
        sha256.convert(utf8.encode('$key|enc|$context')).bytes;
    final authKey = sha256.convert(utf8.encode('$key|auth|$context')).bytes;
    final expectedMac = Hmac(
      sha256,
      authKey,
    ).convert([...utf8.encode(context), ...nonce, ...encrypted]).bytes;

    if (!_constantTimeBytesEqual(mac, expectedMac)) {
      throw const FormatException('Encrypted payload authentication failed');
    }

    final decrypted = _xorWithKeystream(encrypted, encryptionKey, nonce);
    return utf8.decode(decrypted);
  }

  static List<int> _xorWithKeystream(
    List<int> input,
    List<int> keyBytes,
    List<int> nonce,
  ) {
    final output = <int>[];
    var blockIndex = 0;

    while (output.length < input.length) {
      final keystreamBlock = sha256.convert([
        ...keyBytes,
        ...nonce,
        ...utf8.encode(':$blockIndex'),
      ]).bytes;

      for (final byte in keystreamBlock) {
        if (output.length >= input.length) break;
        output.add(input[output.length] ^ byte);
      }
      blockIndex++;
    }

    return output;
  }

  static bool _constantTimeBytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }

    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
