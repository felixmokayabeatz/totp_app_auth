// lib/services/sync_service.dart
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/otp_account.dart';
import 'encryption_service.dart';
import '../config/app_config.dart';
import 'dart:convert';

class SyncService {
  // ─── Singleton ────────────────────────────────────────────────────────────
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal() {
    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Content-Type': 'application/json'},
    ));
  }

  late Dio _dio;
  bool _isRefreshing = false;
  String? _encryptionKey;

  // ─── Sync-enabled preference key ─────────────────────────────────────────
  static const _syncEnabledKey = 'sync_to_cloud_enabled';

  Future<bool> isSyncEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_syncEnabledKey) ?? true;
  }

  Future<void> setSyncEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_syncEnabledKey, value);
  }

  // ─── Box helpers ──────────────────────────────────────────────────────────
  Future<String> _getUserBoxName() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('current_user');
    if (username == null || username.isEmpty) return 'otp_accounts_default';
    return 'otp_accounts_$username';
  }

  Future<Box<OTPAccount>> _getUserBox() async {
    final boxName = await _getUserBoxName();
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<OTPAccount>(boxName);
    }
    return Hive.box<OTPAccount>(boxName);
  }

  Future<Box<OTPAccount>> getUserBox() async => await _getUserBox();
  Future<String> getCurrentUserBoxName() async => await _getUserBoxName();

  // ─── Auth helpers ─────────────────────────────────────────────────────────
  Future<void> _updateAuthHeader() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    if (token != null && token.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $token';
    }
  }

  Future<bool> _refreshToken() async {
    if (_isRefreshing) return false;
    _isRefreshing = true;
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = prefs.getString('refresh_token');
    if (refreshToken == null) { _isRefreshing = false; return false; }
    try {
      final response = await _dio.post('token/refresh/', data: {'refresh': refreshToken});
      if (response.statusCode == 200) {
        await prefs.setString('access_token', response.data['access']);
        await _updateAuthHeader();
        _isRefreshing = false;
        return true;
      }
    } catch (_) {}
    _isRefreshing = false;
    return false;
  }

  Future<Response> _requestWithRetry(Future<Response> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        final refreshed = await _refreshToken();
        if (refreshed) return await request();
      }
      rethrow;
    }
  }

  Future<void> _initEncryption() async {
    if (_encryptionKey != null) return;
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('current_user') ?? 'default_user';
    _encryptionKey = EncryptionService.generateKey(username, 'otp_auth_salt_2024');
  }

  Future<String> _getCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('current_user') ?? 'default_user';
  }

  // ─── THE FIX: decrypt the locally-encrypted secret back to plain text ─────
  // The cloud envelope is already encrypted with simpleEncrypt/simpleDecrypt.
  // So secrets inside must be PLAIN so every device can read them correctly.
  Future<String> _decryptSecretForUpload(String storedSecret) async {
    // If it is already plain Base32, just return it as-is
    final strippedSpaces = storedSecret.replaceAll(RegExp(r'\s+'), '');
    final isRawBase32 = RegExp(r'^[A-Z2-7a-z]+$').hasMatch(strippedSpaces);
    if (isRawBase32) return storedSecret;

    // Otherwise decrypt it using the local user key
    try {
      final userId = await _getCurrentUserId();
      return EncryptionService.decryptSecret(storedSecret, userId);
    } catch (e) {
      // If decryption fails just return as-is to avoid data loss
      return storedSecret;
    }
  }

  // ─── Register / Login ─────────────────────────────────────────────────────
  Future<bool> register(String username, String email, String password) async {
    try {
      final response = await _dio.post('auth/register/', data: {
        'username': username,
        'email': email,
        'password': password,
      });
      if (response.statusCode == 200 || response.statusCode == 201) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('access_token', response.data['access']);
        await prefs.setString('refresh_token', response.data['refresh']);
        await prefs.setString('current_user', username);
        await prefs.setString('user_email', email);
        await prefs.setString('user_id', response.data['user']['id'].toString());
        await _updateAuthHeader();
        await _initEncryption();
        return true;
      }
      return false;
    } catch (e) {
      print('Register error: $e');
      return false;
    }
  }

  Future<bool> login(String username, String password) async {
    try {
      final response = await _dio.post('auth/login/', data: {
        'username': username,
        'password': password,
      });
      if (response.statusCode == 200) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('access_token', response.data['access']);
        await prefs.setString('refresh_token', response.data['refresh']);
        await prefs.setString('current_user', username);
        await prefs.setString('user_email', response.data['user']['email'] ?? '');
        await prefs.setString('user_id', response.data['user']['id'].toString());
        await _updateAuthHeader();
        await _initEncryption();
        final userBox = await _getUserBox();
        print('User box ${await _getUserBoxName()} has ${userBox.length} accounts');
        await downloadAndMergeAccounts();
        return true;
      }
      return false;
    } catch (e) {
      print('Login error: $e');
      return false;
    }
  }

  // ─── Delete a single account ──────────────────────────────────────────────
  Future<void> deleteAccountLocalOnly(String accountId) async {
    final userBox = await _getUserBox();
    await userBox.delete(accountId);
    print('Deleted $accountId locally only');
  }

  Future<bool> deleteAccountEverywhere(String accountId) async {
    await _updateAuthHeader();
    try {
      final response = await _requestWithRetry(() => _dio.post(
        'sync/delete-account/',
        data: {'account_id': accountId},
      ));
      if (response.statusCode == 200) {
        final userBox = await _getUserBox();
        await userBox.delete(accountId);
        print('Deleted $accountId everywhere');
        return true;
      }
      print('Server delete failed: ${response.statusCode}');
      return false;
    } catch (e) {
      print('deleteAccountEverywhere error: $e');
      return false;
    }
  }

  // ─── Delete ALL accounts ──────────────────────────────────────────────────
  Future<void> deleteAllLocalOnly() async {
    final userBox = await _getUserBox();
    await userBox.clear();
    print('Cleared all accounts locally');
  }

  Future<bool> deleteAllEverywhere() async {
    await _updateAuthHeader();
    try {
      final response = await _requestWithRetry(
        () => _dio.post('sync/delete-all-accounts/'),
      );
      if (response.statusCode == 200) {
        final userBox = await _getUserBox();
        await userBox.clear();
        print('Deleted all accounts everywhere');
        return true;
      }
      return false;
    } catch (e) {
      print('deleteAllEverywhere error: $e');
      return false;
    }
  }

  // ─── Download and merge ───────────────────────────────────────────────────
  Future<void> downloadAndMergeAccounts() async {
    await _updateAuthHeader();
    await _initEncryption();
    if (_encryptionKey == null) return;

    final prefs = await SharedPreferences.getInstance();
    String deviceId = prefs.getString('device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
      await prefs.setString('device_id', deviceId);
    }

    try {
      final response = await _requestWithRetry(() => _dio.get(
        'sync/get-data/',
        queryParameters: {'data_type': 'otp_accounts', 'device_id': deviceId},
      ));

      if (response.statusCode == 200 && response.data['encrypted_content'] != null) {
        final encryptedContent = response.data['encrypted_content'];

        if (encryptedContent.toString().isEmpty) {
          print('Cloud has no data');
          return;
        }

        final decrypted = EncryptionService.simpleDecrypt(encryptedContent, _encryptionKey!);

        if (decrypted.isEmpty || decrypted.trim().isEmpty) {
          print('Decrypted content is empty');
          return;
        }

        try {
          final List<dynamic> cloudAccounts = jsonDecode(decrypted);
          final userBox = await _getUserBox();
          final tombstones = await _fetchTombstones();
          final userId = await _getCurrentUserId();

          int added = 0;
          for (var ca in cloudAccounts) {
            final id = ca['id'] as String;
            if (tombstones.contains(id)) continue;
            if (!userBox.containsKey(id)) {
              // ── FIX: secret from cloud is PLAIN text, encrypt it locally ──
              final plainSecret = ca['secret'] as String;
              final localEncryptedSecret = EncryptionService.encryptSecret(plainSecret, userId);

              final newAccount = OTPAccount(
                id: id,
                service: ca['service'],
                secret: localEncryptedSecret, // stored encrypted with THIS device's key
                issuer: ca['issuer'],
                createdAt: DateTime.parse(ca['createdAt']),
                userId: userId,
              );
              await userBox.put(newAccount.id, newAccount);
              added++;
            }
          }
          print('Merged $added accounts from cloud');
          await syncAccounts();
        } catch (jsonError) {
          print('Failed to parse cloud JSON: $jsonError');
        }
      }
    } catch (e) {
      print('downloadAndMergeAccounts error: $e');
    }
  }

  Future<Set<String>> _fetchTombstones() async {
    try {
      final response = await _requestWithRetry(
        () => _dio.get('sync/tombstones/'));
      if (response.statusCode == 200) {
        final List ids = response.data['tombstoned_ids'] ?? [];
        return ids.cast<String>().toSet();
      }
    } catch (_) {}
    return {};
  }

  // ─── Main sync ────────────────────────────────────────────────────────────
  Future<bool> syncAccounts() async {
    if (!(await isSyncEnabled())) {
      print('Sync disabled by user preference');
      return true;
    }

    await _updateAuthHeader();
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    if (token == null || token.isEmpty) return false;

    final userBox = await _getUserBox();
    await _initEncryption();
    if (_encryptionKey == null) return false;

    String deviceId = prefs.getString('device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
      await prefs.setString('device_id', deviceId);
    }

    try {
      Map<String, dynamic> cloudAccountsMap = {};
      int cloudVersion = 0;
      List<String> cloudDeletedAccounts = [];

      // STEP 1: Download cloud data
      try {
        final downloadResponse = await _requestWithRetry(() => _dio.get(
          'sync/get-data/',
          queryParameters: {
            'data_type': 'otp_accounts',
            'device_id': deviceId,
          },
        ));

        if (downloadResponse.statusCode == 200 &&
            downloadResponse.data['encrypted_content'] != null) {
          final encryptedContent = downloadResponse.data['encrypted_content'];

          if (encryptedContent.toString().isEmpty) {
            print('Cloud has empty data');
          } else {
            final decrypted = EncryptionService.simpleDecrypt(
                encryptedContent, _encryptionKey!);
            if (decrypted.isNotEmpty && decrypted.trim().isNotEmpty) {
              try {
                final List<dynamic> cloudAccounts = jsonDecode(decrypted);
                cloudVersion = downloadResponse.data['version'] ?? 0;
                for (var a in cloudAccounts) {
                  cloudAccountsMap[a['id']] = a;
                }
                if (downloadResponse.data['deleted_accounts'] != null) {
                  cloudDeletedAccounts = List<String>.from(
                      jsonDecode(downloadResponse.data['deleted_accounts']));
                }
                print('Cloud has ${cloudAccounts.length} accounts');
              } catch (jsonError) {
                print('Failed to parse cloud JSON: $jsonError');
              }
            }
          }
        }
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          print('No cloud data yet - this is normal for new users');
        } else {
          print('Download error: ${e.message}');
        }
      }

      // STEP 2: Fetch tombstones
      final tombstones = await _fetchTombstones();
      print('Tombstones: $tombstones');

      // STEP 3: Get local accounts (skip tombstones)
      final userId = await _getCurrentUserId();
      final localAccountsMap = <String, dynamic>{};
      for (var a in userBox.values) {
        if (tombstones.contains(a.id)) {
          await userBox.delete(a.id);
          continue;
        }
        localAccountsMap[a.id] = a;
      }
      print('Local has ${localAccountsMap.length} accounts');

      // STEP 4: Merge cloud accounts into local if not already present
      int addedFromCloud = 0;
      for (var entry in cloudAccountsMap.entries) {
        final id = entry.key;
        if (tombstones.contains(id)) continue;
        if (!localAccountsMap.containsKey(id) && !userBox.containsKey(id)) {
          final a = entry.value;
          // ── FIX: secret from cloud is PLAIN, encrypt with local key ──
          final plainSecret = a['secret'] as String;
          final localEncryptedSecret = EncryptionService.encryptSecret(plainSecret, userId);

          final newAcc = OTPAccount(
            id: id,
            service: a['service'],
            secret: localEncryptedSecret, // encrypted with THIS device's key
            issuer: a['issuer'],
            createdAt: DateTime.parse(a['createdAt']),
            userId: userId,
          );
          await userBox.put(id, newAcc);
          addedFromCloud++;
        }
      }
      print('Added $addedFromCloud accounts from cloud');

      // STEP 5: Upload merged data
      // ── FIX: decrypt each secret before uploading so cloud always has PLAIN secrets ──
      final finalData = await Future.wait(
        userBox.values
            .where((a) => !tombstones.contains(a.id))
            .map((a) async {
          final plainSecret = await _decryptSecretForUpload(a.secret);
          return {
            'id': a.id,
            'service': a.service,
            'secret': plainSecret, // PLAIN secret in the cloud envelope
            'issuer': a.issuer,
            'createdAt': a.createdAt.toIso8601String(),
          };
        }).toList(),
      );

      final encrypted = EncryptionService.simpleEncrypt(
          jsonEncode(finalData), _encryptionKey!);
      final newVersion = cloudVersion + 1;

      final uploadResponse = await _dio.post('sync/sync/', data: {
        'data_type': 'otp_accounts',
        'encrypted_content': encrypted,
        'version': newVersion,
        'device_id': deviceId,
        'deleted_accounts': jsonEncode(cloudDeletedAccounts),
      });

      if (uploadResponse.statusCode == 200) {
        print('Sync successful - ${finalData.length} accounts synced');
        return true;
      } else {
        print('Sync upload failed: ${uploadResponse.statusCode}');
        return false;
      }
    } catch (e) {
      print('syncAccounts error: $e');
      return false;
    }
  }

  // ─── 2FA / password helpers ───────────────────────────────────────────────
  Future<bool> send2FACode(String username, String password) async {
    try {
      final r = await _dio.post('send-2fa/',
          data: {'username': username, 'password': password});
      return r.data['success'] == true;
    } catch (e) {
      print('send2FA error: $e');
      return false;
    }
  }

  Future<bool> verify2FACode(String username, String code) async {
    try {
      final r = await _dio.post('verify-2fa/',
          data: {'username': username, 'code': code});
      return r.data['success'] == true;
    } catch (e) {
      print('verify2FA error: $e');
      return false;
    }
  }

  Future<bool> sendDeleteOtp(String username) async {
    await _updateAuthHeader();
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    if (token == null) {
      print('No token available for delete OTP');
      return false;
    }
    try {
      print('Sending delete OTP request with token...');
      final response = await _dio.post(
        'send-delete-otp/',
        data: {'username': username},
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        }),
      );
      print('Delete OTP response: ${response.data}');
      return response.data['success'] == true;
    } catch (e) {
      print('sendDeleteOtp error: $e');
      if (e is DioException) {
        print('Response status: ${e.response?.statusCode}');
        print('Response data: ${e.response?.data}');
      }
      return false;
    }
  }

  Future<bool> verifyDeleteOtp(String username, String code) async {
    await _updateAuthHeader();
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    if (token == null) {
      print('No token available for verify delete OTP');
      return false;
    }
    try {
      print('Verifying delete OTP...');
      final response = await _dio.post(
        'verify-delete-otp/',
        data: {'username': username, 'code': code},
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        }),
      );
      return response.data['success'] == true;
    } catch (e) {
      print('verifyDeleteOtp error: $e');
      return false;
    }
  }

  Future<bool> changePassword(String currentPassword, String newPassword) async {
    await _updateAuthHeader();
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    if (token == null) return false;
    try {
      final r = await _dio.post('auth/change_password/', data: {
        'current_password': currentPassword,
        'new_password': newPassword,
      });
      return r.statusCode == 200;
    } catch (e) {
      print('changePassword error: $e');
      return false;
    }
  }

  Future<bool> sendPasswordResetCode(String email) async {
    try {
      final r = await _dio.post('send-reset-code/', data: {'email': email});
      return r.data['success'] == true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> resetPassword(
      String email, String code, String newPassword) async {
    try {
      final r = await _dio.post('reset-password/', data: {
        'email': email,
        'code': code,
        'new_password': newPassword,
      });
      return r.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
    await prefs.remove('current_user');
    await prefs.remove('user_email');
    await prefs.remove('user_id');
    _encryptionKey = null;
    _dio.options.headers.remove('Authorization');
  }

  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    return token != null && token.isNotEmpty;
  }

  Future<String?> getCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('current_user');
  }
}