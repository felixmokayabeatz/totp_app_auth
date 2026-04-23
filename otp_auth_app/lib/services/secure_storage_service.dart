import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SecureStorageService {
  static const accessTokenKey = 'access_token';
  static const refreshTokenKey = 'refresh_token';
  static const currentUserKey = 'current_user';
  static const userEmailKey = 'user_email';
  static const userIdKey = 'user_id';
  static const encryptionKey = 'encryption_key';

  static const List<String> _knownKeys = [
    accessTokenKey,
    refreshTokenKey,
    currentUserKey,
    userEmailKey,
    userIdKey,
    encryptionKey,
  ];

  static final SecureStorageService _instance =
      SecureStorageService._internal();
  factory SecureStorageService() => _instance;
  SecureStorageService._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<void> init() async {
    for (final key in _knownKeys) {
      await _migrateLegacyPreference(key);
    }
  }

  Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);

    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(key)) {
      await prefs.remove(key);
    }
  }

  Future<String?> read(String key) async {
    final value = await _storage.read(key: key);
    if (value != null) {
      return value;
    }

    return _migrateLegacyPreference(key);
  }

  Future<void> delete(String key) async {
    await _storage.delete(key: key);

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  Future<void> deleteAll() async {
    await _storage.deleteAll();

    final prefs = await SharedPreferences.getInstance();
    for (final key in _knownKeys) {
      await prefs.remove(key);
    }
  }

  Future<String?> _migrateLegacyPreference(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final legacyValue = prefs.getString(key);

    if (legacyValue != null) {
      await _storage.write(key: key, value: legacyValue);
      await prefs.remove(key);
    }

    return legacyValue;
  }
}
