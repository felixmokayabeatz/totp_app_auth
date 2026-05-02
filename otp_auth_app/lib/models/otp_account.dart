// models/otp_account.dart

import 'package:hive/hive.dart';
import '../services/encryption_service.dart';

part 'otp_account.g.dart'; // ← ADD THIS LINE

@HiveType(typeId: 0)
class OTPAccount {
  @HiveField(0)
  String id;

  @HiveField(1)
  String service;

  @HiveField(2)
  String encryptedSecret;

  @HiveField(3)
  String? issuer;

  @HiveField(4)
  DateTime createdAt;

  @HiveField(5)
  String? accountLabel;

  String? _plainSecret;

  OTPAccount({
    required this.id,
    required this.service,
    required String secret,
    this.issuer,
    required this.createdAt,
    this.accountLabel,
    String? userId,
  }) : encryptedSecret = '' {
    if (userId != null && userId.isNotEmpty) {
      setSecret(secret, userId);
    } else {
      encryptedSecret = secret;
      _plainSecret = null;
    }
  }

  void setSecret(String secret, String userId) {
    _plainSecret = secret;
    encryptedSecret = EncryptionService.encryptSecret(secret, userId);
  }

  String getSecret(String userId) {
    if (_plainSecret != null) return _plainSecret!;

    try {
      final decrypted = EncryptionService.decryptSecret(encryptedSecret, userId);
      if (_looksLikeBase32Secret(decrypted)) {
        _plainSecret = decrypted;
        return _plainSecret!;
      }
    } catch (e) {
      print('Decryption error: $e');
    }

    if (_looksLikeBase32Secret(encryptedSecret)) {
      _plainSecret = encryptedSecret;
      return _plainSecret!;
    }

    return encryptedSecret;
  }

  String get secret => encryptedSecret;

  bool _looksLikeBase32Secret(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('=', '')
        .toUpperCase();
    return cleaned.isNotEmpty && RegExp(r'^[A-Z2-7]+$').hasMatch(cleaned);
  }
}
