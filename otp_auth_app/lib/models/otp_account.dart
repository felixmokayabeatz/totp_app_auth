import 'package:hive/hive.dart';
import '../services/encryption_service.dart';

part 'otp_account.g.dart';

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
  
  String? _plainSecret;
  
  OTPAccount({
    required this.id,
    required this.service,
    required String secret,
    this.issuer,
    required this.createdAt,
    String? userId,
  }) : encryptedSecret = '' {
    if (userId != null && userId.isNotEmpty) {
      setSecret(secret, userId);
    } else {
      encryptedSecret = secret;
      _plainSecret = secret;
    }
  }
  
  void setSecret(String secret, String userId) {
    _plainSecret = secret;
    encryptedSecret = EncryptionService.encryptSecret(secret, userId);
  }
  
  String getSecret(String userId) {
    if (_plainSecret != null) return _plainSecret!;
    try {
      _plainSecret = EncryptionService.decryptSecret(encryptedSecret, userId);
      return _plainSecret!;
    } catch (e) {
      print('Decryption error: $e');
      return encryptedSecret;
    }
  }
  
  String get secret => encryptedSecret;
}