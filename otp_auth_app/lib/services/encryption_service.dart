// encryption_service.dart

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

  // The local vault used to be encrypted with generateKey(userId, salt), where
  // userId is the account's email address -- public information. Anyone with
  // the .hive file could derive the same key and read every secret in it. It
  // was obfuscation wearing the shape of encryption.
  //
  // A random per-install secret now goes into that derivation, so the key is no
  // longer computable from anything an attacker holding the file can see. It is
  // configured once at start-up from secure storage rather than threaded
  // through the thirty-odd call sites that pass a userId, which keeps the
  // change small enough to reason about.
  //
  // Until it is configured, the legacy derivation is used unchanged: reading
  // existing data must never depend on initialisation order.

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
      // Not configured yet: keep writing what this install can already read.
      return simpleEncrypt(secret, legacyLocalKeyFor(userId));
    }
    return authenticatedEncrypt(
      secret,
      _localKeyFor(userId),
      context: localVaultContext,
    );
  }

  /// Decrypt a locally stored secret, accepting either format.
  ///
  /// Values written before the per-install secret existed stay readable, and
  /// are rewritten in the current format the next time they are saved.
  static String decryptSecret(String encryptedSecret, String userId) {
    // Either authenticated format. Checking only for the older prefix here is
    // what broke when AES-GCM landed: newly written values fell through to the
    // unauthenticated reader and threw on its base64.
    if (isAuthenticatedPayload(encryptedSecret)) {
      return authenticatedDecrypt(
        encryptedSecret,
        _localKeyFor(userId),
        context: localVaultContext,
      );
    }
    return simpleDecrypt(encryptedSecret, legacyLocalKeyFor(userId));
  }

  // --- Key derivation -------------------------------------------------------
  // generateKey below is a single SHA-256. As a password KDF that is no work
  // at all: a GPU walks billions of candidate passwords a second against a
  // stored wrap. Anything a password protects goes through PBKDF2-HMAC-SHA256
  // instead, which costs an attacker the same iteration count it costs us.
  //
  // Implemented here rather than pulled in, because PBKDF2 is a short, exactly
  // specified construction and the alternative was another dependency on the
  // launch path. It is checked against published test vectors in
  // test/kdf_test.dart -- do not change it without those passing.

  /// OWASP's floor for PBKDF2-HMAC-SHA256. Raise it, never lower it: a stored
  /// wrap records the count it was made with, so old wraps keep opening.
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
      // U1 = HMAC(P, S || INT_32_BE(block))
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

  /// A key from a password, at a real cost. Returned as 32 hex characters so
  /// it drops into every place that already takes a String key.
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

  // --- Vault keyring --------------------------------------------------------
  // The vault used to be encrypted with a key derived straight from the
  // account identity and password. Every serious failure in this app came out
  // of that one decision: lowercasing the email changed the key, a username
  // that was not the email changed the key, a password change meant rewriting
  // the whole vault, and a password reset -- which by definition happens
  // without the old password -- left the vault sealed under a key nobody could
  // ever derive again.
  //
  // The keyring removes the cause rather than handling the symptoms. The vault
  // is encrypted with a random data key that never changes. That key is stored
  // wrapped: once under the password, once under each recovery code. Changing
  // a password re-wraps thirty-two bytes and does not touch the vault. A reset
  // unwraps through a recovery code. Nothing derives anything from an identity,
  // so how the address is spelled stops mattering entirely.

  /// The synced OTP vault. It used to be stored under simpleEncrypt, a
  /// repeating-key XOR: the payload is JSON whose first thirty-two bytes are
  /// guessable, and thirty-two bytes of known plaintext is the whole key. The
  /// password never even entered into breaking it.
  static const String otpAccountsSyncContext = 'otp-accounts-sync';
  static const String snapshotSyncContext = 'otp-vault-snapshots';
  static const String localVaultContext = 'local-vault';

  static const String _dataKeyPasswordContext = 'vault-datakey-password';
  static const String _dataKeyCodeContext = 'vault-datakey-code';

  /// A fresh random data key. Hex, so it is a plain String like every other
  /// key this service takes.
  static String generateVaultDataKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .substring(0, 32);
  }

  /// A random, non-secret salt stored beside the wrapped key.
  ///
  /// It is what makes the wrapping key depend on the password alone rather
  /// than on the account identity, which is the whole point.
  static String generateKeyringSalt() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// [iterations] of 0 means the original single-SHA-256 derivation, which
  /// keyrings written before PBKDF2 landed still use. Those keep opening, and
  /// are re-wrapped at the current cost the first time they are opened.
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

  /// The data key, or null when [password] is not the one it was wrapped under.
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

  // --- Vault key escrow ----------------------------------------------------
  // The vault key is derived from the account password, so a password reset --
  // which by definition happens without the old password -- used to leave the
  // synced vault locked under a key nobody could ever derive again. Wrapping
  // the key under each recovery code gives the PDF the user is already made to
  // save a way to unlock it, turning those codes into a real recovery path
  // rather than only a way back into the account.
  //
  // Authenticated, so a wrong code fails loudly instead of yielding a
  // plausible-looking wrong key that would then be used to "decrypt" the vault.
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

  /// The vault key sealed in [wrapped], or null if [recoveryCode] is not the
  /// code it was wrapped under.
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

  /// Seal [newKey] under [previousKey], so a re-key stays reachable from an
  /// escrow entry written before it without needing the codes again.
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

  // --- AES-256-GCM ----------------------------------------------------------
  // Everything here used to run on a hand-rolled construction: a SHA-256
  // keystream with an HMAC over it. It was encrypt-then-MAC with a random nonce
  // and a constant-time compare, so it was not broken -- but "not broken as far
  // as I can tell" is not the standard a 2FA vault should be held to. This is
  // AES-256-GCM from pointycastle, which is a reviewed implementation of a
  // reviewed primitive.
  //
  // Written as bl3. bl2 payloads stay readable so existing data migrates on its
  // next write, and the unauthenticated original stays gated behind an explicit
  // flag.

  static const String _aesPrefix = 'bl3:';

  /// Whether [value] is in one of the authenticated formats, rather than the
  /// unauthenticated original. Anything that dispatches on format must use
  /// this: hard-coding a single prefix silently breaks on the next change.
  static bool isAuthenticatedPayload(String value) =>
      value.startsWith(_aesPrefix) || value.startsWith(_legacyMacPrefix);

  static const String _legacyMacPrefix = 'bl2:';
  static const int _gcmNonceBytes = 12;
  static const int _gcmMacBits = 128;

  /// A 256-bit key from the caller's key string, bound to its context so a
  /// payload written for one purpose cannot be read as another.
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
          // The context is authenticated as associated data as well as mixed
          // into the key: tampering that swaps a payload between contexts fails
          // the tag rather than merely deriving the wrong key.
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
      // Surfaced as FormatException so every existing caller's handling of a
      // wrong key or altered payload keeps working unchanged.
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
      // Anything without the prefix predates authenticated encryption. Reading
      // it is only allowed where a caller is explicitly migrating it forward:
      // left open, this is a downgrade -- strip four bytes and the MAC check
      // that makes the format worth having disappears with them.
      if (!allowLegacyPlaintextFallback) {
        throw const FormatException('Refusing to read unauthenticated payload');
      }
      return simpleDecrypt(cipherText, key);
    }

    // The previous hand-rolled format. Read only, so existing payloads survive
    // until their next write puts them in AES-GCM.
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
