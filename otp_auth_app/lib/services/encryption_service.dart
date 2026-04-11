import 'dart:convert';
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
}