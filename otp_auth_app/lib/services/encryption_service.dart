// encryption_service.dart

import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

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

  static String encryptSecret(String secret, String userId) {
    final key = generateKey(userId, 'otp_local_encryption_salt');
    return simpleEncrypt(secret, key);
  }

  static String decryptSecret(String encryptedSecret, String userId) {
    final key = generateKey(userId, 'otp_local_encryption_salt');
    return simpleDecrypt(encryptedSecret, key);
  }

  static String encryptPasswordEntrySecret(String secret, String userId) {
    final key = generateKey(userId, 'password_entry_local_encryption_salt');
    return authenticatedEncrypt(secret, key, context: 'password-entry-local');
  }

  static String decryptPasswordEntrySecret(
    String encryptedSecret,
    String userId,
  ) {
    final key = generateKey(userId, 'password_entry_local_encryption_salt');
    return authenticatedDecrypt(
      encryptedSecret,
      key,
      context: 'password-entry-local',
    );
  }

  static String encryptPasswordEntryNote(String note, String userId) {
    final key = generateKey(
      userId,
      'password_entry_note_local_encryption_salt',
    );
    return authenticatedEncrypt(
      note,
      key,
      context: 'password-entry-note-local',
    );
  }

  static String decryptPasswordEntryNote(String encryptedNote, String userId) {
    final key = generateKey(
      userId,
      'password_entry_note_local_encryption_salt',
    );
    return authenticatedDecrypt(
      encryptedNote,
      key,
      context: 'password-entry-note-local',
    );
  }

  static String encryptSecureMessageText(String text, String userId) {
    final key = generateKey(userId, 'secure_message_local_encryption_salt');
    return authenticatedEncrypt(text, key, context: 'secure-message-local');
  }

  static String decryptSecureMessageText(String encryptedText, String userId) {
    final key = generateKey(userId, 'secure_message_local_encryption_salt');
    return authenticatedDecrypt(
      encryptedText,
      key,
      context: 'secure-message-local',
    );
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

  static String _passwordWrappingKey(String password, String salt) {
    return generateKey(password, 'vault_keyring|$salt');
  }

  static String wrapDataKeyWithPassword(
    String dataKey,
    String password,
    String salt,
  ) {
    return authenticatedEncrypt(
      dataKey,
      _passwordWrappingKey(password, salt),
      context: _dataKeyPasswordContext,
    );
  }

  /// The data key, or null when [password] is not the one it was wrapped under.
  static String? unwrapDataKeyWithPassword(
    String wrapped,
    String password,
    String salt,
  ) {
    try {
      final key = authenticatedDecrypt(
        wrapped,
        _passwordWrappingKey(password, salt),
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
  }) {
    return authenticatedDecrypt(cipherText, key, context: context);
  }

  static String authenticatedEncrypt(
    String plainText,
    String key, {
    required String context,
  }) {
    if (plainText.isEmpty) return '';

    final nonce = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final input = utf8.encode(plainText);
    final encryptionKey =
        sha256.convert(utf8.encode('$key|enc|$context')).bytes;
    final authKey = sha256.convert(utf8.encode('$key|auth|$context')).bytes;
    final encrypted = _xorWithKeystream(input, encryptionKey, nonce);
    final mac = Hmac(
      sha256,
      authKey,
    ).convert([...utf8.encode(context), ...nonce, ...encrypted]).bytes;

    return 'bl2:${base64Encode([...nonce, ...mac, ...encrypted])}';
  }

  static String authenticatedDecrypt(
    String cipherText,
    String key, {
    required String context,
  }) {
    if (cipherText.isEmpty) return '';
    if (!cipherText.startsWith('bl2:')) {
      return simpleDecrypt(cipherText, key);
    }

    final payload = base64.decode(cipherText.substring(4));
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
