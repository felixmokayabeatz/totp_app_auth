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
    return prefs.getBool(_syncEnabledKey) ?? true; // default ON
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

  /// Delete locally only. Other devices are untouched.
  Future<void> deleteAccountLocalOnly(String accountId) async {
    final userBox = await _getUserBox();
    await userBox.delete(accountId);
    print('Deleted $accountId locally only');
  }

  /// Delete everywhere:
  ///   1. Mark the account as a tombstone on the server so any device that
  ///      tries to sync it back gets rejected and the server strips it.
  ///   2. Remove from local box.
  Future<bool> deleteAccountEverywhere(String accountId) async {
    await _updateAuthHeader();
    try {
      // Tell server: tombstone this account ID
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

  /// Delete all accounts locally only.
  Future<void> deleteAllLocalOnly() async {
    final userBox = await _getUserBox();
    await userBox.clear();
    print('Cleared all accounts locally');
  }

  /// Delete all accounts everywhere (server tombstones all, local cleared).
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

  // ─── Sync ─────────────────────────────────────────────────────────────────
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
        final decrypted = EncryptionService.simpleDecrypt(
          response.data['encrypted_content'], _encryptionKey!);
        final List<dynamic> cloudAccounts = jsonDecode(decrypted);
        final userBox = await _getUserBox();

        // Fetch tombstoned IDs so we never re-add them
        final tombstones = await _fetchTombstones();

        int added = 0;
        for (var ca in cloudAccounts) {
          final id = ca['id'] as String;
          if (tombstones.contains(id)) continue; // skip tombstoned
          if (!userBox.containsKey(id)) {
            final newAccount = OTPAccount(
              id: id,
              service: ca['service'],
              secret: ca['secret'],
              issuer: ca['issuer'],
              createdAt: DateTime.parse(ca['createdAt']),
              userId: await _getCurrentUserId(),
            );
            await userBox.put(newAccount.id, newAccount);
            added++;
          }
        }
        print('Merged $added accounts from cloud');
        await syncAccounts();
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

  Future<bool> syncAccounts() async {
    // Respect sync-enabled preference
    if (!(await isSyncEnabled())) {
      print('Sync disabled by user preference');
      return true; // not an error
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
      // 1. Download
      final downloadResponse = await _requestWithRetry(() => _dio.get(
        'sync/get-data/',
        queryParameters: {'data_type': 'otp_accounts', 'device_id': deviceId},
      ));

      Map<String, dynamic> cloudAccountsMap = {};
      int cloudVersion = 0;

      if (downloadResponse.statusCode == 200 &&
          downloadResponse.data['encrypted_content'] != null) {
        final decrypted = EncryptionService.simpleDecrypt(
          downloadResponse.data['encrypted_content'], _encryptionKey!);
        final List<dynamic> cloudAccounts = jsonDecode(decrypted);
        cloudVersion = downloadResponse.data['version'] ?? 0;
        for (var a in cloudAccounts) {
          cloudAccountsMap[a['id']] = a;
        }
      }

      // 2. Fetch tombstones so we don't re-add deleted accounts
      final tombstones = await _fetchTombstones();

      // 3. Merge: local wins for new, cloud fills in missing, tombstones excluded
      final localMap = <String, dynamic>{};
      for (var a in userBox.values) {
        if (tombstones.contains(a.id)) {
          // Server says this is deleted everywhere – remove locally too
          await userBox.delete(a.id);
          continue;
        }
        localMap[a.id] = {
          'id': a.id,
          'service': a.service,
          'secret': a.encryptedSecret,
          'issuer': a.issuer,
          'createdAt': a.createdAt.toIso8601String(),
        };
      }

      for (var entry in cloudAccountsMap.entries) {
        final id = entry.key;
        if (tombstones.contains(id)) continue; // server tombstoned
        if (!localMap.containsKey(id) && !userBox.containsKey(id)) {
          // New from cloud – add locally
          final a = entry.value;
          final newAcc = OTPAccount(
            id: id,
            service: a['service'],
            secret: a['secret'],
            issuer: a['issuer'],
            createdAt: DateTime.parse(a['createdAt']),
            userId: await _getCurrentUserId(),
          );
          await userBox.put(id, newAcc);
          localMap[id] = a;
        }
      }

      // 4. Upload merged set
      final finalData = userBox.values
          .where((a) => !tombstones.contains(a.id))
          .map((a) => {
                'id': a.id,
                'service': a.service,
                'secret': a.encryptedSecret,
                'issuer': a.issuer,
                'createdAt': a.createdAt.toIso8601String(),
              })
          .toList();

      final encrypted = EncryptionService.simpleEncrypt(
          jsonEncode(finalData), _encryptionKey!);

      final uploadResponse = await _dio.post('sync/sync/', data: {
        'data_type': 'otp_accounts',
        'encrypted_content': encrypted,
        'version': cloudVersion + 1,
        'device_id': deviceId,
      });

      return uploadResponse.statusCode == 200;
    } catch (e) {
      print('syncAccounts error: $e');
      return false;
    }
  }

  // ─── 2FA / password helpers ───────────────────────────────────────────────
  Future<bool> send2FACode(String username, String password) async {
    try {
      final r = await _dio.post('send-2fa/', data: {'username': username, 'password': password});
      return r.data['success'] == true;
    } catch (e) { print('send2FA error: $e'); return false; }
  }

  Future<bool> verify2FACode(String username, String code) async {
    try {
      final r = await _dio.post('verify-2fa/', data: {'username': username, 'code': code});
      return r.data['success'] == true;
    } catch (e) { print('verify2FA error: $e'); return false; }
  }

  Future<bool> sendDeleteOtp(String username) async {
    try {
      final r = await _dio.post('send-delete-otp/', data: {'username': username});
      return r.data['success'] == true;
    } catch (e) { print('sendDeleteOtp error: $e'); return false; }
  }

  Future<bool> verifyDeleteOtp(String username, String code) async {
    try {
      final r = await _dio.post('verify-delete-otp/', data: {'username': username, 'code': code});
      return r.data['success'] == true;
    } catch (e) { print('verifyDeleteOtp error: $e'); return false; }
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
    } catch (e) { print('changePassword error: $e'); return false; }
  }

  Future<bool> sendPasswordResetCode(String email) async {
    try {
      final r = await _dio.post('send-reset-code/', data: {'email': email});
      return r.data['success'] == true;
    } catch (e) { return false; }
  }

  Future<bool> resetPassword(String email, String code, String newPassword) async {
    try {
      final r = await _dio.post('reset-password/', data: {
        'email': email, 'code': code, 'new_password': newPassword,
      });
      return r.statusCode == 200;
    } catch (e) { return false; }
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