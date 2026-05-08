import 'package:dio/dio.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../models/app_notification_item.dart';
import '../models/device_session_info.dart';
import '../models/otp_account.dart';
import 'encryption_service.dart';
import 'otp_service.dart';
import 'secure_storage_service.dart';
import '../config/app_config.dart';
import 'dart:convert';
import 'dart:io';

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
  static const MethodChannel _storageChannel =
      MethodChannel('com.beatzlock.otp/storage');
  Future<bool>? _refreshTokenFuture;
  String? _encryptionKey;
  String? _lastErrorMessage;
  final SecureStorageService _secureStorage = SecureStorageService();

  String? get lastErrorMessage => _lastErrorMessage;

  String? _extractServerError(dynamic data) {
    if (data is String && data.trim().isNotEmpty) {
      final trimmed = data.trim();
      final lower = trimmed.toLowerCase();
      if (lower.startsWith('<!doctype html') ||
          lower.startsWith('<html') ||
          lower.contains('<title>page not found')) {
        return null;
      }
      return trimmed;
    }

    if (data is List<int>) {
      try {
        final decoded = utf8.decode(data).trim();
        if (decoded.isEmpty) return null;
        try {
          return _extractServerError(jsonDecode(decoded));
        } catch (_) {
          final lower = decoded.toLowerCase();
          if (lower.startsWith('<!doctype html') ||
              lower.startsWith('<html') ||
              lower.contains('<title>page not found')) {
            return null;
          }
          return decoded;
        }
      } catch (_) {
        return null;
      }
    }

    if (data is Map<String, dynamic>) {
      for (final key in const ['error', 'detail', 'message']) {
        final value = data[key];
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }

      for (final value in data.values) {
        if (value is List && value.isNotEmpty && value.first is String) {
          final first = (value.first as String).trim();
          if (first.isNotEmpty) return first;
        }
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
    }

    return null;
  }

  String _normalizeAuthError(String message, {int? statusCode}) {
    final normalized = message.toLowerCase();

    if (statusCode == 401 ||
        normalized.contains('invalid credential') ||
        normalized.contains('invalid username or password') ||
        normalized.contains('no active account found')) {
      return 'Invalid username or password.';
    }

    return message;
  }

  String _friendlyRequestError(DioException error, String fallback) {
    final statusCode = error.response?.statusCode;
    final serverError = _extractServerError(error.response?.data);
    if (serverError != null && serverError.isNotEmpty) {
      return _normalizeAuthError(serverError, statusCode: statusCode);
    }

    final rawError = error.error?.toString() ?? '';

    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Connection timed out. Check your internet connection, firewall, or proxy on this device.';
      case DioExceptionType.connectionError:
        if (rawError.contains('Failed host lookup')) {
          return 'Could not reach the server. This device may have a DNS or internet issue.';
        }
        if (rawError.contains('HandshakeException') ||
            rawError.toLowerCase().contains('certificate')) {
          return 'Secure connection failed. Check this device date/time, antivirus HTTPS filtering, or certificate trust.';
        }
        return 'Could not reach the server. Check your internet connection, firewall, or proxy on this device.';
      case DioExceptionType.badCertificate:
        return 'Secure connection failed. This device may not trust the server certificate.';
      case DioExceptionType.badResponse:
        final status = statusCode;
        if (status == 401) {
          return 'Invalid username or password.';
        }
        if (status == 403) {
          return 'You are not authorized to perform this action.';
        }
        if (status == 404) {
          return 'Auth endpoint not found. Make sure the OTP backend is running, not just the update server.';
        }
        if (status == 500) {
          return 'Server error while processing the request. Please try again.';
        }
        return fallback;
      case DioExceptionType.cancel:
        return 'Request was cancelled.';
      case DioExceptionType.unknown:
        if (rawError.contains('HandshakeException') ||
            rawError.toLowerCase().contains('certificate')) {
          return 'Secure connection failed. Check this device date/time, antivirus HTTPS filtering, or certificate trust.';
        }
        if (rawError.contains('Failed host lookup')) {
          return 'Could not reach the server. This device may have a DNS or internet issue.';
        }
        return fallback;
    }
  }

  // ─── Sync-enabled preference key ─────────────────────────────────────────
  static const _syncEnabledKey = 'sync_to_cloud_enabled';

  // ─── Encryption key storage in Hive ──────────────────────────────────────
  Future<void> _storeEncryptionKey(String key) async {
    await _secureStorage.write(SecureStorageService.encryptionKey, key);
  }

  Future<String?> _getStoredEncryptionKey() async {
    return _secureStorage.read(SecureStorageService.encryptionKey);
  }

  Future<bool> _ensureEncryptionKeyAvailable() async {
    if (_encryptionKey != null && _encryptionKey!.isNotEmpty) {
      return true;
    }
    return restoreEncryptionKey();
  }

  Future<void> _clearStoredEncryptionKey() async {
    await _secureStorage.delete(SecureStorageService.encryptionKey);
  }

  // ─── Sync preference ──────────────────────────────────────────────────────
  Future<bool> isSyncEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final storedValue = prefs.getBool(_syncEnabledKey);
    if (storedValue != null) {
      return storedValue;
    }
    return isLoggedIn();
  }

  Future<void> setSyncEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value && !await isLoggedIn()) {
      _lastErrorMessage = 'Sign in to enable automatic cross-platform sync.';
      await prefs.setBool(_syncEnabledKey, false);
      return;
    }

    await prefs.setBool(_syncEnabledKey, value);

    try {
      await _updateAuthHeader();
      await _dio.post('sync-preference/', data: {'sync_enabled': value});
      debugPrint('Sync preference pushed to server: $value');
    } catch (e) {
      debugPrint('Failed to push sync preference: $e');
    }
  }

  Future<void> refreshSyncPreferenceFromServer() async {
    if (!await isLoggedIn()) {
      return;
    }

    try {
      await _updateAuthHeader();
      final response = await _dio.get('sync-preference/get/');
      if (response.statusCode == 200) {
        final serverValue = response.data['sync_enabled'] as bool;
        final prefs = await SharedPreferences.getInstance();
        final localValue = prefs.getBool(_syncEnabledKey) ?? await isLoggedIn();
        if (serverValue != localValue) {
          await prefs.setBool(_syncEnabledKey, serverValue);
          debugPrint('Sync preference updated from server: $serverValue');
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch sync preference: $e');
    }
  }

  // ─── Box helpers ──────────────────────────────────────────────────────────
  Future<String> _getUserBoxName() async {
    final username =
        await _secureStorage.read(SecureStorageService.currentUserKey) ??
            await _secureStorage.read(SecureStorageService.localVaultUserKey);
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
    final storedUsername =
        await _secureStorage.read(SecureStorageService.currentUserKey) ?? '';
    final localVaultUsername =
        await _secureStorage.read(SecureStorageService.localVaultUserKey) ?? '';
    final storedUserId =
        await _secureStorage.read(SecureStorageService.userIdKey) ?? '';
    final storedEmail =
        await _secureStorage.read(SecureStorageService.userEmailKey) ?? '';
    final legacyBoxNames = <String>{
      'otp_accounts',
      'otp_accounts_default',
      if (storedUsername.isNotEmpty) 'otp_accounts_$storedUsername',
      if (localVaultUsername.isNotEmpty) 'otp_accounts_$localVaultUsername',
      if (storedUserId.isNotEmpty) 'otp_accounts_$storedUserId',
      if (storedEmail.isNotEmpty) 'otp_accounts_$storedEmail',
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
          accountLabel: account.accountLabel,
          createdAt: account.createdAt,
          userId: currentUserId,
        );
        await targetBox.put(account.id, migratedAccount);
        migratedCount++;
      }
    }

    if (migratedCount > 0) {
      debugPrint('Migrated $migratedCount local accounts into $targetBoxName');
    }
  }

  // ─── Auth helpers ─────────────────────────────────────────────────────────
  Future<void> _updateAuthHeader() async {
    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    final deviceId = await getOrCreateDeviceId();
    final deviceLabel = await _buildDeviceLabel();
    if (token != null && token.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $token';
    } else {
      _dio.options.headers.remove('Authorization');
    }
    _dio.options.headers['X-Device-ID'] = deviceId;
    _dio.options.headers['X-Device-Label'] = deviceLabel;
  }

  bool _isSessionRevokedError(DioException error) {
    final data = error.response?.data;
    final message = _extractServerError(data)?.toLowerCase() ?? '';

    if (data is Map) {
      final code = data['code']?.toString().toLowerCase() ?? '';
      if (code == 'session_revoked') {
        return true;
      }
    }

    return message.contains('session has been signed out') ||
        message.contains('device session has been signed out');
  }

  Future<bool> _performTokenRefresh() async {
    final refreshToken =
        await _secureStorage.read(SecureStorageService.refreshTokenKey);
    if (refreshToken == null || refreshToken.isEmpty) {
      return false;
    }
    try {
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final refreshDio = Dio(BaseOptions(
        baseUrl: AppConfig.apiUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
        headers: {
          'Content-Type': 'application/json',
          'X-Device-ID': deviceId,
          'X-Device-Label': deviceLabel,
        },
      ));
      final response = await refreshDio.post(
        'token/refresh/',
        data: {'refresh': refreshToken},
      );
      if (response.statusCode == 200) {
        await _secureStorage.write(
            SecureStorageService.accessTokenKey, response.data['access']);
        await _updateAuthHeader();
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<bool> _refreshToken() async {
    final existingRefresh = _refreshTokenFuture;
    if (existingRefresh != null) {
      return existingRefresh;
    }

    final refreshFuture = _performTokenRefresh();
    _refreshTokenFuture = refreshFuture;

    try {
      return await refreshFuture;
    } finally {
      if (identical(_refreshTokenFuture, refreshFuture)) {
        _refreshTokenFuture = null;
      }
    }
  }

  Future<Response<T>> _requestWithRetry<T>(
    Future<Response<T>> Function(String accessToken) request, {
    bool clearSessionOnRefreshFailure = true,
  }) async {
    Future<Response<T>> runRequest() async {
      await _updateAuthHeader();
      final accessToken =
          await _secureStorage.read(SecureStorageService.accessTokenKey);
      if (accessToken == null || accessToken.isEmpty) {
        throw StateError('Missing access token for authenticated request.');
      }
      return request(accessToken);
    }

    try {
      return await runRequest();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        final refreshed = await _refreshToken();
        if (refreshed) return await runRequest();
        if (clearSessionOnRefreshFailure || _isSessionRevokedError(e)) {
          await logout(notifyServer: false);
        }
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
    return await _secureStorage.read(SecureStorageService.currentUserKey) ??
        await _secureStorage.read(SecureStorageService.localVaultUserKey) ??
        'default_user';
  }

  Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString('device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
      await prefs.setString('device_id', deviceId);
    }
    return deviceId;
  }

  Future<String?> _friendlyMobileDeviceName() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        final brand = info.brand.trim();
        final model = info.model.trim();
        if (brand.isNotEmpty && model.isNotEmpty) {
          return '$brand $model';
        }
        if (model.isNotEmpty) return model;
      }

      if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        final ownerName = info.name.trim();
        if (ownerName.isNotEmpty &&
            ownerName.toLowerCase() != 'iphone' &&
            ownerName.toLowerCase() != 'ipad') {
          return ownerName;
        }
        final model = info.model.trim();
        if (model.isNotEmpty) return model;
      }
    } catch (_) {}

    return null;
  }

  Future<String> _buildDeviceLabel() async {
    final prefs = await SharedPreferences.getInstance();
    final savedDeviceId = prefs.getString('device_id');
    String? hostname;
    final mobileName = await _friendlyMobileDeviceName();

    try {
      hostname = Platform.localHostname.trim();
    } catch (_) {
      hostname = null;
    }

    final operatingSystem = Platform.operatingSystem;
    final prettyOs = operatingSystem.isEmpty
        ? 'Device'
        : '${operatingSystem[0].toUpperCase()}${operatingSystem.substring(1)}';
    final normalizedHostname = hostname?.toLowerCase();
    final hasUsefulHostname = hostname != null &&
        hostname.isNotEmpty &&
        normalizedHostname != 'localhost' &&
        normalizedHostname != 'localhost.localdomain' &&
        normalizedHostname != 'android';

    if (mobileName != null && mobileName.isNotEmpty) {
      return mobileName;
    }

    if (hasUsefulHostname) {
      return '$prettyOs - $hostname';
    }

    if (savedDeviceId != null && savedDeviceId.isNotEmpty) {
      final shortenedId = savedDeviceId.length > 8
          ? savedDeviceId.substring(savedDeviceId.length - 8)
          : savedDeviceId;
      return '$prettyOs - $shortenedId';
    }

    return prettyOs;
  }

  Future<String> getCurrentDeviceLabel() async {
    return _buildDeviceLabel();
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
      _lastErrorMessage = null;
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _dio.post('auth/register/', data: {
        'username': username,
        'email': email,
        'password': password,
        'device_id': deviceId,
        'device_label': deviceLabel,
      });
      if (response.statusCode == 200 || response.statusCode == 201) {
        final canonicalUsername =
            response.data['user']?['username']?.toString() ?? username.trim();
        await _secureStorage.write(
            SecureStorageService.accessTokenKey, response.data['access']);
        await _secureStorage.write(
            SecureStorageService.refreshTokenKey, response.data['refresh']);
        await _secureStorage.write(
            SecureStorageService.currentUserKey, canonicalUsername);
        await _secureStorage.write(
            SecureStorageService.localVaultUserKey, canonicalUsername);
        await _secureStorage.write(SecureStorageService.userEmailKey, email);
        await _secureStorage.write(SecureStorageService.userIdKey,
            response.data['user']['id'].toString());
        OTPService().clearCachedUserId();
        await _updateAuthHeader();
        _initEncryption(canonicalUsername, password);
        await setSyncEnabled(true);
        return true;
      }
      _lastErrorMessage = 'Registration failed. Please try again.';
      return false;
    } on DioException catch (e) {
      _lastErrorMessage =
          _friendlyRequestError(e, 'Registration failed. Please try again.');
      debugPrint('Register error: $e');
      return false;
    } catch (e) {
      _lastErrorMessage = 'Registration failed. Please try again.';
      debugPrint('Register error: $e');
      return false;
    }
  }

  // ─── Login ────────────────────────────────────────────────────────────────
  Future<bool> login(String username, String password) async {
    try {
      _lastErrorMessage = null;
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _dio.post('auth/login/', data: {
        'username': username.trim(),
        'password': password,
        'device_id': deviceId,
        'device_label': deviceLabel,
      });
      if (response.statusCode == 200) {
        final canonicalUsername =
            response.data['user']?['username']?.toString() ?? username.trim();
        await _secureStorage.write(
            SecureStorageService.accessTokenKey, response.data['access']);
        await _secureStorage.write(
            SecureStorageService.refreshTokenKey, response.data['refresh']);
        await _secureStorage.write(
            SecureStorageService.currentUserKey, canonicalUsername);
        await _secureStorage.write(
            SecureStorageService.localVaultUserKey, canonicalUsername);
        await _secureStorage.write(SecureStorageService.userEmailKey,
            response.data['user']['email'] ?? '');
        await _secureStorage.write(SecureStorageService.userIdKey,
            response.data['user']['id'].toString());
        OTPService().clearCachedUserId();
        await _updateAuthHeader();

        // Treat successful token issuance as a successful login.
        final encryptionKey = EncryptionService.generateKey(
            canonicalUsername + password, 'beatzLockKenya2099');

        await _storeEncryptionKey(encryptionKey);
        _encryptionKey = encryptionKey;
        await setSyncEnabled(true);

        try {
          await migrateLegacyLocalAccounts();
        } catch (e) {
          debugPrint('Legacy account migration error after login: $e');
        }

        try {
          final userBox = await _getUserBox();
          debugPrint(
              'User box ${await _getUserBoxName()} has ${userBox.length} accounts');
        } catch (e) {
          debugPrint('User box load error after login: $e');
        }

        try {
          if (await isSyncEnabled()) {
            await downloadAndMergeAccounts();
          }
        } catch (e) {
          debugPrint('Cloud restore error after login: $e');
        }

        return true;
      }
      return false;
    } on DioException catch (e) {
      _lastErrorMessage =
          _friendlyRequestError(e, 'Login failed. Please try again.');
      debugPrint('Login error: $e');
      return false;
    } catch (e) {
      _lastErrorMessage = 'Login failed. Please try again.';
      debugPrint('Login error: $e');
      return false;
    }
  }

  // ─── Restore encryption key on app restart ───────────────────────────────
  Future<bool> restoreEncryptionKey() async {
    final storedKey = await _getStoredEncryptionKey();
    if (storedKey != null && storedKey.isNotEmpty) {
      _encryptionKey = storedKey;
      debugPrint('Encryption key restored from Hive');
      return true;
    }
    debugPrint('No stored encryption key found');
    return false;
  }

  // ─── Delete a single account ──────────────────────────────────────────────
  Future<void> deleteAccountLocalOnly(String accountId) async {
    final userBox = await _getUserBox();
    await userBox.delete(accountId);
    debugPrint('Deleted $accountId locally only');
  }

  Future<bool> deleteAccountEverywhere(String accountId) async {
    await _updateAuthHeader();
    try {
      final response = await _requestWithRetry((_) => _dio.post(
            'sync/delete-account/',
            data: {'account_id': accountId},
          ));
      if (response.statusCode == 200) {
        final userBox = await _getUserBox();
        await userBox.delete(accountId);
        debugPrint('Deleted $accountId everywhere');
        return true;
      }
      debugPrint('Server delete failed: ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('deleteAccountEverywhere error: $e');
      return false;
    }
  }

  // ─── Delete ALL accounts ──────────────────────────────────────────────────
  Future<void> deleteAllLocalOnly() async {
    final userBox = await _getUserBox();
    await userBox.clear();
    debugPrint('Cleared all accounts locally');
  }

  Future<bool> deleteAllEverywhere() async {
    await _updateAuthHeader();
    try {
      final response = await _requestWithRetry(
        (_) => _dio.post('sync/delete-all-accounts/'),
      );
      if (response.statusCode == 200) {
        final userBox = await _getUserBox();
        await userBox.clear();
        debugPrint('Deleted all accounts everywhere');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('deleteAllEverywhere error: $e');
      return false;
    }
  }

  // ─── Download and merge ───────────────────────────────────────────────────
  Future<void> downloadAndMergeAccounts() async {
    await _updateAuthHeader();
    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      return;
    }

    if (!await _ensureEncryptionKeyAvailable()) {
      debugPrint('Encryption key not set - user must log in first');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    String deviceId = prefs.getString('device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
      await prefs.setString('device_id', deviceId);
    }

    try {
      final response = await _requestWithRetry((_) => _dio.get(
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
          debugPrint('Cloud has no data');
          return;
        }

        final decrypted =
            EncryptionService.simpleDecrypt(encryptedContent, _encryptionKey!);

        if (decrypted.isEmpty || decrypted.trim().isEmpty) {
          debugPrint('Decrypted content is empty');
          return;
        }

        try {
          final List<dynamic> cloudAccounts = jsonDecode(decrypted);
          final userBox = await _getUserBox();
          final tombstones = await _fetchTombstones();
          final userId = await _getCurrentUserId();

          int added = 0;
          int updatedTitles = 0;
          for (var ca in cloudAccounts) {
            final id = ca['id'] as String;
            if (tombstones.contains(id)) continue;
            if (!userBox.containsKey(id)) {
              final newAccount = OTPAccount(
                id: id,
                service: ca['service'],
                secret: ca['secret'],
                issuer: ca['issuer'],
                accountLabel: ca['account_label'],
                createdAt: DateTime.parse(ca['createdAt']),
                userId: userId,
              );
              await userBox.put(newAccount.id, newAccount);
              added++;
              continue;
            }

            final existingAccount = userBox.get(id);
            final cloudService = ca['service'] as String?;
            final cloudIssuer = ca['issuer'] as String?;
            final cloudAccountLabel = ca['account_label'] as String?;
            if (existingAccount != null) {
              var changed = false;
              if (cloudService != null &&
                  existingAccount.service != cloudService) {
                existingAccount.service = cloudService;
                changed = true;
              }
              if (existingAccount.issuer != cloudIssuer) {
                existingAccount.issuer = cloudIssuer;
                changed = true;
              }
              if (existingAccount.accountLabel != cloudAccountLabel) {
                existingAccount.accountLabel = cloudAccountLabel;
                changed = true;
              }
              if (!changed) continue;
              await userBox.put(id, existingAccount);
              updatedTitles++;
            }
          }
          debugPrint(
              'Merged $added accounts from cloud and updated $updatedTitles titles');
          await syncAccounts();
        } catch (jsonError) {
          debugPrint('Failed to parse cloud JSON: $jsonError');
        }
      }
    } catch (e) {
      debugPrint('downloadAndMergeAccounts error: $e');
    }
  }

  Future<Set<String>> _fetchTombstones() async {
    try {
      final response =
          await _requestWithRetry((_) => _dio.get('sync/tombstones/'));
      if (response.statusCode == 200) {
        final List ids = response.data['tombstoned_ids'] ?? [];
        return ids.cast<String>().toSet();
      }
    } catch (_) {}
    return {};
  }

  // ─── Main sync ────────────────────────────────────────────────────────────
  Future<bool> syncAccounts({bool preferLocalTitleChanges = false}) async {
    if (!(await isSyncEnabled())) {
      debugPrint('Sync disabled by user preference');
      return true;
    }

    await _updateAuthHeader();
    final prefs = await SharedPreferences.getInstance();
    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'Sign in to enable automatic cross-platform sync.';
      return false;
    }

    if (!await _ensureEncryptionKeyAvailable()) {
      _lastErrorMessage =
          'Cloud sync needs your saved encryption key. Log in again once on this device to restore sync.';
      debugPrint('Encryption key not set - user must log in first');
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
        final downloadResponse = await _requestWithRetry((_) => _dio.get(
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
            debugPrint('Cloud has empty data');
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
                debugPrint('Cloud has ${cloudAccounts.length} accounts');
              } catch (jsonError) {
                debugPrint('Failed to parse cloud JSON: $jsonError');
              }
            }
          }
        }
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          debugPrint('No cloud data yet - normal for new users');
        } else {
          debugPrint('Download error: ${e.message}');
        }
      }

      final tombstones = await _fetchTombstones();
      debugPrint('Tombstones: $tombstones');

      final userId = await _getCurrentUserId();
      final localAccountsMap = <String, dynamic>{};
      for (var a in userBox.values) {
        if (tombstones.contains(a.id)) {
          await userBox.delete(a.id);
          continue;
        }
        localAccountsMap[a.id] = a;
      }
      debugPrint('Local has ${localAccountsMap.length} accounts');

      int addedFromCloud = 0;
      int updatedTitlesFromCloud = 0;
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
            accountLabel: a['account_label'],
            createdAt: DateTime.parse(a['createdAt']),
            userId: userId,
          );
          await userBox.put(id, newAcc);
          addedFromCloud++;
          continue;
        }

        if (!preferLocalTitleChanges) {
          final existingAccount = userBox.get(id);
          final cloudService = entry.value['service'] as String?;
          final cloudIssuer = entry.value['issuer'] as String?;
          final cloudAccountLabel = entry.value['account_label'] as String?;
          if (existingAccount != null) {
            var changed = false;
            if (cloudService != null &&
                existingAccount.service != cloudService) {
              existingAccount.service = cloudService;
              changed = true;
            }
            if (existingAccount.issuer != cloudIssuer) {
              existingAccount.issuer = cloudIssuer;
              changed = true;
            }
            if (existingAccount.accountLabel != cloudAccountLabel) {
              existingAccount.accountLabel = cloudAccountLabel;
              changed = true;
            }
            if (!changed) continue;
            await userBox.put(id, existingAccount);
            updatedTitlesFromCloud++;
          }
        }
      }
      debugPrint(
          'Added $addedFromCloud accounts from cloud and updated $updatedTitlesFromCloud titles');

      final finalData = await Future.wait(
        userBox.values.where((a) => !tombstones.contains(a.id)).map((a) async {
          final plainSecret = await _decryptSecretForUpload(a.secret);
          return {
            'id': a.id,
            'service': a.service,
            'secret': plainSecret,
            'issuer': a.issuer,
            'account_label': a.accountLabel,
            'createdAt': a.createdAt.toIso8601String(),
          };
        }).toList(),
      );

      final encrypted = EncryptionService.simpleEncrypt(
          jsonEncode(finalData), _encryptionKey!);
      final newVersion = cloudVersion + 1;

      final uploadResponse = await _requestWithRetry((_) => _dio.post(
            'sync/sync/',
            data: {
              'data_type': 'otp_accounts',
              'encrypted_content': encrypted,
              'version': newVersion,
              'device_id': deviceId,
              'deleted_accounts': jsonEncode(cloudDeletedAccounts),
            },
          ));

      if (uploadResponse.statusCode == 200) {
        debugPrint('Sync successful - ${finalData.length} accounts synced');
        return true;
      } else {
        debugPrint('Sync upload failed: ${uploadResponse.statusCode}');
        _lastErrorMessage = 'Sync upload failed. Please try again.';
        return false;
      }
    } on DioException catch (e) {
      _lastErrorMessage = e.response?.data?['error']?.toString() ??
          'Sync failed. Please sign in again if this device lost its session.';
      debugPrint('syncAccounts error: $e');
      return false;
    } catch (e) {
      _lastErrorMessage = 'Sync failed. Please try again.';
      debugPrint('syncAccounts error: $e');
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
      _lastErrorMessage = _friendlyRequestError(
        e,
        'Unable to send the verification code.',
      );
      debugPrint('send2FA error: $e');
      return false;
    } catch (e) {
      _lastErrorMessage = 'Unable to send the verification code.';
      debugPrint('send2FA error: $e');
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
      _lastErrorMessage = _friendlyRequestError(e, 'Verification failed.');
      debugPrint('verify2FA error: $e');
      return false;
    } catch (e) {
      _lastErrorMessage = 'Verification failed.';
      debugPrint('verify2FA error: $e');
      return false;
    }
  }

  Future<bool> sendDeleteOtp(String username) async {
    await _updateAuthHeader();
    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null) {
      debugPrint('No token available for delete OTP');
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
      debugPrint('sendDeleteOtp error: $e');
      if (e is DioException) {
        debugPrint('Response status: ${e.response?.statusCode}');
        debugPrint('Response data: ${e.response?.data}');
      }
      return false;
    }
  }

  Future<bool> verifyDeleteOtp(String username, String code) async {
    await _updateAuthHeader();
    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
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
      debugPrint('verifyDeleteOtp error: $e');
      return false;
    }
  }

  Future<bool> changePassword(
      String currentPassword, String newPassword) async {
    await _updateAuthHeader();
    final prefs = await SharedPreferences.getInstance();
    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null) return false;

    final username = await _getCurrentUserId();
    final deviceLabel = await _buildDeviceLabel();

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
            'account_label': a.accountLabel,
            'createdAt': a.createdAt.toIso8601String(),
          };
        }).toList(),
      );

      final r = await _dio.post('auth/change_password/', data: {
        'current_password': currentPassword,
        'new_password': newPassword,
        'device_label': deviceLabel,
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

      debugPrint('Password changed and data re-encrypted successfully');
      return true;
    } catch (e) {
      debugPrint('changePassword error: $e');
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
  Future<bool> verifyLoginWithRecoveryCode(
      String username, String password, String recoveryCode) async {
    try {
      _lastErrorMessage = null;
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _dio.post('recovery-code/login/', data: {
        'username': username.trim(),
        'password': password,
        'recovery_code': recoveryCode.trim(),
        'device_id': deviceId,
        'device_label': deviceLabel,
      });
      return response.data['success'] == true;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Recovery code verification failed.';
      return false;
    } catch (e) {
      _lastErrorMessage = 'Recovery code verification failed.';
      return false;
    }
  }

  Future<bool> checkRecoveryEmailExists(String email) async {
    try {
      _lastErrorMessage = null;
      final response = await _dio.post('recovery-code/check-email/', data: {
        'email': email.trim(),
      });
      return response.data['success'] == true;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'No account found with this email.';
      return false;
    } catch (e) {
      _lastErrorMessage = 'No account found with this email.';
      return false;
    }
  }

  Future<bool> resetPasswordWithRecoveryCode(
      String email, String recoveryCode, String newPassword) async {
    try {
      _lastErrorMessage = null;
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _dio.post('recovery-code/reset-password/', data: {
        'email': email.trim(),
        'recovery_code': recoveryCode.trim(),
        'new_password': newPassword,
        'device_id': deviceId,
        'device_label': deviceLabel,
      });
      if (response.data['success'] == true) {
        final canonicalUsername =
            response.data['user']?['username']?.toString() ?? '';
        await _secureStorage.write(
            SecureStorageService.accessTokenKey, response.data['access']);
        await _secureStorage.write(
            SecureStorageService.refreshTokenKey, response.data['refresh']);
        await _secureStorage.write(
            SecureStorageService.currentUserKey, canonicalUsername);
        await _secureStorage.write(SecureStorageService.userEmailKey,
            response.data['user']?['email']?.toString() ?? email.trim());
        await _secureStorage.write(SecureStorageService.userIdKey,
            response.data['user']?['id']?.toString() ?? '');
        OTPService().clearCachedUserId();
        await _updateAuthHeader();

        final encryptionKey = EncryptionService.generateKey(
            canonicalUsername + newPassword, 'beatzLockKenya2099');
        await _storeEncryptionKey(encryptionKey);
        _encryptionKey = encryptionKey;
        return true;
      }
      return false;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Password reset with recovery code failed.';
      return false;
    } catch (e) {
      _lastErrorMessage = 'Password reset with recovery code failed.';
      return false;
    }
  }

  Future<Map<String, dynamic>?> getBackupCodeStatus() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      _lastErrorMessage =
          'You need to be signed in to view recovery code status.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.get(
          'backup-codes/status/',
          options: Options(headers: {
            'Authorization': 'Bearer $accessToken',
          }),
        ),
      );

      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data as Map);
      }

      _lastErrorMessage = 'Could not load recovery code status.';
      return null;
    } on DioException catch (e) {
      _lastErrorMessage = _friendlyRequestError(
        e,
        'Could not load recovery code status.',
      );
      return null;
    } catch (e) {
      _lastErrorMessage = 'Could not load recovery code status.';
      return null;
    }
  }

  Future<Directory> _resolveBackupCodesDirectory() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
    }

    return await getApplicationDocumentsDirectory();
  }

  String _backupCodesFileName(String username) {
    final safeUsername = username.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final timestamp =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    return 'beatzlock_backup_codes_${safeUsername}_$timestamp.pdf';
  }

  Future<String> _saveBackupCodesPdf({
    required String fileName,
    required List<int> bytes,
  }) async {
    if (Platform.isAndroid) {
      final savedPath = await _storageChannel.invokeMethod<String>(
        'savePdfToDownloads',
        {
          'fileName': fileName,
          'bytes': Uint8List.fromList(bytes),
        },
      );
      if (savedPath == null || savedPath.isEmpty) {
        throw FileSystemException('Android Downloads save returned no path.');
      }
      return savedPath;
    }

    final directory = await _resolveBackupCodesDirectory();
    await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<String?> downloadBackupCodesPdf() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to download backup codes.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.get<List<int>>(
          'backup-codes/download/',
          options: Options(
            responseType: ResponseType.bytes,
            headers: {
              'Authorization': 'Bearer $accessToken',
            },
          ),
        ),
      );

      final bytes = response.data;
      if (response.statusCode != 200 || bytes == null || bytes.isEmpty) {
        _lastErrorMessage = 'Backup code PDF download failed.';
        return null;
      }

      final username =
          await _secureStorage.read(SecureStorageService.currentUserKey) ??
              'user';
      final fileName = _backupCodesFileName(username);
      return await _saveBackupCodesPdf(
        fileName: fileName,
        bytes: bytes,
      );
    } on DioException catch (e) {
      _lastErrorMessage = _friendlyRequestError(
        e,
        'Unable to download backup codes right now.',
      );
      return null;
    } catch (e) {
      _lastErrorMessage = 'Unable to save backup codes on this device.';
      return null;
    }
  }

  Future<List<AppNotificationItem>> getNotifications() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to view notifications.';
      return [];
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.get(
          'notifications/',
          options: Options(headers: {
            'Authorization': 'Bearer $accessToken',
          }),
        ),
      );

      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List)
            .whereType<Map>()
            .map((item) => AppNotificationItem.fromJson(
                  Map<String, dynamic>.from(item),
                ))
            .toList();
      }

      _lastErrorMessage = 'Could not load notifications.';
      return [];
    } on DioException catch (e) {
      _lastErrorMessage = _friendlyRequestError(
        e,
        'Could not load notifications.',
      );
      return [];
    } catch (e) {
      _lastErrorMessage = 'Could not load notifications.';
      return [];
    }
  }

  Future<AppNotificationItem?> getNotificationDetail(
      String notificationId) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to view notifications.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.get(
          'notifications/$notificationId/',
          options: Options(headers: {
            'Authorization': 'Bearer $accessToken',
          }),
        ),
      );

      if (response.statusCode == 200 && response.data is Map) {
        return AppNotificationItem.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
      }

      _lastErrorMessage = 'Could not load this notification.';
      return null;
    } on DioException catch (e) {
      _lastErrorMessage = _friendlyRequestError(
        e,
        'Could not load this notification.',
      );
      return null;
    } catch (e) {
      _lastErrorMessage = 'Could not load this notification.';
      return null;
    }
  }

  Future<int?> markAllNotificationsRead() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to manage notifications.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'notifications/mark-all-read/',
          options: Options(headers: {
            'Authorization': 'Bearer $accessToken',
          }),
        ),
      );

      if (response.statusCode == 200 && response.data is Map) {
        return int.tryParse(response.data['marked_count'].toString()) ?? 0;
      }

      _lastErrorMessage = 'Could not mark all notifications as read.';
      return null;
    } on DioException catch (e) {
      _lastErrorMessage = _friendlyRequestError(
        e,
        'Could not mark all notifications as read.',
      );
      return null;
    } catch (e) {
      _lastErrorMessage = 'Could not mark all notifications as read.';
      return null;
    }
  }

  Future<int?> clearNotifications({
    String? notificationType,
    int? olderThanDays,
    bool keepUnread = false,
  }) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to manage notifications.';
      return null;
    }

    final data = <String, dynamic>{
      'notification_type': notificationType ?? 'all',
      'keep_unread': keepUnread,
    };
    if (olderThanDays != null) {
      data['older_than_days'] = olderThanDays;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'notifications/clear/',
          data: data,
          options: Options(headers: {
            'Authorization': 'Bearer $accessToken',
          }),
        ),
      );

      if (response.statusCode == 200 && response.data is Map) {
        return int.tryParse(response.data['deleted_count'].toString()) ?? 0;
      }

      _lastErrorMessage = 'Could not clear notifications.';
      return null;
    } on DioException catch (e) {
      _lastErrorMessage = _friendlyRequestError(
        e,
        'Could not clear notifications.',
      );
      return null;
    } catch (e) {
      _lastErrorMessage = 'Could not clear notifications.';
      return null;
    }
  }

  Future<bool> logAccountAddedNotification({
    required String serviceName,
    String? accountLabel,
  }) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'notifications/log-event/',
          data: {
            'event_type': 'account_added',
            'service_name': serviceName,
            'account_label': accountLabel,
          },
          options: Options(headers: {
            'Authorization': 'Bearer $accessToken',
          }),
        ),
      );
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  Future<bool> logAppPinChangedNotification(
      {required String deviceLabel}) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'notifications/log-event/',
          data: {
            'event_type': 'app_pin_changed',
            'device_label': deviceLabel,
          },
          options: Options(headers: {
            'Authorization': 'Bearer $accessToken',
          }),
        ),
      );
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  Future<List<DeviceSessionInfo>> getActiveDeviceSessions() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to view active devices.';
      return [];
    }

    try {
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _requestWithRetry(
        (accessToken) => _dio.get(
          'device-sessions/',
          queryParameters: {
            'device_id': deviceId,
            'device_label': deviceLabel,
          },
          options: Options(headers: {
            'Authorization': 'Bearer $accessToken',
          }),
        ),
      );

      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List)
            .whereType<Map>()
            .map((item) => DeviceSessionInfo.fromJson(
                  Map<String, dynamic>.from(item),
                ))
            .toList();
      }

      _lastErrorMessage = 'Could not load active devices.';
      return [];
    } on DioException catch (e) {
      _lastErrorMessage =
          _friendlyRequestError(e, 'Could not load active devices.');
      return [];
    } catch (e) {
      _lastErrorMessage = 'Could not load active devices.';
      return [];
    }
  }

  Future<bool> revokeDeviceSession(String sessionId) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to manage devices.';
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'device-sessions/$sessionId/revoke/',
          options: Options(headers: {
            'Authorization': 'Bearer $accessToken',
          }),
        ),
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not sign out this device.';
      return false;
    } catch (e) {
      _lastErrorMessage = 'Could not sign out this device.';
      return false;
    }
  }

  Future<bool> setPrimaryDeviceSession(
    String sessionId,
    String password,
  ) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to manage devices.';
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'device-sessions/$sessionId/set-primary/',
          data: {
            'password': password,
          },
          options: Options(headers: {
            'Authorization': 'Bearer $accessToken',
          }),
        ),
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not set the primary device.';
      return false;
    } catch (e) {
      _lastErrorMessage = 'Could not set the primary device.';
      return false;
    }
  }

  Future<int?> revokeOtherDeviceSessions() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to manage devices.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'device-sessions/revoke-others/',
          options: Options(headers: {
            'Authorization': 'Bearer $accessToken',
          }),
        ),
      );

      if (response.statusCode == 200) {
        return int.tryParse(response.data['revoked_count'].toString()) ?? 0;
      }

      _lastErrorMessage = 'Could not sign out the other devices.';
      return null;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not sign out the other devices.';
      return null;
    } catch (e) {
      _lastErrorMessage = 'Could not sign out the other devices.';
      return null;
    }
  }

  Future<bool> heartbeatSession() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      return false;
    }

    try {
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'device-sessions/heartbeat/',
          data: {
            'device_id': deviceId,
            'device_label': deviceLabel,
          },
          options: Options(headers: {
            'Authorization': 'Bearer $accessToken',
          }),
        ),
        clearSessionOnRefreshFailure: false,
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 && _isSessionRevokedError(e)) {
        _lastErrorMessage = _friendlyRequestError(
          e,
          'This device session is no longer active.',
        );
        await logout(notifyServer: false);
        return false;
      }
      if (e.response?.statusCode == 401) {
        _lastErrorMessage =
            'Session check could not refresh right now. Keeping you signed in.';
      }
      return true;
    } catch (e) {
      return true;
    }
  }

  Future<bool> validateCurrentSession() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in.';
      return false;
    }

    return heartbeatSession();
  }

  Future<void> logout({bool notifyServer = true}) async {
    final currentVaultUser =
        await _secureStorage.read(SecureStorageService.currentUserKey);

    if (notifyServer) {
      try {
        await _updateAuthHeader();
        final token =
            await _secureStorage.read(SecureStorageService.accessTokenKey);
        if (token != null && token.isNotEmpty) {
          final deviceId = await getOrCreateDeviceId();
          final deviceLabel = await _buildDeviceLabel();
          await _dio.post(
            'device-sessions/logout-current/',
            data: {
              'device_id': deviceId,
              'device_label': deviceLabel,
            },
            options: Options(headers: {
              'Authorization': 'Bearer $token',
            }),
          );
        }
      } catch (_) {}
    }

    if (currentVaultUser != null && currentVaultUser.trim().isNotEmpty) {
      await _secureStorage.write(
        SecureStorageService.localVaultUserKey,
        currentVaultUser.trim(),
      );
    }

    await _secureStorage.deleteSessionData();

    await _clearStoredEncryptionKey();

    _encryptionKey = null;
    OTPService().clearCachedUserId();
    _dio.options.headers.remove('Authorization');
  }

  Future<bool> isLoggedIn() async {
    final token =
        await _secureStorage.read(SecureStorageService.accessTokenKey);
    return token != null && token.isNotEmpty;
  }

  Future<String?> getCurrentUser() async {
    return _secureStorage.read(SecureStorageService.currentUserKey);
  }
}
