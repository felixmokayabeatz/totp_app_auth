import 'package:hive/hive.dart';

import '../services/encryption_service.dart';

part 'secure_message.g.dart';

@HiveType(typeId: 2)
class SecureMessage {
  @HiveField(0)
  String id;

  @HiveField(1)
  String encryptedText;

  @HiveField(2)
  DateTime createdAt;

  @HiveField(3)
  String? authorDeviceLabel;

  String? _plainText;

  SecureMessage({
    required this.id,
    required String text,
    required this.createdAt,
    this.authorDeviceLabel,
    String? userId,
  }) : encryptedText = '' {
    if (userId != null && userId.isNotEmpty) {
      setText(text, userId);
    } else {
      encryptedText = text;
      _plainText = null;
    }
  }

  void setText(String text, String userId) {
    _plainText = text;
    encryptedText = EncryptionService.encryptSecureMessageText(text, userId);
  }

  String getText(String userId) {
    if (_plainText != null) return _plainText!;

    try {
      _plainText =
          EncryptionService.decryptSecureMessageText(encryptedText, userId);
      return _plainText!;
    } catch (_) {
      return 'Unable to decrypt message.';
    }
  }
}
