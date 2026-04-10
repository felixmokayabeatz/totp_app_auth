import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class EncryptionService {
  static String generateKey(String password, String salt) {
    var key = sha256.convert(utf8.encode(password + salt)).toString();
    return key.substring(0, 32);
  }
  
  static String simpleEncrypt(String text, String key) {
    // Simple XOR encryption for demo (use proper AES in production)
    List<int> textBytes = utf8.encode(text);
    List<int> keyBytes = utf8.encode(key);
    List<int> encrypted = [];
    
    for (int i = 0; i < textBytes.length; i++) {
      encrypted.add(textBytes[i] ^ keyBytes[i % keyBytes.length]);
    }
    
    return base64.encode(encrypted);
  }
  
  static String simpleDecrypt(String encryptedBase64, String key) {
    List<int> encrypted = base64.decode(encryptedBase64);
    List<int> keyBytes = utf8.encode(key);
    List<int> decrypted = [];
    
    for (int i = 0; i < encrypted.length; i++) {
      decrypted.add(encrypted[i] ^ keyBytes[i % keyBytes.length]);
    }
    
    return utf8.decode(decrypted);
  }
}