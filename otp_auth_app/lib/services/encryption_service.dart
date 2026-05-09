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
      String encryptedSecret, String userId) {
    final key = generateKey(userId, 'password_entry_local_encryption_salt');
    return authenticatedDecrypt(
      encryptedSecret,
      key,
      context: 'password-entry-local',
    );
  }

  static String encryptPasswordEntryNote(String note, String userId) {
    final key = generateKey(userId, 'password_entry_note_local_encryption_salt');
    return authenticatedEncrypt(note, key, context: 'password-entry-note-local');
  }

  static String decryptPasswordEntryNote(String encryptedNote, String userId) {
    final key = generateKey(userId, 'password_entry_note_local_encryption_salt');
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

  static String encryptSensitiveSyncPayload(String plainText, String key,
      {required String context}) {
    return authenticatedEncrypt(plainText, key, context: context);
  }

  static String decryptSensitiveSyncPayload(String cipherText, String key,
      {required String context}) {
    return authenticatedDecrypt(cipherText, key, context: context);
  }

  static String authenticatedEncrypt(String plainText, String key,
      {required String context}) {
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
    ).convert([
      ...utf8.encode(context),
      ...nonce,
      ...encrypted,
    ]).bytes;

    return 'bl2:${base64Encode([...nonce, ...mac, ...encrypted])}';
  }

  static String authenticatedDecrypt(String cipherText, String key,
      {required String context}) {
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
    ).convert([
      ...utf8.encode(context),
      ...nonce,
      ...encrypted,
    ]).bytes;

    if (!_constantTimeBytesEqual(mac, expectedMac)) {
      throw const FormatException('Encrypted payload authentication failed');
    }

    final decrypted = _xorWithKeystream(encrypted, encryptionKey, nonce);
    return utf8.decode(decrypted);
  }

  static List<int> _xorWithKeystream(
      List<int> input, List<int> keyBytes, List<int> nonce) {
    final output = <int>[];
    var blockIndex = 0;

    while (output.length < input.length) {
      final keystreamBlock = sha256.convert(
        [
          ...keyBytes,
          ...nonce,
          ...utf8.encode(':$blockIndex'),
        ],
      ).bytes;

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
