import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/otp_account.dart';
import 'encryption_service.dart';
import 'otp_service.dart';
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
  String? _lastErrorMessage;

  String? get lastErrorMessage => _lastErrorMessage;

  // ─── Sync-enabled preference key ─────────────────────────────────────────
  static const _syncEnabledKey = 'sync_to_cloud_enabled';

  // ─── Encryption key storage in Hive ──────────────────────────────────────
  Future<void> _storeEncryptionKey(String key) async {
    final box = await Hive.openBox('secure_data');
    await box.put('encryption_key', key);
  }

  Future<String?> _getStoredEncryptionKey() async {
    final box = await Hive.openBox('secure_data');
    return box.get('encryption_key');
  }

  Future<bool> _ensureEncryptionKeyAvailable() async {
    if (_encryptionKey != null && _encryptionKey!.isNotEmpty) {
      return true;
    }
    return restoreEncryptionKey();
  }

  Future<void> _clearStoredEncryptionKey() async {
    final box = await Hive.openBox('secure_data');
    await box.delete('encryption_key');
  }

  // ─── Sync preference ──────────────────────────────────────────────────────
  Future<bool> isSyncEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_syncEnabledKey) ?? true;
  }

  Future<void> setSyncEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_syncEnabledKey, value);

    try {
      await _updateAuthHeader();
      await _dio.post('sync-preference/', data: {'sync_enabled': value});
      print('Sync preference pushed to server: $value');
    } catch (e) {
      print('Failed to push sync preference: $e');
    }
  }

  Future<void> refreshSyncPreferenceFromServer() async {
    try {
      await _updateAuthHeader();
      final response = await _dio.get('sync-preference/get/');
      if (response.statusCode == 200) {
        final serverValue = response.data['sync_enabled'] as bool;
        final prefs = await SharedPreferences.getInstance();
        final localValue = prefs.getBool(_syncEnabledKey) ?? true;
        if (serverValue != localValue) {
          await prefs.setBool(_syncEnabledKey, serverValue);
          print('Sync preference updated from server: $serverValue');
        }
      }
    } catch (e) {
      print('Failed to fetch sync preference: $e');
    }
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

  String _decodeLegacySecretForMigration(
      String storedSecret, String currentUserId) {
    final strippedSpaces = storedSecret.replaceAll(RegExp(r'\s+'), '');
    final isRawBase32 = RegExp(r'^[A-Z2-7a-z]+$').hasMatch(strippedSpaces);
    if (isRawBase32) {
      return storedSecret;
    }

    final candidateUserIds = <String>[
      currentUserId,
      'default_user',
    ];

    for (final userId in candidateUserIds) {
      try {
        final plainSecret =
            EncryptionService.decryptSecret(storedSecret, userId);
        final cleanPlainSecret =
            plainSecret.replaceAll(RegExp(r'\s+'), '').toUpperCase();
        if (RegExp(r'^[A-Z2-7]+$').hasMatch(cleanPlainSecret)) {
          return plainSecret;
        }
      } catch (_) {}
    }

    return storedSecret;
  }

  Future<void> migrateLegacyLocalAccounts() async {
    final targetBoxName = await _getUserBoxName();
    final targetBox = await _getUserBox();
    final currentUserId = await _getCurrentUserId();
    final legacyBoxNames = <String>{
      'otp_accounts',
      'otp_accounts_default',
    };

    int migratedCount = 0;

    for (final boxName in legacyBoxNames) {
      if (boxName == targetBoxName) continue;

      Box<OTPAccount> sourceBox;
      try {
        sourceBox = Hive.isBoxOpen(boxName)
            ? Hive.box<OTPAccount>(boxName)
            : await Hive.openBox<OTPAccount>(boxName);
      } catch (_) {
        continue;
      }

      for (final account in sourceBox.values) {
        if (targetBox.containsKey(account.id)) continue;
        final plainSecret =
            _decodeLegacySecretForMigration(account.secret, currentUserId);
        final migratedAccount = OTPAccount(
          id: account.id,
          service: account.service,
          secret: plainSecret,
          issuer: account.issuer,
          createdAt: account.createdAt,
          userId: currentUserId,
        );
        await targetBox.put(account.id, migratedAccount);
        migratedCount++;
      }
    }

    if (migratedCount > 0) {
      print('Migrated $migratedCount local accounts into $targetBoxName');
    }
  }

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
    if (refreshToken == null) {
      _isRefreshing = false;
      return false;
    }
    try {
      final response =
          await _dio.post('token/refresh/', data: {'refresh': refreshToken});
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

  Future<Response> _requestWithRetry(
      Future<Response> Function() request) async {
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

  // ─── Encryption init ──────────────────────────────────────────────────────
  void _initEncryption(String username, String password) {
    if (_encryptionKey != null) return;
    _encryptionKey = EncryptionService.generateKey(
      username + password,
      'beatzLockKenya2099',
    );
  }

  Future<String> _getCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('current_user') ?? 'default_user';
  }

  // ─── Decrypt local secret back to plain for uploading ────────────────────
  Future<String> _decryptSecretForUpload(String storedSecret) async {
    final strippedSpaces = storedSecret.replaceAll(RegExp(r'\s+'), '');
    final isRawBase32 = RegExp(r'^[A-Z2-7a-z]+$').hasMatch(strippedSpaces);
    if (isRawBase32) return storedSecret;
    try {
      final userId = await _getCurrentUserId();
      return EncryptionService.decryptSecret(storedSecret, userId);
    } catch (e) {
      return storedSecret;
    }
  }

  // ─── Register ─────────────────────────────────────────────────────────────
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
        await prefs.setString(
            'user_id', response.data['user']['id'].toString());
        OTPService().clearCachedUserId();
        await _updateAuthHeader();
        _initEncryption(username, password);
        return true;
      }
      return false;
    } catch (e) {
      print('Register error: $e');
      return false;
    }
  }

  // ─── Login ────────────────────────────────────────────────────────────────
  Future<bool> login(String username, String password) async {
    try {
      _lastErrorMessage = null;
      final response = await _dio.post('auth/login/', data: {
        'username': username.trim(),
        'password': password,
      });
      if (response.statusCode == 200) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('access_token', response.data['access']);
        await prefs.setString('refresh_token', response.data['refresh']);
        await prefs.setString('current_user', username);
        await prefs.setString(
            'user_email', response.data['user']['email'] ?? '');
        await prefs.setString(
            'user_id', response.data['user']['id'].toString());
        OTPService().clearCachedUserId();
        await _updateAuthHeader();

        // Treat successful token issuance as a successful login.
        final encryptionKey = EncryptionService.generateKey(
            username + password, 'beatzLockKenya2099');

        await _storeEncryptionKey(encryptionKey);
        _encryptionKey = encryptionKey;

        try {
          await migrateLegacyLocalAccounts();
        } catch (e) {
          print('Legacy account migration error after login: $e');
        }

        try {
          final userBox = await _getUserBox();
          print(
              'User box ${await _getUserBoxName()} has ${userBox.length} accounts');
        } catch (e) {
          print('User box load error after login: $e');
        }

        try {
          if (await isSyncEnabled()) {
            await downloadAndMergeAccounts();
          }
        } catch (e) {
          print('Cloud restore error after login: $e');
        }

        return true;
      }
      return false;
    } on DioException catch (e) {
      _lastErrorMessage = e.response?.data?['error']?.toString() ??
          'Login failed. Please try again.';
      print('Login error: $e');
      return false;
    } catch (e) {
      _lastErrorMessage = 'Login failed. Please try again.';
      print('Login error: $e');
      return false;
    }
  }

  // ─── Restore encryption key on app restart ───────────────────────────────
  Future<bool> restoreEncryptionKey() async {
    final storedKey = await _getStoredEncryptionKey();
    if (storedKey != null && storedKey.isNotEmpty) {
      _encryptionKey = storedKey;
      print('Encryption key restored from Hive');
      return true;
    }
    print('No stored encryption key found');
    return false;
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

    if (!await _ensureEncryptionKeyAvailable()) {
      print('Encryption key not set - user must log in first');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    String deviceId = prefs.getString('device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
      await prefs.setString('device_id', deviceId);
    }

    try {
      final response = await _requestWithRetry(() => _dio.get(
            'sync/get-data/',
            queryParameters: {
              'data_type': 'otp_accounts',
              'device_id': deviceId
            },
          ));

      if (response.statusCode == 200 &&
          response.data['encrypted_content'] != null) {
        final encryptedContent = response.data['encrypted_content'];

        if (encryptedContent.toString().isEmpty) {
          print('Cloud has no data');
          return;
        }

        final decrypted =
            EncryptionService.simpleDecrypt(encryptedContent, _encryptionKey!);

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
              final newAccount = OTPAccount(
                id: id,
                service: ca['service'],
                secret: ca['secret'],
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
      final response =
          await _requestWithRetry(() => _dio.get('sync/tombstones/'));
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

    if (!await _ensureEncryptionKeyAvailable()) {
      _lastErrorMessage =
          'Cloud sync needs your saved encryption key. Log in again once on this device to restore sync.';
      print('Encryption key not set - user must log in first');
      return false;
    }

    final userBox = await _getUserBox();

    String deviceId = prefs.getString('device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
      await prefs.setString('device_id', deviceId);
    }

    try {
      Map<String, dynamic> cloudAccountsMap = {};
      int cloudVersion = 0;
      List<String> cloudDeletedAccounts = [];

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
          print('No cloud data yet - normal for new users');
        } else {
          print('Download error: ${e.message}');
        }
      }

      final tombstones = await _fetchTombstones();
      print('Tombstones: $tombstones');

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

      int addedFromCloud = 0;
      for (var entry in cloudAccountsMap.entries) {
        final id = entry.key;
        if (tombstones.contains(id)) continue;
        if (!localAccountsMap.containsKey(id) && !userBox.containsKey(id)) {
          final a = entry.value;
          final newAcc = OTPAccount(
            id: id,
            service: a['service'],
            secret: a['secret'],
            issuer: a['issuer'],
            createdAt: DateTime.parse(a['createdAt']),
            userId: userId,
          );
          await userBox.put(id, newAcc);
          addedFromCloud++;
        }
      }
      print('Added $addedFromCloud accounts from cloud');

      final finalData = await Future.wait(
        userBox.values.where((a) => !tombstones.contains(a.id)).map((a) async {
          final plainSecret = await _decryptSecretForUpload(a.secret);
          return {
            'id': a.id,
            'service': a.service,
            'secret': plainSecret,
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
      _lastErrorMessage = null;
      final r = await _dio.post('send-2fa/',
          data: {'username': username.trim(), 'password': password});
      return r.data['success'] == true;
    } on DioException catch (e) {
      _lastErrorMessage = e.response?.data?['error']?.toString() ??
          'Unable to send the verification code.';
      print('send2FA error: $e');
      return false;
    } catch (e) {
      _lastErrorMessage = 'Unable to send the verification code.';
      print('send2FA error: $e');
      return false;
    }
  }

  Future<bool> verify2FACode(String username, String code) async {
    try {
      _lastErrorMessage = null;
      final r = await _dio.post('verify-2fa/',
          data: {'username': username.trim(), 'code': code.trim()});
      return r.data['success'] == true;
    } on DioException catch (e) {
      _lastErrorMessage =
          e.response?.data?['error']?.toString() ?? 'Verification failed.';
      print('verify2FA error: $e');
      return false;
    } catch (e) {
      _lastErrorMessage = 'Verification failed.';
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
      final response = await _dio.post(
        'send-delete-otp/',
        data: {'username': username},
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        }),
      );
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
    if (token == null) return false;
    try {
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

  Future<bool> changePassword(
      String currentPassword, String newPassword) async {
    await _updateAuthHeader();
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    if (token == null) return false;

    final username = await _getCurrentUserId();

    try {
      final userBox = await _getUserBox();
      final tombstones = await _fetchTombstones();

      final plainAccounts = await Future.wait(
        userBox.values.where((a) => !tombstones.contains(a.id)).map((a) async {
          final plainSecret = await _decryptSecretForUpload(a.secret);
          return {
            'id': a.id,
            'service': a.service,
            'secret': plainSecret,
            'issuer': a.issuer,
            'createdAt': a.createdAt.toIso8601String(),
          };
        }).toList(),
      );

      final r = await _dio.post('auth/change_password/', data: {
        'current_password': currentPassword,
        'new_password': newPassword,
      });

      if (r.statusCode != 200) return false;

      _encryptionKey = null;
      _initEncryption(username, newPassword);

      for (var account in plainAccounts) {
        final id = account['id'] as String;
        if (userBox.containsKey(id)) {
          final existing = userBox.get(id)!;
          existing.setSecret(account['secret'] as String, username);
          await userBox.put(id, existing);
        }
      }

      final encrypted = EncryptionService.simpleEncrypt(
          jsonEncode(plainAccounts), _encryptionKey!);

      await _dio.post('sync/sync/', data: {
        'data_type': 'otp_accounts',
        'encrypted_content': encrypted,
        'version': DateTime.now().millisecondsSinceEpoch,
        'device_id': prefs.getString('device_id') ?? 'unknown',
        'deleted_accounts': '[]',
      });

      // Update stored encryption key
      await _storeEncryptionKey(_encryptionKey!);

      print('Password changed and data re-encrypted successfully');
      return true;
    } catch (e) {
      print('changePassword error: $e');
      return false;
    }
  }

  Future<bool> sendPasswordResetCode(String email) async {
    try {
      _lastErrorMessage = null;
      final r =
          await _dio.post('send-reset-code/', data: {'email': email.trim()});
      return r.data['success'] == true;
    } on DioException catch (e) {
      _lastErrorMessage = e.response?.data?['error']?.toString() ??
          'Unable to send reset code.';
      return false;
    } catch (e) {
      _lastErrorMessage = 'Unable to send reset code.';
      return false;
    }
  }

  Future<bool> resetPassword(
      String email, String code, String newPassword) async {
    try {
      _lastErrorMessage = null;
      final r = await _dio.post('reset-password/', data: {
        'email': email.trim(),
        'code': code.trim(),
        'new_password': newPassword,
      });
      return r.statusCode == 200;
    } on DioException catch (e) {
      _lastErrorMessage =
          e.response?.data?['error']?.toString() ?? 'Password reset failed.';
      return false;
    } catch (e) {
      _lastErrorMessage = 'Password reset failed.';
      return false;
    }
  }

  // ─── Logout ───────────────────────────────────────────────────────────────
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
    await prefs.remove('current_user');
    await prefs.remove('user_email');
    await prefs.remove('user_id');

    await _clearStoredEncryptionKey();

    _encryptionKey = null;
    OTPService().clearCachedUserId();
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
