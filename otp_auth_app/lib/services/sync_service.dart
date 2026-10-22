import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
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
import 'push_messaging_service.dart';
import 'server_lockdown_service.dart';
import 'secure_storage_service.dart';
import '../config/app_config.dart';
import '../utils/network_error_messages.dart';
import 'dart:convert';
import 'dart:io';

/// The wrapped copies of an account's vault data key.
///
/// Stored in the cloud as plain JSON: everything inside is either already
/// encrypted or deliberately public. The salt is not a secret -- it exists so
/// the password wrapping key depends on the password alone, never on how the
/// account identity happens to be spelled.
class VaultKeyring {
  const VaultKeyring({
    required this.salt,
    required this.passwordWrap,
    required this.codeWraps,
    required this.kdfIterations,
  });

  final String salt;
  final String passwordWrap;
  final List<String> codeWraps;

  /// How the password wrap was made. Zero means the original single SHA-256,
  /// which keyrings written before PBKDF2 landed use; those still open, and are
  /// re-wrapped at the current cost the first time they do.
  final int kdfIterations;

  bool get usesStrongKdf =>
      kdfIterations >= EncryptionService.passwordKdfIterations;

  static VaultKeyring? fromJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final salt = decoded['salt']?.toString() ?? '';
      final passwordWrap = decoded['password_wrap']?.toString() ?? '';
      if (salt.isEmpty || passwordWrap.isEmpty) return null;
      return VaultKeyring(
        salt: salt,
        passwordWrap: passwordWrap,
        kdfIterations: int.tryParse('${decoded['kdf_iterations'] ?? 0}') ?? 0,
        codeWraps: ((decoded['code_wraps'] as List?) ?? const [])
            .map((wrap) => wrap.toString())
            .where((wrap) => wrap.isNotEmpty)
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  String toJson() => jsonEncode({
        'version': 2,
        'salt': salt,
        'password_wrap': passwordWrap,
        'code_wraps': codeWraps,
        'kdf': kdfIterations > 0 ? 'pbkdf2-sha256' : 'sha256',
        'kdf_iterations': kdfIterations,
      });

  VaultKeyring copyWith({String? passwordWrap, List<String>? codeWraps}) {
    return VaultKeyring(
      salt: salt,
      passwordWrap: passwordWrap ?? this.passwordWrap,
      codeWraps: codeWraps ?? this.codeWraps,
      kdfIterations: kdfIterations,
    );
  }
}

class SyncService {
  static const _passwordlessUnlockKeyPrefix = 'passwordless_unlock_key_';
  static const _passwordlessSyncUnlockContext = 'passwordless-sync-unlock';
  // ─── Singleton ────────────────────────────────────────────────────────────
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal() {
    _dio = Dio(
      BaseOptions(
        baseUrl: AppConfig.apiUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
        headers: {'Content-Type': 'application/json'},
      ),
    );
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          // Endpoints that establish a session must never carry one.
          //
          // DRF runs DEFAULT_AUTHENTICATION_CLASSES on every request that has
          // an Authorization header, before permission classes -- so a stale or
          // revoked token makes DeviceSessionJWTAuthentication raise 401 on
          // AllowAny views too. Sign-in then failed with "Invalid email or
          // password" while the credentials were perfectly good, because the
          // shared Dio instance was still carrying the previous session's
          // token. Stripping it here rather than at each call site means a new
          // auth endpoint cannot reintroduce the bug by forgetting to.
          if (_isUnauthenticatedPath(options.path)) {
            options.headers.remove('Authorization');
          }
          handler.next(options);
        },
      ),
    );
    ServerLockdownService().attachDioInterceptor(
      _dio,
      featureSummary:
          'sign-in, sync, passwordless, notifications, device sessions, and other server features',
    );
  }

  /// Paths that are reached before a session exists, or in order to create
  /// one. Anything here is sent without an Authorization header.
  static const Set<String> _unauthenticatedPaths = {
    'auth/login/',
    'auth/register/',
    'auth/passwordless-start/',
    'auth/passwordless-poll/',
    'send-2fa/',
    'verify-2fa/',
    'send-reset-code/',
    'reset-password/',
    'recovery-code/login/',
    'recovery-code/check-email/',
    'recovery-code/reset-password/',
  };

  @visibleForTesting
  static bool debugIsUnauthenticatedPath(String path) =>
      _isUnauthenticatedPath(path);

  static bool _isUnauthenticatedPath(String path) {
    // Dio hands the path as given at the call site, but a leading slash or a
    // full URL should match just the same.
    final normalised = path
        .replaceFirst(RegExp(r'^.*?/api/'), '')
        .replaceFirst(RegExp(r'^/+'), '');
    return _unauthenticatedPaths.contains(normalised);
  }

  late Dio _dio;
  static const MethodChannel _storageChannel = MethodChannel(
    'com.beatzlock.otp/storage',
  );
  static const MethodChannel _deviceIdentityChannel = MethodChannel(
    'com.beatzlock.otp/device_identity',
  );
  Future<bool>? _refreshTokenFuture;
  String? _encryptionKey;
  String? _lastErrorMessage;
  String? _cachedMobileDeviceFingerprint;
  final SecureStorageService _secureStorage = SecureStorageService();

  String? get lastErrorMessage => _lastErrorMessage;

  /// Set when the cloud vault exists but no key this device can derive opens
  /// it, so the UI can offer key transfer instead of showing an empty list.
  bool _vaultKeyMismatch = false;
  bool get vaultKeyMismatch => _vaultKeyMismatch;

  String _syncUnlockRequiredMessage() {
    return 'Cloud sync is locked on this device. Open Settings and use "Unlock Sync On This Device" once to restore your encrypted vault.';
  }

  String _vaultKeyMismatchMessage() {
    return 'Your synced accounts are encrypted with a key this device cannot derive from your email and password. Approve a passwordless sign-in from a device that still shows your accounts to hand this device the vault key.';
  }

  Future<bool> hasAvailableEncryptionKey() async {
    return _ensureEncryptionKeyAvailable();
  }

  Future<bool> isSyncLockedOnCurrentDevice() async {
    if (!await isLoggedIn()) {
      return false;
    }
    // A key that is present but does not open the cloud vault leaves sync just
    // as unusable as no key at all, and wants the same tile: entering the
    // password re-derives the key against the vault instead of assuming one
    // spelling of the account identity.
    if (_vaultKeyMismatch) {
      return true;
    }
    return !await _ensureEncryptionKeyAvailable();
  }

  String _normalizeRecoveryCode(String rawCode) {
    return rawCode.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

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

    if (statusCode == 404 &&
        (normalized.contains('no account was found for that username') ||
            normalized.contains('no account was found for that email') ||
            normalized.contains('user not found') ||
            normalized.contains('account not available'))) {
      return 'Account not available.';
    }

    if (statusCode == 401 ||
        normalized.contains('invalid credential') ||
        normalized.contains('invalid email or password') ||
        normalized.contains('invalid username or password') ||
        normalized.contains('no active account found')) {
      return 'Invalid email or password.';
    }

    return message;
  }

  String _friendlyRequestError(DioException error, String fallback) {
    final statusCode = error.response?.statusCode;
    final serverError = _extractServerError(error.response?.data);
    if (serverError != null && serverError.isNotEmpty) {
      return _normalizeAuthError(serverError, statusCode: statusCode);
    }

    // Transport failures get their wording from one shared place, so "no
    // internet" reads the same everywhere in the app and never mentions DNS,
    // proxies or certificate trust -- none of which a user can act on.
    final transportMessage = NetworkErrorMessages.forTransport(error);
    if (transportMessage != null) {
      return transportMessage;
    }

    if (error.type == DioExceptionType.badResponse) {
      if (statusCode == 401) {
        return 'Invalid email or password.';
      }
      if (statusCode == 403) {
        return 'You are not authorized to perform this action.';
      }
      if (statusCode == 404) {
        return 'BeatzLock could not find that on the server. It may be '
            'temporarily unavailable -- try again shortly.';
      }
      if (statusCode != null && statusCode >= 500) {
        return NetworkErrorMessages.serverError;
      }
    }

    return fallback;
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

  Future<void> _activateSyncEncryptionKey(
    String encryptionKey, {
    bool enableSyncByDefault = true,
  }) async {
    await _storeEncryptionKey(encryptionKey);
    _encryptionKey = encryptionKey;
    await setSyncEnabled(enableSyncByDefault);
    await _restoreSyncedVaultDataAfterUnlock();
  }

  // ─── Vault key negotiation ───────────────────────────────────────────────
  // The vault key is derived from the identity the API returns as
  // user["username"] plus the password, and that derivation is
  // case-sensitive. The identity used to be a stored username column and is
  // now the email address, lowercased in the database. An account whose
  // address had any capital in it therefore derives a different key today
  // than it did when its cloud blob was written: installs already signed in
  // keep working from the key in secure storage, while a fresh sign-in on a
  // new device derives the new spelling and cannot open the blob. Rather than
  // trust one derivation, try every spelling this device can construct
  // against the actual cloud payload and keep the one that opens it.

  static const _vaultKeySalt = 'beatzLockKenya2099';

  String _deriveVaultKey(String identity, String password) {
    return EncryptionService.generateKey(identity + password, _vaultKeySalt);
  }

  /// Decode an `otp_accounts` payload, or null if [key] does not open it.
  @visibleForTesting
  List<dynamic>? tryDecodeAccountsPayload(String encryptedContent, String key) {
    try {
      final decrypted = _decryptSyncBlob(
        encryptedContent,
        key,
        'otp_accounts',
      );
      if (decrypted.trim().isEmpty) return null;
      final decoded = jsonDecode(decrypted);
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Every distinct key the spellings of [identities] can produce, with the
  /// canonical derivation first so a healthy account never changes behaviour.
  @visibleForTesting
  List<String> candidateVaultKeys(
    Iterable<String> identities,
    String password,
  ) {
    final seenKeys = <String>{};
    final keys = <String>[];
    for (final identity in identities) {
      final trimmed = identity.trim();
      if (trimmed.isEmpty) continue;
      for (final spelling in <String>[trimmed, trimmed.toLowerCase()]) {
        final key = _deriveVaultKey(spelling, password);
        if (seenKeys.add(key)) keys.add(key);
      }
    }
    return keys;
  }

  /// The raw encrypted `otp_accounts` blob, or null when the account has none.
  Future<String?> _fetchRawAccountsPayload() async {
    try {
      final deviceId = await getOrCreateDeviceId();
      final response = await _dio.get(
        'sync/get-data/',
        queryParameters: {'data_type': 'otp_accounts', 'device_id': deviceId},
      );
      if (response.statusCode != 200) return null;
      final content = response.data['encrypted_content']?.toString() ?? '';
      return content.isEmpty ? null : content;
    } catch (_) {
      return null;
    }
  }

  /// The key that actually opens this account's cloud vault.
  ///
  /// Falls back to the canonical derivation when there is nothing in the cloud
  /// to test against (a new account), and sets [vaultKeyMismatch] when a vault
  /// exists that no derivable key opens -- that account's key only exists on a
  /// device that is already signed in, and has to be transferred from there.
  Future<String> _resolveVaultEncryptionKey({
    required String canonicalUsername,
    required String password,
    String? typedIdentifier,
  }) async {
    _vaultKeyMismatch = false;
    final candidates = candidateVaultKeys(
      <String>[canonicalUsername, if (typedIdentifier != null) typedIdentifier],
      password,
    );
    final fallback = candidates.isEmpty
        ? _deriveVaultKey(canonicalUsername, password)
        : candidates.first;

    final payload = await _fetchRawAccountsPayload();
    if (payload == null) return fallback;

    for (final key in candidates) {
      if (tryDecodeAccountsPayload(payload, key) != null) {
        if (key != fallback) {
          debugPrint('Vault opened with a non-canonical identity spelling');
        }
        return key;
      }
    }

    _vaultKeyMismatch = true;
    _lastErrorMessage = _vaultKeyMismatchMessage();
    debugPrint('No derivable key opens the cloud vault on this device');
    return fallback;
  }

  // --- Vault keyring --------------------------------------------------------
  // Where the vault key comes from now. The vault is encrypted with a random
  // data key that never changes; the keyring holds that key wrapped under the
  // password and under each recovery code. A password change re-wraps thirty-
  // two bytes instead of rewriting the vault, and a reset unwraps through a
  // recovery code, so neither can strand anything.
  //
  // Accounts created before this have no keyring and a vault encrypted under a
  // key derived from identity and password. They are upgraded once, in place,
  // the first time a device signs in with a key that opens the vault.

  static const _keyringDataType = 'vault_keyring';

  Future<VaultKeyring?> _fetchKeyring() async {
    try {
      final stored = await getEncryptedSyncData(_keyringDataType);
      final raw = stored?['encrypted_content']?.toString() ?? '';
      if (raw.isEmpty) return null;
      return VaultKeyring.fromJson(raw);
    } catch (e) {
      debugPrint('Could not read vault keyring: $e');
      return null;
    }
  }

  Future<bool> _storeKeyring(VaultKeyring keyring) async {
    try {
      final stored = await getEncryptedSyncData(_keyringDataType);
      final version = int.tryParse(stored?['version']?.toString() ?? '0') ?? 0;
      return await uploadEncryptedSyncData(
        _keyringDataType,
        encryptedContent: keyring.toJson(),
        version: version + 1,
        deletedAccounts: 'N/A',
      );
    } catch (e) {
      debugPrint('Could not write vault keyring: $e');
      return false;
    }
  }

  /// The data key for this account, or null if [password] does not open it.
  Future<String?> _dataKeyFromKeyring(String password) async {
    final keyring = await _fetchKeyring();
    if (keyring == null) return null;

    final dataKey = EncryptionService.unwrapDataKeyWithPassword(
      keyring.passwordWrap,
      password,
      keyring.salt,
      iterations: keyring.kdfIterations,
    );
    if (dataKey == null) return null;

    // Opened under a weaker derivation than we ship. Re-wrap it now, while the
    // password is in hand -- the vault itself is untouched either way.
    if (!keyring.usesStrongKdf) {
      final salt = EncryptionService.generateKeyringSalt();
      await _storeKeyring(
        VaultKeyring(
          salt: salt,
          passwordWrap: EncryptionService.wrapDataKeyWithPassword(
            dataKey,
            password,
            salt,
          ),
          codeWraps: keyring.codeWraps,
          kdfIterations: EncryptionService.passwordKdfIterations,
        ),
      );
      debugPrint('Keyring re-wrapped at the current KDF cost');
    }

    return dataKey;
  }

  /// Move a legacy account onto a keyring, once.
  ///
  /// [legacyKey] must already be known to open the vault. The keyring is
  /// written before the vault is re-encrypted: if the re-encryption then fails,
  /// the vault is still readable under the legacy key and key resolution falls
  /// back to it, so the upgrade simply retries. Writing them the other way
  /// round would leave a vault nothing could open.
  Future<String?> _upgradeLegacyVaultToKeyring(
    String password,
    String legacyKey,
  ) async {
    try {
      final dataKey = EncryptionService.generateVaultDataKey();
      final salt = EncryptionService.generateKeyringSalt();
      final keyring = VaultKeyring(
        salt: salt,
        passwordWrap: EncryptionService.wrapDataKeyWithPassword(
          dataKey,
          password,
          salt,
        ),
        codeWraps: const [],
        kdfIterations: EncryptionService.passwordKdfIterations,
      );

      if (!await _storeKeyring(keyring)) {
        debugPrint('Keyring upgrade aborted: keyring could not be stored');
        return null;
      }

      // Re-encrypt what is stored, having read it under the key that works.
      _encryptionKey = legacyKey;
      if (!await _reEncryptStoredVault(from: legacyKey, to: dataKey)) {
        // The keyring is already written and now names a key the vault is not
        // under. Rather than leave those two disagreeing -- which strands every
        // device that later reads the keyring -- point the keyring back at the
        // key the vault really uses. The account keeps working, and the upgrade
        // is retried on the next sign-in.
        debugPrint(
          'Vault re-encryption failed; pointing the keyring at the current key',
        );
        await _storeKeyring(
          VaultKeyring(
            salt: salt,
            passwordWrap: EncryptionService.wrapDataKeyWithPassword(
              legacyKey,
              password,
              salt,
            ),
            codeWraps: const [],
            kdfIterations: EncryptionService.passwordKdfIterations,
          ),
        );
        _encryptionKey = legacyKey;
        return null;
      }

      debugPrint('Vault upgraded to a keyring-held data key');
      return dataKey;
    } catch (e) {
      debugPrint('Keyring upgrade error: $e');
      return null;
    }
  }

  /// Read every synced blob under [from] and write it back under [to].
  ///
  /// Reads before it writes, blob by blob, and stops at the first one it cannot
  /// read rather than replacing it.
  Future<bool> _reEncryptStoredVault({
    required String from,
    required String to,
  }) async {
    final deviceId = await getOrCreateDeviceId();
    for (final dataType in const ['otp_accounts']) {
      Response<dynamic> current;
      try {
        current = await _requestWithRetry(
          (_) => _dio.get(
            'sync/get-data/',
            queryParameters: {'data_type': dataType, 'device_id': deviceId},
          ),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) continue;
        rethrow;
      }
      if (current.statusCode != 200) continue;

      final cipherText = current.data['encrypted_content']?.toString() ?? '';
      if (cipherText.isEmpty) continue;

      String plainText;
      try {
        plainText = _decryptSyncBlob(cipherText, from, dataType);
        if (plainText.trim().isNotEmpty && jsonDecode(plainText) is! List) {
          throw const FormatException('Synced blob is not a list');
        }
      } catch (_) {
        debugPrint('Re-encrypt stopped: $dataType could not be read');
        return false;
      }
      if (plainText.trim().isEmpty) continue;

      final version = int.tryParse('${current.data['version'] ?? 0}') ?? 0;
      final uploaded = await _requestWithRetry(
        (_) => _dio.post(
          'sync/sync/',
          data: {
            'data_type': dataType,
            'encrypted_content': _encryptSyncBlob(plainText, to, dataType),
            'version': version + 1,
            'device_id': deviceId,
            'deleted_accounts':
                current.data['deleted_accounts']?.toString() ?? '[]',
          },
        ),
      );
      if (uploaded.statusCode != 200) return false;
    }
    return true;
  }

  /// The vault key for this sign-in: from the keyring where there is one,
  /// otherwise the legacy derivation, upgrading the account as a side effect.
  /// The outcome of resolving a vault key, reported directly rather than
  /// through the shared [_vaultKeyMismatch] flag.
  ///
  /// That flag is also set by sync operations, and `_activateSyncEncryptionKey`
  /// runs one. Reading it after activation therefore answered "did the most
  /// recent download decode", not "did this password produce the right key" --
  /// so a correct password reported itself as wrong whenever the restore that
  /// followed it hit anything unreadable.
  Future<({String key, bool opened})> _resolveVaultKeyResult({
    required String canonicalUsername,
    required String password,
    String? typedIdentifier,
  }) async {
    final key = await _resolveVaultKey(
      canonicalUsername: canonicalUsername,
      password: password,
      typedIdentifier: typedIdentifier,
    );
    return (key: key, opened: !_vaultKeyMismatch);
  }

  Future<String> _resolveVaultKey({
    required String canonicalUsername,
    required String password,
    String? typedIdentifier,
  }) async {
    _vaultKeyMismatch = false;

    final fromKeyring = await _dataKeyFromKeyring(password);
    if (fromKeyring != null && fromKeyring.isNotEmpty) {
      // Unwrapping proves the password, not the key. If the keyring and the
      // stored vault disagree -- which happens when an upgrade wrote the
      // keyring and then failed to re-encrypt the vault -- taking this key on
      // faith leaves every device holding one that opens nothing, and the
      // failure surfaces as "your password is wrong" on all of them at once.
      if (await _keyOpensStoredVault(fromKeyring)) {
        debugPrint('Vault key taken from the keyring');
        return fromKeyring;
      }
      debugPrint(
        'Keyring key does not open the stored vault - re-running the upgrade',
      );
    }

    // No keyring, or a keyring this password does not open. Fall back to the
    // derivation this account was created under.
    final legacyKey = await _resolveVaultEncryptionKey(
      canonicalUsername: canonicalUsername,
      password: password,
      typedIdentifier: typedIdentifier,
    );

    if (_vaultKeyMismatch) {
      // Nothing opens the vault. Do not upgrade -- that would write a keyring
      // for a vault this device cannot re-encrypt.
      return legacyKey;
    }

    final upgraded = await _upgradeLegacyVaultToKeyring(password, legacyKey);
    return upgraded ?? legacyKey;
  }

  /// Whether [key] actually decrypts what is stored.
  ///
  /// An account with nothing in the cloud yet has no vault to contradict the
  /// key, so it counts as open.
  Future<bool> _keyOpensStoredVault(String key) async {
    final payload = await _fetchRawAccountsPayload();
    if (payload == null || payload.isEmpty) return true;
    return tryDecodeAccountsPayload(payload, key) != null;
  }

  /// Re-wrap the data key under a new password. The vault is not touched.
  ///
  /// This is what makes a password change cheap and safe: thirty-two bytes are
  /// rewritten instead of every account, password and secure text.
  Future<bool> rewrapKeyringForNewPassword(String newPassword) async {
    final dataKey = await getAvailableEncryptionKey();
    if (dataKey == null || dataKey.isEmpty) return false;

    final existing = await _fetchKeyring();
    if (existing == null) return false;

    final salt = EncryptionService.generateKeyringSalt();
    final updated = VaultKeyring(
      salt: salt,
      passwordWrap: EncryptionService.wrapDataKeyWithPassword(
        dataKey,
        newPassword,
        salt,
      ),
      // Recovery-code wraps seal the same unchanged data key, so they keep
      // working across a password change with nothing to redo.
      codeWraps: existing.codeWraps,
      kdfIterations: EncryptionService.passwordKdfIterations,
    );
    return _storeKeyring(updated);
  }

  /// Add recovery-code wraps for the current data key.
  Future<bool> addRecoveryCodesToKeyring(List<String> recoveryCodes) async {
    final codes = recoveryCodes
        .map(EncryptionService.normalizeRecoveryCode)
        .where((code) => code.isNotEmpty)
        .toList();
    if (codes.isEmpty) return false;

    final dataKey = await getAvailableEncryptionKey();
    if (dataKey == null || dataKey.isEmpty) return false;

    final existing = await _fetchKeyring();
    if (existing == null) return false;

    return _storeKeyring(
      existing.copyWith(
        codeWraps: [
          for (final code in codes)
            EncryptionService.wrapDataKeyWithRecoveryCode(dataKey, code),
        ],
      ),
    );
  }

  /// Recover the data key with a recovery code, and re-wrap it under
  /// [newPassword] when one is given -- the path back after a reset.
  Future<String?> dataKeyFromRecoveryCode(
    String recoveryCode, {
    String? newPassword,
  }) async {
    final code = EncryptionService.normalizeRecoveryCode(recoveryCode);
    if (code.isEmpty) return null;

    final keyring = await _fetchKeyring();
    if (keyring == null) return null;

    String? dataKey;
    for (final wrap in keyring.codeWraps) {
      dataKey = EncryptionService.unwrapDataKeyWithRecoveryCode(wrap, code);
      if (dataKey != null) break;
    }
    if (dataKey == null) return null;

    if (newPassword != null && newPassword.isNotEmpty) {
      final salt = EncryptionService.generateKeyringSalt();
      await _storeKeyring(
        VaultKeyring(
          salt: salt,
          passwordWrap: EncryptionService.wrapDataKeyWithPassword(
            dataKey,
            newPassword,
            salt,
          ),
          codeWraps: keyring.codeWraps,
          kdfIterations: EncryptionService.passwordKdfIterations,
        ),
      );
    }
    return dataKey;
  }

  Future<bool> hasVaultKeyring() async => (await _fetchKeyring()) != null;

  // --- Vault key escrow -----------------------------------------------------
  // The vault key comes from the account password. A password reset happens
  // precisely because the old password is gone, so before this the reset left
  // the synced vault locked under a key nobody could ever derive again: dead
  // ciphertext, silently, with no warning and no way back.
  //
  // The escrow wraps the vault key under each recovery code, so the PDF users
  // are already required to save can unlock it. The server stores only the
  // wrapped blob and never sees the key.
  //
  // Re-keys are handled without needing the codes again: each one appends the
  // new key sealed under the previous one, so an escrow written before a
  // password change still leads to the current key by walking the chain.

  static const _vaultEscrowDataType = 'vault_key_escrow';

  /// Wrap the active vault key under [recoveryCodes] and store it.
  ///
  /// Called when recovery codes are generated, which is the only moment the
  /// app holds them in plaintext. They are not persisted anywhere.
  Future<bool> publishVaultKeyEscrow(List<String> recoveryCodes) async {
    final codes = recoveryCodes
        .map(EncryptionService.normalizeRecoveryCode)
        .where((code) => code.isNotEmpty)
        .toList();
    if (codes.isEmpty) return false;

    // On a keyring account the codes wrap the data key, which never changes --
    // so these wraps keep working through password changes with nothing to
    // redo. The standalone escrow below is only for accounts not yet upgraded.
    if (await addRecoveryCodesToKeyring(codes)) {
      debugPrint('Recovery codes added to the vault keyring');
      return true;
    }

    final vaultKey = await getAvailableEncryptionKey();
    if (vaultKey == null || vaultKey.isEmpty) {
      debugPrint('No vault key to escrow yet');
      return false;
    }

    try {
      final payload = <String, dynamic>{
        'version': 1,
        'wrapped_keys': [
          for (final code in codes)
            EncryptionService.wrapVaultKey(vaultKey, code),
        ],
        // Re-keys append here rather than rewriting wrapped_keys, which cannot
        // be rebuilt without the codes.
        'chain': <String>[],
      };

      final stored = await getEncryptedSyncData(_vaultEscrowDataType);
      final version = int.tryParse(stored?['version']?.toString() ?? '0') ?? 0;
      final ok = await uploadEncryptedSyncData(
        _vaultEscrowDataType,
        encryptedContent: jsonEncode(payload),
        version: version + 1,
        deletedAccounts: 'N/A',
      );
      debugPrint(ok
          ? 'Vault key escrowed under ${codes.length} recovery codes'
          : 'Vault key escrow upload failed');
      return ok;
    } catch (e) {
      debugPrint('publishVaultKeyEscrow error: $e');
      return false;
    }
  }

  /// Record that the vault key changed, so an existing escrow still reaches it.
  Future<void> _appendVaultKeyEscrowLink(
    String previousKey,
    String newKey,
  ) async {
    if (previousKey.isEmpty || newKey.isEmpty || previousKey == newKey) return;
    try {
      final stored = await getEncryptedSyncData(_vaultEscrowDataType);
      final raw = stored?['encrypted_content']?.toString() ?? '';
      if (raw.isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final payload = Map<String, dynamic>.from(decoded);
      final chain = <String>[
        ...((payload['chain'] as List?) ?? const []).map((e) => e.toString()),
        EncryptionService.chainVaultKey(newKey, previousKey),
      ];
      payload['chain'] = chain;

      final version = int.tryParse(stored?['version']?.toString() ?? '0') ?? 0;
      await uploadEncryptedSyncData(
        _vaultEscrowDataType,
        encryptedContent: jsonEncode(payload),
        version: version + 1,
        deletedAccounts: 'N/A',
      );
      debugPrint('Vault key escrow chain extended to ${chain.length} links');
    } catch (e) {
      debugPrint('Could not extend vault key escrow chain: $e');
    }
  }

  /// Whether this account has an escrow that a recovery code could open.
  Future<bool> hasVaultKeyEscrow() async {
    final keyring = await _fetchKeyring();
    if (keyring != null && keyring.codeWraps.isNotEmpty) return true;
    try {
      final stored = await getEncryptedSyncData(_vaultEscrowDataType);
      final raw = stored?['encrypted_content']?.toString() ?? '';
      if (raw.isEmpty) return false;
      final decoded = jsonDecode(raw);
      return decoded is Map &&
          ((decoded['wrapped_keys'] as List?) ?? const []).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // --- Vault re-key ---------------------------------------------------------
  // Key negotiation above recovers a vault whose key this device can still
  // construct from some spelling of the account identity. Where it succeeds but
  // other devices derive a different key, the vault can be rewritten under the
  // key everyone derives today, and this is what does that.
  //
  // The cloud copy is authoritative and is never replaced by local data. A
  // rewrite only ever happens after this device has successfully read what is
  // up there, so the content it writes is the cloud's own content merged with
  // this device's -- a superset, never a substitution. When nothing can open
  // the cloud vault, the repair refuses. That ciphertext is the only copy of
  // whatever it holds, and a device having lost the key is not a reason to
  // destroy it: a key may still exist on a device that has not been opened in
  // a while, and overwriting would end that permanently.

  String _rekeyFailureMessage() {
    return 'Could not rewrite your cloud vault. Nothing was changed. Check your connection and try again.';
  }

  String _vaultUnreadableAnywhereMessage() {
    return 'Nothing on this device can open your cloud vault, so BeatzLock will not touch it -- overwriting it would destroy the only copy of what is in there. Try this on another device that still syncs. If no device can, your synced copy cannot be recovered, but it is left exactly as it is.';
  }

  String _syncContextFor(String dataType) {
    if (dataType == 'otp_accounts') {
      return EncryptionService.otpAccountsSyncContext;
    }
    // Deliberately loud. This used to fall through to the secure-messages
    // context for anything unrecognised, so a typo would encrypt under a
    // context nothing ever reads back and fail only much later.
    throw ArgumentError.value(dataType, 'dataType', 'Unknown synced data type');
  }

  String _encryptSyncBlob(String plainText, String key, String dataType) {
    return EncryptionService.encryptSensitiveSyncPayload(
      plainText,
      key,
      context: _syncContextFor(dataType),
    );
  }

  /// Read a synced blob, accepting the unauthenticated form only long enough
  /// to rewrite it. Every write goes out authenticated.
  String _decryptSyncBlob(String cipherText, String key, String dataType) {
    return EncryptionService.decryptSensitiveSyncPayload(
      cipherText,
      key,
      context: _syncContextFor(dataType),
      allowLegacyPlaintextFallback: true,
    );
  }

  /// Every key this device could use to open the cloud vault, best first.
  Future<List<String>> _vaultRescueKeys(String password) async {
    final canonicalUsername =
        await _secureStorage.read(SecureStorageService.currentUserKey) ?? '';
    final storedEmail =
        await _secureStorage.read(SecureStorageService.userEmailKey);
    final keys = <String>[];
    final storedKey = await getAvailableEncryptionKey();
    if (storedKey != null && storedKey.isNotEmpty) keys.add(storedKey);
    keys.addAll(
      candidateVaultKeys(
        <String>[canonicalUsername, if (storedEmail != null) storedEmail],
        password,
      ),
    );
    return keys;
  }

  /// Rewrite the cloud vault under the key the account password derives today.
  ///
  /// Runs only when this device can read what is already in the cloud, so the
  /// rewrite carries that content forward rather than replacing it. Refuses
  /// otherwise, leaving the stored vault untouched.
  Future<bool> repairCloudVaultKey(String password) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'Sign in before repairing cloud sync.';
      return false;
    }

    final canonicalUsername =
        await _secureStorage.read(SecureStorageService.currentUserKey) ?? '';
    if (canonicalUsername.isEmpty) {
      _lastErrorMessage = 'Sign in again before repairing cloud sync.';
      return false;
    }

    try {
      final verified = await _requestWithRetry(
        (accessToken) => _dio.post(
          'auth/unlock-sync/',
          data: {'password': password},
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      if (verified.statusCode != 200) {
        _lastErrorMessage = 'Password is incorrect.';
        return false;
      }
    } on DioException catch (e) {
      _lastErrorMessage =
          _extractServerError(e.response?.data) ?? 'Password is incorrect.';
      return false;
    }

    final newKey = _deriveVaultKey(canonicalUsername, password);
    final originalKey = await getAvailableEncryptionKey();

    try {
      // Find a key that opens what is up there. Nothing is written unless one
      // does -- an unreadable vault is left alone, not replaced.
      final cloudPayload = await _fetchRawAccountsPayload();
      final cloudIsEmpty = cloudPayload == null || cloudPayload.isEmpty;

      if (!cloudIsEmpty) {
        String? readableKey;
        for (final key in await _vaultRescueKeys(password)) {
          if (tryDecodeAccountsPayload(cloudPayload, key) != null) {
            readableKey = key;
            break;
          }
        }

        if (readableKey == null) {
          _lastErrorMessage = _vaultUnreadableAnywhereMessage();
          return false;
        }

        // Merge the cloud in under the key that opens it, so the rewrite
        // carries every item it holds -- including any this device lacks.
        _encryptionKey = readableKey;
        await _storeEncryptionKey(readableKey);
        await downloadAndMergeAccounts();
      }

      final deviceId = await getOrCreateDeviceId();
      final userBox = await _getUserBox();

      final accounts = await Future.wait(
        userBox.values.map((a) async {
          return <String, dynamic>{
            'id': a.id,
            'service': a.service,
            'secret': await _decryptSecretForUpload(a.secret),
            'issuer': a.issuer,
            'account_label': a.accountLabel,
            'createdAt': a.createdAt.toIso8601String(),
          };
        }).toList(),
      );

      final payloads = <String, List<Map<String, dynamic>>>{
        'otp_accounts': accounts,
      };

      for (final entry in payloads.entries) {
        // Carry the stored version and deletion list forward rather than
        // resetting them: this is a re-encryption, not a fresh vault.
        var version = 0;
        var deletedAccounts = '[]';
        try {
          final current = await _requestWithRetry(
            (_) => _dio.get(
              'sync/get-data/',
              queryParameters: {
                'data_type': entry.key,
                'device_id': deviceId,
              },
            ),
          );
          if (current.statusCode == 200) {
            version = int.tryParse('${current.data['version'] ?? 0}') ?? 0;
            final storedDeleted =
                current.data['deleted_accounts']?.toString() ?? '';
            if (storedDeleted.isNotEmpty) deletedAccounts = storedDeleted;
          }
        } on DioException catch (e) {
          if (e.response?.statusCode != 404) rethrow;
        }

        final uploaded = await _requestWithRetry(
          (_) => _dio.post(
            'sync/sync/',
            data: {
              'data_type': entry.key,
              'encrypted_content': _encryptSyncBlob(
                jsonEncode(entry.value),
                newKey,
                entry.key,
              ),
              'version': version + 1,
              'device_id': deviceId,
              if (entry.key == 'otp_accounts') 'item_count': entry.value.length,
              'deleted_accounts': deletedAccounts,
            },
          ),
        );
        if (uploaded.statusCode != 200) {
          _lastErrorMessage = _rekeyFailureMessage();
          return false;
        }
      }

      // Keep any recovery escrow reaching the current key, without needing
      // the codes -- the new key is sealed under the one it replaces.
      if (originalKey != null && originalKey.isNotEmpty) {
        await _appendVaultKeyEscrowLink(originalKey, newKey);
      }

      await _storeEncryptionKey(newKey);
      _encryptionKey = newKey;
      await setSyncEnabled(true);
      _vaultKeyMismatch = false;
      debugPrint(
        'Cloud vault re-encrypted under the canonical identity: '
        '${accounts.length} accounts',
      );
      return true;
    } on DioException catch (e) {
      await _restoreKeyAfterFailedRepair(originalKey);
      _lastErrorMessage = _friendlyRequestError(e, _rekeyFailureMessage());
      return false;
    } catch (e) {
      await _restoreKeyAfterFailedRepair(originalKey);
      _lastErrorMessage = NetworkErrorMessages.forUnexpected(
        e,
        _rekeyFailureMessage(),
      );
      return false;
    }
  }

  /// Put back the key this device started with, so a failed repair does not
  /// leave it holding one it never had.
  Future<void> _restoreKeyAfterFailedRepair(String? originalKey) async {
    if (originalKey == null || originalKey.isEmpty) return;
    _encryptionKey = originalKey;
    await _storeEncryptionKey(originalKey);
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
    String storedSecret,
    String currentUserId,
  ) {
    final strippedSpaces = storedSecret.replaceAll(RegExp(r'\s+'), '');
    final isRawBase32 = RegExp(r'^[A-Z2-7a-z]+$').hasMatch(strippedSpaces);
    if (isRawBase32) {
      return storedSecret;
    }

    final candidateUserIds = <String>[currentUserId, 'default_user'];

    for (final userId in candidateUserIds) {
      try {
        final plainSecret = EncryptionService.decryptSecret(
          storedSecret,
          userId,
        );
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
        final plainSecret = _decodeLegacySecretForMigration(
          account.secret,
          currentUserId,
        );
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
    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    final deviceId = await getOrCreateDeviceId();
    final deviceLabel = await _buildDeviceLabel();
    final deviceFingerprint = await _getStableMobileDeviceFingerprint();
    if (token != null && token.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $token';
    } else {
      _dio.options.headers.remove('Authorization');
    }
    _dio.options.headers['X-Device-ID'] = deviceId;
    _dio.options.headers['X-Device-Label'] = deviceLabel;
    _dio.options.headers['X-Device-Kind'] = _deviceKind();
    if (deviceFingerprint != null && deviceFingerprint.isNotEmpty) {
      _dio.options.headers['X-Device-Fingerprint'] = deviceFingerprint;
    } else {
      _dio.options.headers.remove('X-Device-Fingerprint');
    }
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
    final refreshToken = await _secureStorage.read(
      SecureStorageService.refreshTokenKey,
    );
    if (refreshToken == null || refreshToken.isEmpty) {
      return false;
    }
    try {
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final deviceFingerprint = await _getStableMobileDeviceFingerprint();
      final refreshDio = Dio(
        BaseOptions(
          baseUrl: AppConfig.apiUrl,
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
          headers: {
            'Content-Type': 'application/json',
            'X-Device-ID': deviceId,
            'X-Device-Label': deviceLabel,
            'X-Device-Kind': _deviceKind(),
            if (deviceFingerprint != null && deviceFingerprint.isNotEmpty)
              'X-Device-Fingerprint': deviceFingerprint,
          },
        ),
      );
      ServerLockdownService().attachDioInterceptor(
        refreshDio,
        featureSummary: 'refresh your signed-in session',
      );
      final response = await refreshDio.post(
        'token/refresh/',
        data: {'refresh': refreshToken},
      );
      if (response.statusCode == 200) {
        await _secureStorage.write(
          SecureStorageService.accessTokenKey,
          response.data['access'],
        );
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
      final accessToken = await _secureStorage.read(
        SecureStorageService.accessTokenKey,
      );
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

  Future<String> getCurrentVaultIdentity() async => await _getCurrentUserId();

  Future<String> getOrCreateDeviceId() async {
    final mobileFingerprint = await _getStableMobileDeviceFingerprint();
    if (mobileFingerprint != null && mobileFingerprint.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final savedDeviceId = prefs.getString('device_id') ?? '';
      if (savedDeviceId != mobileFingerprint) {
        await prefs.setString('device_id', mobileFingerprint);
      }
      return mobileFingerprint;
    }

    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString('device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
      await prefs.setString('device_id', deviceId);
    }
    return deviceId;
  }

  Future<String?> _getStableMobileDeviceFingerprint() async {
    if (_cachedMobileDeviceFingerprint != null) {
      return _cachedMobileDeviceFingerprint;
    }
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return null;
    }

    try {
      final rawId = await _deviceIdentityChannel.invokeMethod<String>(
        'getStableDeviceId',
      );
      final cleaned = rawId?.trim() ?? '';
      if (cleaned.isEmpty) {
        return null;
      }

      final hashed = sha256
          .convert(utf8.encode('beatzlock-device-v1|$cleaned'))
          .toString();
      _cachedMobileDeviceFingerprint = 'mob_$hashed';
      return _cachedMobileDeviceFingerprint;
    } catch (_) {
      return null;
    }
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

  String _deviceKind() {
    if (kIsWeb) {
      return 'web';
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return 'mobile';
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return 'desktop';
    }
    return 'unknown';
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
  Future<bool> register(String email, String password) async {
    try {
      _lastErrorMessage = null;
      final normalizedEmail = email.trim().toLowerCase();
      await _updateAuthHeader();
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _dio.post(
        'auth/register/',
        data: {
          'email': normalizedEmail,
          'username': normalizedEmail,
          'password': password,
          'device_id': deviceId,
          'device_label': deviceLabel,
          'device_kind': _deviceKind(),
        },
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        final canonicalUsername =
            response.data['user']?['username']?.toString() ?? normalizedEmail;
        await _secureStorage.write(
          SecureStorageService.accessTokenKey,
          response.data['access'],
        );
        await _secureStorage.write(
          SecureStorageService.refreshTokenKey,
          response.data['refresh'],
        );
        await _secureStorage.write(
          SecureStorageService.currentUserKey,
          canonicalUsername,
        );
        await _secureStorage.write(
          SecureStorageService.localVaultUserKey,
          canonicalUsername,
        );
        await _secureStorage.write(
          SecureStorageService.userEmailKey,
          response.data['user']?['email']?.toString() ?? normalizedEmail,
        );
        await _secureStorage.write(
          SecureStorageService.userIdKey,
          response.data['user']['id'].toString(),
        );
        OTPService().clearCachedUserId();
        await _updateAuthHeader();
        _initEncryption(canonicalUsername, password);
        await _activateSyncEncryptionKey(_encryptionKey!);
        return true;
      }
      _lastErrorMessage = 'Registration failed. Please try again.';
      return false;
    } on DioException catch (e) {
      _lastErrorMessage = _friendlyRequestError(
        e,
        'Registration failed. Please try again.',
      );
      debugPrint('Register error: $e');
      return false;
    } catch (e) {
      _lastErrorMessage = 'Registration failed. Please try again.';
      debugPrint('Register error: $e');
      return false;
    }
  }

  // ─── Login ────────────────────────────────────────────────────────────────
  Future<bool> login(String email, String password) async {
    try {
      _lastErrorMessage = null;
      final loginIdentifier = email.trim();
      await _updateAuthHeader();
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _dio.post(
        'auth/login/',
        data: {
          'email': loginIdentifier,
          'username': loginIdentifier,
          'password': password,
          'device_id': deviceId,
          'device_label': deviceLabel,
          'device_kind': _deviceKind(),
        },
      );
      if (response.statusCode == 200) {
        final canonicalUsername =
            response.data['user']?['username']?.toString() ?? loginIdentifier;
        await _secureStorage.write(
          SecureStorageService.accessTokenKey,
          response.data['access'],
        );
        await _secureStorage.write(
          SecureStorageService.refreshTokenKey,
          response.data['refresh'],
        );
        await _secureStorage.write(
          SecureStorageService.currentUserKey,
          canonicalUsername,
        );
        await _secureStorage.write(
          SecureStorageService.localVaultUserKey,
          canonicalUsername,
        );
        await _secureStorage.write(
          SecureStorageService.userEmailKey,
          response.data['user']['email'] ?? '',
        );
        await _secureStorage.write(
          SecureStorageService.userIdKey,
          response.data['user']['id'].toString(),
        );
        OTPService().clearCachedUserId();
        await _updateAuthHeader();

        // Treat successful token issuance as a successful login.
        final encryptionKey = await _resolveVaultKey(
          canonicalUsername: canonicalUsername,
          password: password,
          typedIdentifier: loginIdentifier,
        );
        await _activateSyncEncryptionKey(encryptionKey);

        return true;
      }
      return false;
    } on DioException catch (e) {
      _lastErrorMessage = _friendlyRequestError(
        e,
        'Login failed. Please try again.',
      );
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
      final response = await _requestWithRetry(
        (_) =>
            _dio.post('sync/delete-account/', data: {'account_id': accountId}),
      );
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

  Future<bool> deleteSingleAccountEverywhere(
    String accountId, {
    required String confirmationPhrase,
  }) async {
    await _updateAuthHeader();
    try {
      final response = await _requestWithRetry(
        (_) => _dio.post(
          'sync/delete-account-everywhere/',
          data: {
            'account_id': accountId,
            'confirmation_phrase': confirmationPhrase,
          },
        ),
      );
      if (response.statusCode == 200) {
        final userBox = await _getUserBox();
        await userBox.delete(accountId);
        debugPrint('Deleted $accountId everywhere from primary confirmation');
        return true;
      }
      _lastErrorMessage =
          response.data is Map ? response.data['error']?.toString() : null;
      debugPrint('Primary server delete failed: ${response.statusCode}');
      return false;
    } on DioException catch (e) {
      _lastErrorMessage = e.response?.data is Map
          ? e.response?.data['error']?.toString()
          : null;
      debugPrint('deleteSingleAccountEverywhere error: $e');
      return false;
    } catch (e) {
      debugPrint('deleteSingleAccountEverywhere error: $e');
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
    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
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
      final response = await _requestWithRetry(
        (_) => _dio.get(
          'sync/get-data/',
          queryParameters: {'data_type': 'otp_accounts', 'device_id': deviceId},
        ),
      );

      if (response.statusCode == 200 &&
          response.data['encrypted_content'] != null) {
        final encryptedContent = response.data['encrypted_content'];

        if (encryptedContent.toString().isEmpty) {
          debugPrint('Cloud has no data');
          return;
        }

        final cloudAccounts = tryDecodeAccountsPayload(
          encryptedContent.toString(),
          _encryptionKey!,
        );

        if (cloudAccounts == null) {
          // The blob is there but this device's key does not open it. Say so
          // rather than leaving the account list silently empty.
          _vaultKeyMismatch = true;
          _lastErrorMessage = _vaultKeyMismatchMessage();
          debugPrint('Cloud vault could not be decrypted with this key');
          return;
        }
        _vaultKeyMismatch = false;

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
          'Merged $added accounts from cloud and updated $updatedTitles titles',
        );
        await syncAccounts();
      }
    } catch (e) {
      debugPrint('downloadAndMergeAccounts error: $e');
    }
  }

  Future<Set<String>> _fetchTombstones() async {
    try {
      final response = await _requestWithRetry(
        (_) => _dio.get('sync/tombstones/'),
      );
      if (response.statusCode == 200) {
        final List ids = response.data['tombstoned_ids'] ?? [];
        return ids.cast<String>().toSet();
      }
    } catch (_) {}
    return {};
  }

  // ─── Main sync ────────────────────────────────────────────────────────────
  Future<bool> syncAccounts({
    bool preferLocalTitleChanges = false,
    bool retryOnConflict = true,
  }) async {
    if (!(await isSyncEnabled())) {
      debugPrint('Sync disabled by user preference');
      return true;
    }

    await _updateAuthHeader();
    final prefs = await SharedPreferences.getInstance();
    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'Sign in to enable automatic cross-platform sync.';
      return false;
    }

    if (!await _ensureEncryptionKeyAvailable()) {
      _lastErrorMessage = _syncUnlockRequiredMessage();
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
      // True when the cloud holds a vault this device's key cannot open. The
      // upload below replaces the stored blob outright and the server keeps no
      // older version, so uploading in that state would destroy the only copy
      // of accounts this device has never been able to read.
      var cloudVaultUnreadable = false;

      try {
        final downloadResponse = await _requestWithRetry(
          (_) => _dio.get(
            'sync/get-data/',
            queryParameters: {
              'data_type': 'otp_accounts',
              'device_id': deviceId,
            },
          ),
        );

        if (downloadResponse.statusCode == 200 &&
            downloadResponse.data['encrypted_content'] != null) {
          final encryptedContent = downloadResponse.data['encrypted_content'];

          if (encryptedContent.toString().isEmpty) {
            debugPrint('Cloud has empty data');
          } else {
            final cloudAccounts = tryDecodeAccountsPayload(
              encryptedContent.toString(),
              _encryptionKey!,
            );
            if (cloudAccounts == null) {
              cloudVaultUnreadable = true;
              debugPrint('Cloud vault could not be decrypted with this key');
            } else {
              cloudVersion = downloadResponse.data['version'] ?? 0;
              for (var a in cloudAccounts) {
                cloudAccountsMap[a['id']] = a;
              }
              if (downloadResponse.data['deleted_accounts'] != null) {
                cloudDeletedAccounts = List<String>.from(
                  jsonDecode(downloadResponse.data['deleted_accounts']),
                );
              }
              debugPrint('Cloud has ${cloudAccounts.length} accounts');
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

      if (cloudVaultUnreadable) {
        // Stop before the upload. Merging cannot see the accounts that are up
        // there, so an upload now would write a vault missing every one of
        // them over the only copy that exists.
        _vaultKeyMismatch = true;
        _lastErrorMessage = _vaultKeyMismatchMessage();
        debugPrint('Sync aborted - refusing to overwrite an unreadable vault');
        return false;
      }
      _vaultKeyMismatch = false;

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
        'Added $addedFromCloud accounts from cloud and updated $updatedTitlesFromCloud titles',
      );

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

      final encrypted = _encryptSyncBlob(
        jsonEncode(finalData),
        _encryptionKey!,
        'otp_accounts',
      );
      final newVersion = cloudVersion + 1;

      final uploadResponse = await _requestWithRetry(
        (_) => _dio.post(
          'sync/sync/',
          data: {
            'data_type': 'otp_accounts',
            'encrypted_content': encrypted,
            'version': newVersion,
            'device_id': deviceId,
            'item_count': finalData.length,
            'deleted_accounts': jsonEncode(cloudDeletedAccounts),
          },
        ),
      );

      if (uploadResponse.statusCode == 200) {
        debugPrint('Sync successful - ${finalData.length} accounts synced');
        return true;
      } else {
        debugPrint('Sync upload failed: ${uploadResponse.statusCode}');
        _lastErrorMessage =
            'The server did not accept the upload. Please try again.';
        return false;
      }
    } on DioException catch (e) {
      if (_isStaleUploadConflict(e)) {
        // Another device wrote while this cycle was building its upload. Start
        // over once: the download at the top picks up that newer copy and
        // merges it, and only then is anything written.
        if (retryOnConflict) {
          debugPrint('Sync conflict - re-reading and merging before retrying');
          return syncAccounts(
            preferLocalTitleChanges: preferLocalTitleChanges,
            retryOnConflict: false,
          );
        }
        _lastErrorMessage =
            'Another device is syncing right now. This will finish on the next sync.';
        debugPrint('Sync conflict persisted; leaving it for the next cycle');
        return false;
      }
      _lastErrorMessage = _isSessionRevokedError(e)
          ? (_extractServerError(e.response?.data) ??
              'This device session is no longer active.')
          : _friendlyRequestError(e, 'Sync failed. Please try again.');
      debugPrint('syncAccounts error: $e');
      return false;
    } catch (e) {
      _lastErrorMessage = NetworkErrorMessages.forUnexpected(
        e,
        'Sync failed. Please try again.',
      );
      debugPrint('syncAccounts error: $e');
      return false;
    }
  }

  Future<void> _applyAuthenticatedResponse(
    Map<String, dynamic> data, {
    String? password,
    String? transferredEncryptionKey,
    bool enableSyncByDefault = true,
  }) async {
    final user = data['user'] as Map?;
    final canonicalUsername = user?['username']?.toString() ?? '';
    await _secureStorage.write(
      SecureStorageService.accessTokenKey,
      data['access'],
    );
    await _secureStorage.write(
      SecureStorageService.refreshTokenKey,
      data['refresh'],
    );
    await _secureStorage.write(
      SecureStorageService.currentUserKey,
      canonicalUsername,
    );
    await _secureStorage.write(
      SecureStorageService.localVaultUserKey,
      canonicalUsername,
    );
    await _secureStorage.write(
      SecureStorageService.userEmailKey,
      user?['email']?.toString() ?? '',
    );
    await _secureStorage.write(
      SecureStorageService.userIdKey,
      user?['id']?.toString() ?? '',
    );
    OTPService().clearCachedUserId();
    await _updateAuthHeader();

    if (transferredEncryptionKey != null &&
        transferredEncryptionKey.isNotEmpty) {
      await _activateSyncEncryptionKey(
        transferredEncryptionKey,
        enableSyncByDefault: enableSyncByDefault,
      );
      return;
    }

    if (password != null && password.isNotEmpty) {
      final encryptionKey = await _resolveVaultKey(
        canonicalUsername: canonicalUsername,
        password: password,
        typedIdentifier: user?['email']?.toString(),
      );
      await _activateSyncEncryptionKey(
        encryptionKey,
        enableSyncByDefault: enableSyncByDefault,
      );
      return;
    }

    await setSyncEnabled(false);
  }

  Future<void> _restoreSyncedVaultDataAfterUnlock() async {
    try {
      await migrateLegacyLocalAccounts();
    } catch (e) {
      debugPrint('Legacy account migration error after unlock: $e');
    }

    try {
      final userBox = await _getUserBox();
      debugPrint(
        'User box ${await _getUserBoxName()} has ${userBox.length} accounts',
      );
    } catch (e) {
      debugPrint('User box load error after unlock: $e');
    }

    try {
      if (await isSyncEnabled()) {
        await downloadAndMergeAccounts();
      }
    } catch (e) {
      debugPrint('Cloud restore error after unlock: $e');
    }
  }

  Future<String?> getAvailableEncryptionKey() async {
    final ready = await _ensureEncryptionKeyAvailable();
    if (!ready) {
      return null;
    }
    return _encryptionKey;
  }

  String _passwordlessUnlockKeyStorageKey(String requestId) =>
      '$_passwordlessUnlockKeyPrefix$requestId';

  Future<void> _storePasswordlessUnlockTransferKey(
    String requestId,
    String unlockTransferKey,
  ) async {
    final trimmedRequestId = requestId.trim();
    final trimmedTransferKey = unlockTransferKey.trim();
    if (trimmedRequestId.isEmpty || trimmedTransferKey.isEmpty) {
      return;
    }
    await _secureStorage.write(
      _passwordlessUnlockKeyStorageKey(trimmedRequestId),
      trimmedTransferKey,
    );
  }

  Future<String?> _getStoredPasswordlessUnlockTransferKey(
    String requestId,
  ) async {
    final trimmedRequestId = requestId.trim();
    if (trimmedRequestId.isEmpty) {
      return null;
    }
    return _secureStorage.read(
      _passwordlessUnlockKeyStorageKey(trimmedRequestId),
    );
  }

  Future<void> _clearPasswordlessUnlockTransferKey(String requestId) async {
    final trimmedRequestId = requestId.trim();
    if (trimmedRequestId.isEmpty) {
      return;
    }
    await _secureStorage.delete(
      _passwordlessUnlockKeyStorageKey(trimmedRequestId),
    );
  }

  List<String> _passwordlessUnlockTransferKeyCandidates({
    String? responseUnlockTransferKey,
    String? providedUnlockTransferKey,
    String? storedUnlockTransferKey,
  }) {
    final orderedCandidates = <String>[
      responseUnlockTransferKey?.trim() ?? '',
      providedUnlockTransferKey?.trim() ?? '',
      storedUnlockTransferKey?.trim() ?? '',
    ];

    final uniqueCandidates = <String>[];
    for (final candidate in orderedCandidates) {
      if (candidate.isEmpty || uniqueCandidates.contains(candidate)) {
        continue;
      }
      uniqueCandidates.add(candidate);
    }
    return uniqueCandidates;
  }

  String? _restoreTransferredSyncEncryptionKey(
    String? syncUnlockPayload,
    String? unlockTransferKey,
  ) {
    final payload = syncUnlockPayload?.trim() ?? '';
    final transferKey = unlockTransferKey?.trim() ?? '';
    if (payload.isEmpty || transferKey.isEmpty) {
      return null;
    }

    try {
      return EncryptionService.decryptSensitiveSyncPayload(
        payload,
        transferKey,
        context: _passwordlessSyncUnlockContext,
      );
    } catch (e) {
      debugPrint('Passwordless sync unlock restore error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getEncryptedSyncData(String dataType) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to load synced data.';
      return null;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      var deviceId = prefs.getString('device_id') ?? '';
      if (deviceId.isEmpty) {
        deviceId = DateTime.now().millisecondsSinceEpoch.toString();
        await prefs.setString('device_id', deviceId);
      }

      final response = await _requestWithRetry(
        (_) => _dio.get(
          'sync/get-data/',
          queryParameters: {'data_type': dataType, 'device_id': deviceId},
        ),
      );

      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data as Map);
      }

      _lastErrorMessage = 'Could not load synced data.';
      return null;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      _lastErrorMessage = _friendlyRequestError(
        e,
        'Could not load synced data.',
      );
      return null;
    } catch (_) {
      _lastErrorMessage = 'Could not load synced data.';
      return null;
    }
  }

  /// True when the server refused an upload because another device wrote
  /// first. Not an error: the next sync reads that newer copy and merges.
  bool _isStaleUploadConflict(DioException e) {
    if (e.response?.statusCode != 409) return false;
    final data = e.response?.data;
    return data is Map && data['conflict'] == true;
  }

  Future<bool> uploadEncryptedSyncData(
    String dataType, {
    required String encryptedContent,
    required int version,
    String deletedAccounts = 'N/A',
    int? itemCount,
  }) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to save synced data.';
      return false;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      var deviceId = prefs.getString('device_id') ?? '';
      if (deviceId.isEmpty) {
        deviceId = DateTime.now().millisecondsSinceEpoch.toString();
        await prefs.setString('device_id', deviceId);
      }

      final response = await _requestWithRetry(
        (_) => _dio.post(
          'sync/sync/',
          data: {
            'data_type': dataType,
            'encrypted_content': encryptedContent,
            'version': version,
            'device_id': deviceId,
            if (itemCount != null) 'item_count': itemCount,
            'deleted_accounts': deletedAccounts,
          },
        ),
      );

      return response.statusCode == 200;
    } on DioException catch (e) {
      _lastErrorMessage = _friendlyRequestError(
        e,
        'Could not save synced data.',
      );
      return false;
    } catch (_) {
      _lastErrorMessage = 'Could not save synced data.';
      return false;
    }
  }

  Future<bool> unlockSyncOnCurrentDevice(String password) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    final canonicalUsername =
        await _secureStorage.read(SecureStorageService.currentUserKey) ?? '';
    if (token == null || token.isEmpty || canonicalUsername.isEmpty) {
      _lastErrorMessage =
          'You need to be signed in before unlocking sync on this device.';
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'auth/unlock-sync/',
          data: {'password': password},
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      if (response.statusCode == 200) {
        final storedEmail =
            await _secureStorage.read(SecureStorageService.userEmailKey);
        final resolved = await _resolveVaultKeyResult(
          canonicalUsername: canonicalUsername,
          password: password,
          typedIdentifier: storedEmail,
        );

        // Decided before activation, because activation syncs -- and a sync
        // that cannot decode something would otherwise be reported back to the
        // user as a wrong password.
        if (!resolved.opened) {
          _lastErrorMessage = _vaultKeyMismatchMessage();
          return false;
        }

        await _activateSyncEncryptionKey(resolved.key);
        return true;
      }

      _lastErrorMessage = 'Could not unlock sync on this device.';
      return false;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not unlock sync on this device.';
      return false;
    } catch (_) {
      _lastErrorMessage = 'Could not unlock sync on this device.';
      return false;
    }
  }

  Future<bool> unlockSyncAfterPasswordless(String password) async {
    return unlockSyncOnCurrentDevice(password);
  }

  Future<DeviceSessionInfo?> getCurrentDeviceSession() async {
    final sessions = await getActiveDeviceSessions();
    for (final session in sessions) {
      if (session.isCurrent) {
        return session;
      }
    }
    return null;
  }

  Future<bool> clearRestoredAccountTombstones(List<String> accountIds) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage =
          'You need to be signed in to restore synced accounts.';
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (_) => _dio.post(
          'sync/restore-accounts/',
          data: {'account_ids': accountIds},
        ),
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not prepare synced restore on the server.';
      return false;
    } catch (_) {
      _lastErrorMessage = 'Could not prepare synced restore on the server.';
      return false;
    }
  }

  Future<bool> uploadCurrentAccountsAsAuthoritative() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'Sign in to sync restored accounts everywhere.';
      return false;
    }

    if (!await _ensureEncryptionKeyAvailable()) {
      _lastErrorMessage = _syncUnlockRequiredMessage();
      return false;
    }

    final userBox = await _getUserBox();

    try {
      // A restore says "make my accounts look like this snapshot", not "throw
      // away whatever else is in the cloud". Merge the stored copy in first, so
      // an account that exists only on another device survives a restore here,
      // and refuse outright if it cannot be read -- overwriting a vault this
      // device cannot open is the one thing sync must never do.
      var cloudVersion = 0;
      var storedDeletions = '[]';
      try {
        final existing = await getEncryptedSyncData('otp_accounts');
        if (existing != null) {
          cloudVersion =
              int.tryParse(existing['version']?.toString() ?? '0') ?? 0;
          final storedDeletedRaw =
              existing['deleted_accounts']?.toString() ?? '';
          if (storedDeletedRaw.isNotEmpty) storedDeletions = storedDeletedRaw;

          final cipherText = existing['encrypted_content']?.toString() ?? '';
          if (cipherText.isNotEmpty) {
            if (tryDecodeAccountsPayload(cipherText, _encryptionKey!) == null) {
              _lastErrorMessage = _vaultKeyMismatchMessage();
              return false;
            }
            await downloadAndMergeAccounts();
          }
        }
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) rethrow;
      }

      final finalData = await Future.wait(
        userBox.values.map((a) async {
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

      final encrypted = _encryptSyncBlob(
        jsonEncode(finalData),
        _encryptionKey!,
        'otp_accounts',
      );
      return await uploadEncryptedSyncData(
        'otp_accounts',
        encryptedContent: encrypted,
        version: cloudVersion + 1,
        itemCount: finalData.length,
        // Carried forward, not reset. Clearing this used to resurrect every
        // account the user had ever deleted.
        deletedAccounts: storedDeletions,
      );
    } catch (_) {
      _lastErrorMessage = 'Could not sync restored accounts everywhere.';
      return false;
    }
  }

  Future<Map<String, dynamic>?> startPasswordlessLogin(
    String email, {
    String? password,
  }) async {
    try {
      _lastErrorMessage = null;
      final loginIdentifier = email.trim();
      await _updateAuthHeader();
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _dio.post(
        'auth/passwordless-start/',
        data: {
          'email': loginIdentifier,
          'username': loginIdentifier,
          if (password != null && password.isNotEmpty) 'password': password,
          'device_id': deviceId,
          'device_label': deviceLabel,
          'device_kind': _deviceKind(),
        },
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = Map<String, dynamic>.from(response.data as Map);
        final requestId = data['request_id']?.toString() ?? '';
        final unlockTransferKey = data['unlock_transfer_key']?.toString() ?? '';
        if (requestId.isNotEmpty && unlockTransferKey.isNotEmpty) {
          await _storePasswordlessUnlockTransferKey(
            requestId,
            unlockTransferKey,
          );
        }
        final access = data['access']?.toString() ?? '';
        final refresh = data['refresh']?.toString() ?? '';
        if (data['success'] == true &&
            access.isNotEmpty &&
            refresh.isNotEmpty) {
          await _applyAuthenticatedResponse(
            data,
            password: password,
            enableSyncByDefault: password != null && password.isNotEmpty,
          );
        }
        return data;
      }
      _lastErrorMessage = 'Passwordless sign-in could not be started.';
      return null;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Passwordless sign-in could not be started.';
      return e.response?.data is Map
          ? Map<String, dynamic>.from(e.response!.data as Map)
          : null;
    } catch (e) {
      _lastErrorMessage = 'Passwordless sign-in could not be started.';
      return null;
    }
  }

  Future<Map<String, dynamic>?> pollPasswordlessLogin(
    String requestId, {
    String? password,
    String? unlockTransferKey,
  }) async {
    try {
      _lastErrorMessage = null;
      await _updateAuthHeader();
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _dio.post(
        'auth/passwordless-poll/',
        data: {
          'request_id': requestId,
          'device_id': deviceId,
          'device_label': deviceLabel,
          'device_kind': _deviceKind(),
        },
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      final responseUnlockTransferKey =
          data['unlock_transfer_key']?.toString().trim() ?? '';
      if (responseUnlockTransferKey.isNotEmpty) {
        await _storePasswordlessUnlockTransferKey(
          requestId,
          responseUnlockTransferKey,
        );
      }
      final storedUnlockTransferKey =
          await _getStoredPasswordlessUnlockTransferKey(requestId);
      final unlockTransferKeyCandidates =
          _passwordlessUnlockTransferKeyCandidates(
        responseUnlockTransferKey: responseUnlockTransferKey,
        providedUnlockTransferKey: unlockTransferKey,
        storedUnlockTransferKey: storedUnlockTransferKey,
      );
      if (data['success'] == true && data['status'] == 'approved') {
        String? transferredEncryptionKey;
        final syncUnlockPayload = data['sync_unlock_payload']?.toString();

        if (password == null || password.isEmpty) {
          for (final transferKey in unlockTransferKeyCandidates) {
            transferredEncryptionKey = _restoreTransferredSyncEncryptionKey(
              syncUnlockPayload,
              transferKey,
            );
            if (transferredEncryptionKey != null &&
                transferredEncryptionKey.isNotEmpty) {
              break;
            }
          }
          if (syncUnlockPayload != null &&
              syncUnlockPayload.trim().isNotEmpty &&
              (transferredEncryptionKey == null ||
                  transferredEncryptionKey.isEmpty)) {
            data['requires_password_for_sync'] = true;
            data['sync_unlock_message'] =
                'Passwordless sign-in worked, but this device still needs your account password once to unlock encrypted sync.';
          } else if (transferredEncryptionKey != null &&
              transferredEncryptionKey.isNotEmpty) {
            data['requires_password_for_sync'] = false;
          }
        } else {
          data['requires_password_for_sync'] = false;
        }

        await _applyAuthenticatedResponse(
          data,
          password: password,
          transferredEncryptionKey: transferredEncryptionKey,
          enableSyncByDefault: (password != null && password.isNotEmpty) ||
              (transferredEncryptionKey != null &&
                  transferredEncryptionKey.isNotEmpty),
        );
        await _clearPasswordlessUnlockTransferKey(requestId);
      }
      final statusText = data['status']?.toString().trim().toLowerCase() ?? '';
      if (statusText == 'denied' ||
          statusText == 'expired' ||
          statusText == 'completed') {
        await _clearPasswordlessUnlockTransferKey(requestId);
      }
      return data;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Passwordless sign-in could not be completed.';
      return e.response?.data is Map
          ? Map<String, dynamic>.from(e.response!.data as Map)
          : null;
    } catch (e) {
      _lastErrorMessage = 'Passwordless sign-in could not be completed.';
      return null;
    }
  }

  Future<bool> send2FACode(String email, String password) async {
    try {
      _lastErrorMessage = null;
      final loginIdentifier = email.trim();
      final r = await _dio.post(
        'send-2fa/',
        data: {
          'email': loginIdentifier,
          'username': loginIdentifier,
          'password': password,
        },
      );
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

  Future<bool> verify2FACode(String email, String code) async {
    try {
      _lastErrorMessage = null;
      final loginIdentifier = email.trim();
      final r = await _dio.post(
        'verify-2fa/',
        data: {
          'email': loginIdentifier,
          'username': loginIdentifier,
          'code': code.trim(),
        },
      );
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
    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null) {
      debugPrint('No token available for delete OTP');
      return false;
    }
    try {
      final response = await _dio.post(
        'send-delete-otp/',
        data: {'username': username},
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
        ),
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
    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null) return false;
    try {
      final response = await _dio.post(
        'verify-delete-otp/',
        data: {'username': username, 'code': code},
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
        ),
      );
      return response.data['success'] == true;
    } catch (e) {
      debugPrint('verifyDeleteOtp error: $e');
      return false;
    }
  }

  Future<bool> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;
    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null) return false;

    final username = await _getCurrentUserId();
    final deviceLabel = await _buildDeviceLabel();

    try {
      final r = await _dio.post(
        'auth/change_password/',
        data: {
          'current_password': currentPassword,
          'new_password': newPassword,
          'device_label': deviceLabel,
        },
      );

      if (r.statusCode != 200) return false;

      // With a keyring the vault key does not depend on the password, so a
      // password change re-wraps thirty-two bytes and leaves every account,
      // password and secure text exactly where it is. Nothing is re-encrypted,
      // so nothing can be lost doing it.
      if (await rewrapKeyringForNewPassword(newPassword)) {
        debugPrint('Password changed and keyring re-wrapped');
        return true;
      }

      // No keyring yet: fall back to re-keying the vault in place, which reads
      // what is stored before writing it.
      final rekeyed = await repairCloudVaultKey(newPassword);
      if (!rekeyed) {
        // The password did change; only the rewrite did not. The stored vault
        // is left exactly as it was rather than being overwritten. Move this
        // device onto the new key so it is consistent with the account, and
        // let the sync-locked path offer the rest.
        final canonical = _deriveVaultKey(username, newPassword);
        await _storeEncryptionKey(canonical);
        _encryptionKey = canonical;
        _lastErrorMessage =
            'Your password was changed, but your synced vault could not be re-encrypted here, so it was left untouched. Sign out and back in with your new password on a device that still syncs -- that repairs it automatically.';
        debugPrint('Password changed; vault re-key deferred');
        return true;
      }

      debugPrint('Password changed and vault re-encrypted successfully');
      return true;
    } catch (e) {
      debugPrint('changePassword error: $e');
      return false;
    }
  }

  Future<bool> sendPasswordResetCode(String email) async {
    try {
      _lastErrorMessage = null;
      final r = await _dio.post(
        'send-reset-code/',
        data: {'email': email.trim()},
      );
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
    String email,
    String code,
    String newPassword,
  ) async {
    try {
      _lastErrorMessage = null;
      final r = await _dio.post(
        'reset-password/',
        data: {
          'email': email.trim(),
          'code': code.trim(),
          'new_password': newPassword,
        },
      );
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
    String email,
    String password,
    String recoveryCode,
  ) async {
    try {
      _lastErrorMessage = null;
      final loginIdentifier = email.trim();
      await _updateAuthHeader();
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _dio.post(
        'recovery-code/login/',
        data: {
          'email': loginIdentifier,
          'username': loginIdentifier,
          'password': password,
          'recovery_code': recoveryCode.trim(),
          'device_id': deviceId,
          'device_label': deviceLabel,
        },
      );
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
      final response = await _dio.post(
        'recovery-code/check-email/',
        data: {'email': email.trim()},
      );
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
    String email,
    String recoveryCode,
    String newPassword,
  ) async {
    try {
      _lastErrorMessage = null;
      await _updateAuthHeader();
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _dio.post(
        'recovery-code/reset-password/',
        data: {
          'email': email.trim(),
          'recovery_code': recoveryCode.trim(),
          'new_password': newPassword,
          'device_id': deviceId,
          'device_label': deviceLabel,
          'device_kind': _deviceKind(),
        },
      );
      if (response.data['success'] == true) {
        final canonicalUsername =
            response.data['user']?['username']?.toString() ?? '';
        await _secureStorage.write(
          SecureStorageService.accessTokenKey,
          response.data['access'],
        );
        await _secureStorage.write(
          SecureStorageService.refreshTokenKey,
          response.data['refresh'],
        );
        await _secureStorage.write(
          SecureStorageService.currentUserKey,
          canonicalUsername,
        );
        await _secureStorage.write(
          SecureStorageService.userEmailKey,
          response.data['user']?['email']?.toString() ?? email.trim(),
        );
        await _secureStorage.write(
          SecureStorageService.userIdKey,
          response.data['user']?['id']?.toString() ?? '',
        );
        OTPService().clearCachedUserId();
        await _updateAuthHeader();

        final encryptionKey = EncryptionService.generateKey(
          canonicalUsername + newPassword,
          'beatzLockKenya2099',
        );
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

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage =
          'You need to be signed in to view recovery code status.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.get(
          'backup-codes/status/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
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

  Future<List<Map<String, dynamic>>> getBackupCodeGenerationRequests() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage =
          'You need to be signed in to review backup-code requests.';
      return const [];
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.get(
          'backup-code-requests/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      }
      return const [];
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not load backup-code requests.';
      return const [];
    } catch (_) {
      _lastErrorMessage = 'Could not load backup-code requests.';
      return const [];
    }
  }

  Future<String?> createBackupCodeGenerationRequest() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage =
          'You need to be signed in to request backup-code download.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'backup-code-requests/start/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          response.data is Map) {
        final data = Map<String, dynamic>.from(response.data as Map);
        return data['primary_device_label']?.toString();
      }
      _lastErrorMessage = 'Could not send the backup-code request.';
      return null;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not send the backup-code request.';
      return null;
    } catch (_) {
      _lastErrorMessage = 'Could not send the backup-code request.';
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
        {'fileName': fileName, 'bytes': Uint8List.fromList(bytes)},
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

  /// Escrow the vault key under codes handed back with a freshly generated
  /// PDF. Silent on absence: an un-updated server simply sends no header.
  Future<void> _escrowUnderHeaderCodes(String? headerValue) async {
    final codes = (headerValue ?? '')
        .split(',')
        .map((code) => code.trim())
        .where((code) => code.isNotEmpty)
        .toList();
    if (codes.isEmpty) return;
    await publishVaultKeyEscrow(codes);
  }

  Future<String?> downloadBackupCodesPdf({bool preferDarkTheme = false}) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to download backup codes.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.get<List<int>>(
          'backup-codes/download/',
          queryParameters: {'pdf_theme': preferDarkTheme ? 'dark' : 'light'},
          options: Options(
            responseType: ResponseType.bytes,
            headers: {
              'Authorization': 'Bearer $accessToken',
              'X-PDF-Theme': preferDarkTheme ? 'dark' : 'light',
            },
          ),
        ),
      );

      final bytes = response.data;
      if (response.statusCode != 200 || bytes == null || bytes.isEmpty) {
        _lastErrorMessage = 'Backup code PDF download failed.';
        return null;
      }

      // The only moment this app holds the codes in plaintext. Wrap the vault
      // key under them now so a later password reset can recover it, then let
      // them go -- they are never written to storage.
      await _escrowUnderHeaderCodes(response.headers.value('x-backup-codes'));

      final username =
          await _secureStorage.read(SecureStorageService.currentUserKey) ??
              'user';
      final fileName = _backupCodesFileName(username);
      return await _saveBackupCodesPdf(fileName: fileName, bytes: bytes);
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

  Future<String?> approveBackupCodeGenerationRequest(
    String requestId, {
    bool preferDarkTheme = false,
  }) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage =
          'You need to be signed in to approve backup-code requests.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'backup-code-requests/$requestId/approve/',
          options: Options(
            headers: {
              'Authorization': 'Bearer $accessToken',
              'X-PDF-Theme': preferDarkTheme ? 'dark' : 'light',
            },
          ),
          queryParameters: {'pdf_theme': preferDarkTheme ? 'dark' : 'light'},
        ),
      );

      if (response.statusCode == 200 && response.data is Map) {
        final data = Map<String, dynamic>.from(response.data as Map);
        final encoded = data['pdf_base64']?.toString() ?? '';
        final fileName = data['file_name']?.toString() ?? '';
        if (encoded.isEmpty || fileName.isEmpty) {
          _lastErrorMessage = 'Backup-code PDF payload was incomplete.';
          return null;
        }

        final codes = ((data['codes'] as List?) ?? const [])
            .map((code) => code.toString())
            .toList();
        if (codes.isNotEmpty) {
          await publishVaultKeyEscrow(codes);
        }

        final bytes = base64Decode(encoded);
        return await _saveBackupCodesPdf(fileName: fileName, bytes: bytes);
      }

      _lastErrorMessage = 'Could not approve this backup-code request.';
      return null;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not approve this backup-code request.';
      return null;
    } catch (_) {
      _lastErrorMessage = 'Could not save backup codes on this device.';
      return null;
    }
  }

  Future<bool> denyBackupCodeGenerationRequest(String requestId) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage =
          'You need to be signed in to deny backup-code requests.';
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'backup-code-requests/$requestId/deny/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not deny this backup-code request.';
      return false;
    } catch (_) {
      _lastErrorMessage = 'Could not deny this backup-code request.';
      return false;
    }
  }

  Future<List<AppNotificationItem>> getNotifications() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to view notifications.';
      return [];
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.get(
          'notifications/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );

      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List)
            .whereType<Map>()
            .map(
              (item) =>
                  AppNotificationItem.fromJson(Map<String, dynamic>.from(item)),
            )
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
    String notificationId,
  ) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to view notifications.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.get(
          'notifications/$notificationId/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
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

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to manage notifications.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'notifications/mark-all-read/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
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

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
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
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
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

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
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
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  Future<bool> logAppPinChangedNotification({
    required String deviceLabel,
  }) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'notifications/log-event/',
          data: {'event_type': 'app_pin_changed', 'device_label': deviceLabel},
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  Future<bool> logAccountsImportedNotification({
    required int importedCount,
    int skippedCount = 0,
    String? sourceLabel,
  }) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'notifications/log-event/',
          data: {
            'event_type': 'accounts_imported',
            'imported_count': importedCount,
            'skipped_count': skippedCount,
            'source_label': sourceLabel,
          },
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  Future<bool> logPasswordsImportedNotification({
    required int importedCount,
    String? sourceLabel,
  }) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'notifications/log-event/',
          data: {
            'event_type': 'passwords_imported',
            'imported_count': importedCount,
            'source_label': sourceLabel,
          },
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
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

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
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
          queryParameters: {'device_id': deviceId, 'device_label': deviceLabel},
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );

      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List)
            .whereType<Map>()
            .map(
              (item) =>
                  DeviceSessionInfo.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList();
      }

      _lastErrorMessage = 'Could not load active devices.';
      return [];
    } on DioException catch (e) {
      _lastErrorMessage = _friendlyRequestError(
        e,
        'Could not load active devices.',
      );
      return [];
    } catch (e) {
      _lastErrorMessage = 'Could not load active devices.';
      return [];
    }
  }

  Future<bool> registerPushToken({
    required String token,
    String platform = 'android',
    bool reportError = false,
    bool allowEmptyToken = false,
  }) async {
    await _updateAuthHeader();
    if (reportError) {
      _lastErrorMessage = null;
    }

    final accessToken = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (accessToken == null || accessToken.isEmpty) {
      if (reportError) {
        _lastErrorMessage = 'You need to be signed in to enable notifications.';
      }
      return false;
    }

    final trimmedToken = token.trim();
    if (trimmedToken.isEmpty && !allowEmptyToken) {
      if (reportError) {
        _lastErrorMessage = 'Notification token is missing.';
      }
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (freshAccessToken) => _dio.post(
          'device-sessions/push-token/',
          data: {
            'token': trimmedToken,
            'platform': platform.trim().isEmpty ? 'android' : platform.trim(),
          },
          options: Options(
            headers: {'Authorization': 'Bearer $freshAccessToken'},
          ),
        ),
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      if (reportError) {
        _lastErrorMessage = _extractServerError(e.response?.data) ??
            'Could not enable push notifications.';
      }
      return false;
    } catch (_) {
      if (reportError) {
        _lastErrorMessage = 'Could not enable push notifications.';
      }
      return false;
    }
  }

  Future<bool> revokeDeviceSession(String sessionId) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to manage devices.';
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'device-sessions/$sessionId/revoke/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
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

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to manage devices.';
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'device-sessions/$sessionId/set-primary/',
          data: {'password': password},
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
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

  Future<List<Map<String, dynamic>>> getPasswordlessRequests() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage =
          'You need to be signed in to review sign-in requests.';
      return const [];
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.get(
          'passwordless-requests/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      }
      return const [];
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not load passwordless sign-in requests.';
      return const [];
    } catch (_) {
      _lastErrorMessage = 'Could not load passwordless sign-in requests.';
      return const [];
    }
  }

  Future<bool> approvePasswordlessRequest(
    String requestId, {
    required String enteredCode,
    String? unlockTransferKey,
    bool attemptSyncUnlockTransfer = true,
  }) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;
    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to approve sign-ins.';
      return false;
    }

    try {
      String? syncUnlockPayload;
      if (attemptSyncUnlockTransfer) {
        var resolvedUnlockTransferKey = unlockTransferKey?.trim() ?? '';
        if (resolvedUnlockTransferKey.isEmpty) {
          final requests = await getPasswordlessRequests();
          for (final item in requests) {
            final itemRequestId = item['id']?.toString() ?? '';
            if (itemRequestId != requestId) {
              continue;
            }
            resolvedUnlockTransferKey =
                item['unlock_transfer_key']?.toString().trim() ?? '';
            break;
          }
        }

        if (resolvedUnlockTransferKey.isEmpty) {
          _lastErrorMessage =
              'This sign-in request is missing its sync transfer key. Refresh and try again.';
          return false;
        }

        final encryptionKey = await getAvailableEncryptionKey();
        if (encryptionKey == null || encryptionKey.isEmpty) {
          _lastErrorMessage =
              'Unlock sync on this primary phone first, then approve again.';
          return false;
        }

        syncUnlockPayload = EncryptionService.encryptSensitiveSyncPayload(
          encryptionKey,
          resolvedUnlockTransferKey,
          context: _passwordlessSyncUnlockContext,
        );
      }
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'passwordless-requests/$requestId/approve/',
          data: {
            'code': enteredCode,
            if (syncUnlockPayload != null && syncUnlockPayload.isNotEmpty)
              'sync_unlock_payload': syncUnlockPayload,
          },
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not approve this sign-in request.';
      return false;
    } catch (_) {
      _lastErrorMessage = 'Could not approve this sign-in request.';
      return false;
    }
  }

  Future<bool> denyPasswordlessRequest(String requestId) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;
    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to deny sign-ins.';
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'passwordless-requests/$requestId/deny/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not deny this sign-in request.';
      return false;
    } catch (_) {
      _lastErrorMessage = 'Could not deny this sign-in request.';
      return false;
    }
  }

  Future<bool> deletePasswordlessRequestLog(String requestId) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;
    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to manage sign-in logs.';
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'passwordless-requests/$requestId/delete-log/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not delete this sign-in log.';
      return false;
    } catch (_) {
      _lastErrorMessage = 'Could not delete this sign-in log.';
      return false;
    }
  }

  Future<int?> clearPasswordlessRequestLogs() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;
    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to manage sign-in logs.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'passwordless-requests/clear-logs/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      if (response.statusCode == 200 && response.data is Map) {
        return int.tryParse(
              response.data['cleared_count']?.toString() ?? '0',
            ) ??
            0;
      }
      _lastErrorMessage = 'Could not clear the sign-in logs.';
      return null;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not clear the sign-in logs.';
      return null;
    } catch (_) {
      _lastErrorMessage = 'Could not clear the sign-in logs.';
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getBulkDeleteRequests() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to review delete requests.';
      return const [];
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.get(
          'bulk-delete-requests/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      }
      return const [];
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not load OTP delete requests.';
      return const [];
    } catch (_) {
      _lastErrorMessage = 'Could not load OTP delete requests.';
      return const [];
    }
  }

  Future<String?> createBulkDeleteRequest({
    required List<String> accountIds,
    required DateTime rangeStartDate,
    required DateTime rangeEndDate,
  }) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to request cloud deletion.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'bulk-delete-requests/start/',
          data: {
            'account_ids': accountIds,
            'range_start_date': DateTime(
              rangeStartDate.year,
              rangeStartDate.month,
              rangeStartDate.day,
            ).toIso8601String(),
            'range_end_date': DateTime(
              rangeEndDate.year,
              rangeEndDate.month,
              rangeEndDate.day,
            ).toIso8601String(),
          },
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          response.data is Map) {
        final data = Map<String, dynamic>.from(response.data as Map);
        return data['primary_device_label']?.toString();
      }
      _lastErrorMessage = 'Could not send the delete request.';
      return null;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not send the delete request.';
      return null;
    } catch (_) {
      _lastErrorMessage = 'Could not send the delete request.';
      return null;
    }
  }

  Future<int?> approveBulkDeleteRequest(String requestId) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage =
          'You need to be signed in to approve delete requests.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'bulk-delete-requests/$requestId/approve/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      if (response.statusCode == 200 && response.data is Map) {
        return int.tryParse(
              response.data['deleted_count']?.toString() ?? '0',
            ) ??
            0;
      }
      _lastErrorMessage = 'Could not approve this delete request.';
      return null;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not approve this delete request.';
      return null;
    } catch (_) {
      _lastErrorMessage = 'Could not approve this delete request.';
      return null;
    }
  }

  Future<bool> denyBulkDeleteRequest(String requestId) async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to deny delete requests.';
      return false;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'bulk-delete-requests/$requestId/deny/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        ),
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Could not deny this delete request.';
      return false;
    } catch (_) {
      _lastErrorMessage = 'Could not deny this delete request.';
      return false;
    }
  }

  Future<bool> recoverPrimaryDevice({
    required String email,
    required String password,
    required String emailCode,
    required String recoveryCode,
  }) async {
    try {
      _lastErrorMessage = null;
      final loginIdentifier = email.trim();
      await _updateAuthHeader();
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _dio.post(
        'auth/recover-primary-device/',
        data: {
          'email': loginIdentifier,
          'username': loginIdentifier,
          'password': password,
          'email_code': emailCode.trim(),
          'recovery_code': _normalizeRecoveryCode(recoveryCode),
          'device_id': deviceId,
          'device_label': deviceLabel,
          'device_kind': _deviceKind(),
        },
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      if (data['success'] == true) {
        await _applyAuthenticatedResponse(
          data,
          password: password,
          enableSyncByDefault: true,
        );
        return true;
      }
      return false;
    } on DioException catch (e) {
      _lastErrorMessage = _extractServerError(e.response?.data) ??
          'Primary-device recovery failed.';
      return false;
    } catch (_) {
      _lastErrorMessage = 'Primary-device recovery failed.';
      return false;
    }
  }

  Future<int?> revokeOtherDeviceSessions() async {
    await _updateAuthHeader();
    _lastErrorMessage = null;

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in to manage devices.';
      return null;
    }

    try {
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'device-sessions/revoke-others/',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
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

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      return false;
    }

    try {
      final deviceId = await getOrCreateDeviceId();
      final deviceLabel = await _buildDeviceLabel();
      final response = await _requestWithRetry(
        (accessToken) => _dio.post(
          'device-sessions/heartbeat/',
          data: {'device_id': deviceId, 'device_label': deviceLabel},
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
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

    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    if (token == null || token.isEmpty) {
      _lastErrorMessage = 'You need to be signed in.';
      return false;
    }

    return heartbeatSession();
  }

  Future<void> logout({bool notifyServer = true}) async {
    final currentVaultUser = await _secureStorage.read(
      SecureStorageService.currentUserKey,
    );

    if (notifyServer) {
      try {
        await _updateAuthHeader();
        final token = await _secureStorage.read(
          SecureStorageService.accessTokenKey,
        );
        if (token != null && token.isNotEmpty) {
          final deviceId = await getOrCreateDeviceId();
          final deviceLabel = await _buildDeviceLabel();
          await _dio.post(
            'device-sessions/logout-current/',
            data: {'device_id': deviceId, 'device_label': deviceLabel},
            options: Options(headers: {'Authorization': 'Bearer $token'}),
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

    // Detach the push listeners with the session. Left attached, they kept
    // handling messages for the account that just signed out.
    try {
      await PushMessagingService().dispose();
    } catch (e) {
      debugPrint('Push teardown on logout failed: $e');
    }

    _encryptionKey = null;
    OTPService().clearCachedUserId();
    _dio.options.headers.remove('Authorization');
  }

  Future<bool> isLoggedIn() async {
    final token = await _secureStorage.read(
      SecureStorageService.accessTokenKey,
    );
    return token != null && token.isNotEmpty;
  }

  Future<String?> getCurrentUser() async {
    return _secureStorage.read(SecureStorageService.currentUserKey);
  }
}
