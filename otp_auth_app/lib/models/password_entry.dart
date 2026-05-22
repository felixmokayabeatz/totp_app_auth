// models/password_entry.dart

import 'package:hive/hive.dart';
import '../services/encryption_service.dart';

part 'password_entry.g.dart';

@HiveType(typeId: 1)
class PasswordEntry {
  @HiveField(0)
  String id;

  @HiveField(1)
  String title;

  @HiveField(2)
  String username;

  @HiveField(3)
  String encryptedPassword;

  @HiveField(4)
  String? serverIP;

  @HiveField(5)
  DateTime createdAt;

  @HiveField(6)
  String? encryptedNote;

  @HiveField(7)
  DateTime updatedAt;

  String? _plainPassword;
  String? _plainNote;

  PasswordEntry({
    required this.id,
    required this.title,
    required this.username,
    required String password,
    String? note,
    this.serverIP,
    required this.createdAt,
    DateTime? updatedAt,
    String? userId,
  })  : encryptedPassword = '',
        encryptedNote = null,
        updatedAt = updatedAt ?? createdAt {
    if (userId != null && userId.isNotEmpty) {
      setPassword(password, userId);
      setNote(note, userId);
    } else {
      encryptedPassword = password;
      _plainPassword = null;
      encryptedNote = note;
      _plainNote = null;
    }
  }

  void setPassword(String password, String userId) {
    _plainPassword = password;
    encryptedPassword = EncryptionService.encryptPasswordEntrySecret(
      password,
      userId,
    );
    touch();
  }

  String getPassword(String userId) {
    if (_plainPassword != null) return _plainPassword!;

    try {
      _plainPassword = EncryptionService.decryptPasswordEntrySecret(
        encryptedPassword,
        userId,
      );
      return _plainPassword!;
    } catch (_) {
      _plainPassword = encryptedPassword;
      return _plainPassword!;
    }
  }

  void setNote(String? note, String userId) {
    final normalized = note?.trim() ?? '';
    if (normalized.isEmpty) {
      encryptedNote = null;
      _plainNote = null;
      touch();
      return;
    }

    _plainNote = normalized;
    encryptedNote = EncryptionService.encryptPasswordEntryNote(
      normalized,
      userId,
    );
    touch();
  }

  String? getNote(String userId) {
    if (_plainNote != null) return _plainNote;
    if (encryptedNote == null || encryptedNote!.isEmpty) return null;

    try {
      _plainNote = EncryptionService.decryptPasswordEntryNote(
        encryptedNote!,
        userId,
      );
      return _plainNote;
    } catch (_) {
      _plainNote = encryptedNote;
      return _plainNote;
    }
  }

  String get password => encryptedPassword;
  String? get note => encryptedNote;

  void touch() {
    updatedAt = DateTime.now();
  }
}
