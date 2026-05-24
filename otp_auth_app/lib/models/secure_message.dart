import 'package:hive/hive.dart';

import '../services/encryption_service.dart';

part 'secure_message.g.dart';

@HiveType(typeId: 2)
class SecureMessage {
  static const int foreverRetentionMinutes = -1;
  static const int defaultRetentionMinutes = 24 * 60;
  static const int minimumRetentionMinutes = 10;

  @HiveField(0)
  String id;

  @HiveField(1)
  String encryptedText;

  @HiveField(2)
  DateTime createdAt;

  @HiveField(3)
  String? authorDeviceLabel;

  @HiveField(4)
  int retentionMinutes;

  String? _plainText;

  SecureMessage({
    required this.id,
    required String text,
    required this.createdAt,
    this.authorDeviceLabel,
    int? retentionMinutes,
    String? userId,
  })  : encryptedText = '',
        retentionMinutes = normalizeRetentionMinutes(retentionMinutes) {
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

  static int normalizeRetentionMinutes(int? minutes) {
    if (minutes == foreverRetentionMinutes) {
      return foreverRetentionMinutes;
    }
    if (minutes == null) {
      return defaultRetentionMinutes;
    }
    return minutes < minimumRetentionMinutes
        ? minimumRetentionMinutes
        : minutes;
  }

  bool get persistsForever => retentionMinutes == foreverRetentionMinutes;

  DateTime? expiresAt() {
    if (persistsForever) {
      return null;
    }
    return createdAt.add(Duration(minutes: retentionMinutes));
  }

  bool isExpired({DateTime? now}) {
    final expiresAtValue = expiresAt();
    if (expiresAtValue == null) {
      return false;
    }
    return expiresAtValue.isBefore(now ?? DateTime.now());
  }

  String getText(String userId) {
    if (_plainText != null) return _plainText!;

    try {
      _plainText = EncryptionService.decryptSecureMessageText(
        encryptedText,
        userId,
      );
      return _plainText!;
    } catch (_) {
      return 'Unable to decrypt message.';
    }
  }
}
