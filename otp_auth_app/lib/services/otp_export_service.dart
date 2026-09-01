import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/otp_account.dart';
import 'encryption_service.dart';
import 'sync_service.dart';

/// Getting every account out at once.
///
/// Until now the only way out was the per-account QR screen: forty-four
/// accounts meant forty-four scans. For an app where the user may hold the only
/// copy of their seeds, that is the difference between a bad day and losing
/// their second factor for every service they have.
///
/// Two formats, because they answer different questions:
///
/// * **Encrypted** -- a backup. Passphrase-derived through the same PBKDF2 cost
///   as the vault key and sealed with the authenticated cipher. Safe to keep in
///   cloud storage or on a drive.
/// * **otpauth URIs** -- portability. Every other authenticator reads these,
///   which is exactly why the file is plaintext seeds and has to be treated as
///   such. The caller has to ask for it explicitly.
enum OtpExportFormat { encrypted, plainOtpAuthUris }

class OtpExportResult {
  const OtpExportResult({
    required this.filePath,
    required this.accountCount,
    required this.format,
  });

  final String filePath;
  final int accountCount;
  final OtpExportFormat format;

  bool get isPlaintext => format == OtpExportFormat.plainOtpAuthUris;
}

class OtpExportService {
  static final OtpExportService _instance = OtpExportService._internal();
  factory OtpExportService() => _instance;
  OtpExportService._internal();

  final SyncService _syncService = SyncService();

  static const String exportContext = 'otp-vault-export';
  static const int exportFormatVersion = 1;

  String? _lastErrorMessage;
  String? get lastErrorMessage => _lastErrorMessage;

  /// `otpauth://totp/Issuer:label?secret=...&issuer=...`
  ///
  /// Everything user-supplied is percent-encoded: an account label with a slash
  /// or an ampersand in it would otherwise produce a URI that silently imports
  /// as something else.
  String buildOtpAuthUri({
    required String secret,
    required String service,
    String? issuer,
    String? accountLabel,
  }) {
    final resolvedIssuer = (issuer == null || issuer.trim().isEmpty)
        ? service.trim()
        : issuer.trim();
    final resolvedLabel = (accountLabel == null || accountLabel.trim().isEmpty)
        ? service.trim()
        : accountLabel.trim();

    final label = resolvedIssuer.isEmpty
        ? Uri.encodeComponent(resolvedLabel)
        : '${Uri.encodeComponent(resolvedIssuer)}:'
            '${Uri.encodeComponent(resolvedLabel)}';

    final query = <String>[
      'secret=${Uri.encodeQueryComponent(secret.replaceAll(RegExp(r'\s+'), ''))}',
      if (resolvedIssuer.isNotEmpty)
        'issuer=${Uri.encodeQueryComponent(resolvedIssuer)}',
      'algorithm=SHA1',
      'digits=6',
      'period=30',
    ];

    return 'otpauth://totp/$label?${query.join('&')}';
  }

  /// Every account on this device, with its secret in the clear.
  ///
  /// Reads local storage, which does not depend on the sync key, so an export
  /// works even when cloud sync is broken -- which is when it is needed most.
  Future<List<Map<String, String>>> _collectAccounts() async {
    final box = await _syncService.getUserBox();
    final vaultIdentity = await _syncService.getCurrentVaultIdentity();
    final accounts = <Map<String, String>>[];

    for (final OTPAccount account in box.values) {
      String secret;
      try {
        secret = account.getSecret(vaultIdentity);
      } catch (e) {
        debugPrint('Export skipped ${account.id}: $e');
        continue;
      }
      if (secret.trim().isEmpty) continue;

      accounts.add({
        'id': account.id,
        'service': account.service,
        'secret': secret,
        'issuer': account.issuer ?? '',
        'account_label': account.accountLabel ?? '',
        'created_at': account.createdAt.toIso8601String(),
      });
    }
    return accounts;
  }

  Future<int> accountCount() async => (await _collectAccounts()).length;

  /// Write an export to [directory], returning where it landed.
  ///
  /// [passphrase] is required for [OtpExportFormat.encrypted] and ignored
  /// otherwise.
  Future<OtpExportResult?> export({
    required Directory directory,
    required OtpExportFormat format,
    String? passphrase,
  }) async {
    _lastErrorMessage = null;

    final accounts = await _collectAccounts();
    if (accounts.isEmpty) {
      _lastErrorMessage = 'There are no accounts on this device to export.';
      return null;
    }

    if (format == OtpExportFormat.encrypted &&
        (passphrase == null || passphrase.trim().length < 8)) {
      _lastErrorMessage =
          'Choose a passphrase of at least 8 characters. You will need it to '
          'restore this file, and it cannot be recovered.';
      return null;
    }

    try {
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;

      final File file;
      if (format == OtpExportFormat.encrypted) {
        file = File('${directory.path}/beatzlock_export_$stamp.bl');
        await file.writeAsString(
          _buildEncryptedExport(accounts, passphrase!),
          flush: true,
        );
      } else {
        file = File('${directory.path}/beatzlock_otpauth_$stamp.txt');
        await file.writeAsString(
          _buildPlainExport(accounts),
          flush: true,
        );
      }

      return OtpExportResult(
        filePath: file.path,
        accountCount: accounts.length,
        format: format,
      );
    } catch (e) {
      debugPrint('Export failed: $e');
      _lastErrorMessage = 'Could not write the export file: $e';
      return null;
    }
  }

  String _buildEncryptedExport(
    List<Map<String, String>> accounts,
    String passphrase,
  ) {
    final salt = EncryptionService.generateKeyringSalt();
    final key = EncryptionService.deriveKeyFromPassword(
      passphrase,
      'beatzlock_export|$salt',
    );

    // The header is deliberately readable: a backup nobody can identify years
    // later is not much of a backup. It carries no secret -- the salt and the
    // iteration count are what a correct KDF publishes.
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'beatzlock-otp-export',
      'version': exportFormatVersion,
      'created_at': DateTime.now().toIso8601String(),
      'account_count': accounts.length,
      'kdf': 'pbkdf2-sha256',
      'kdf_iterations': EncryptionService.passwordKdfIterations,
      'salt': salt,
      'payload': EncryptionService.encryptSensitiveSyncPayload(
        jsonEncode(accounts),
        key,
        context: exportContext,
      ),
    });
  }

  String _buildPlainExport(List<Map<String, String>> accounts) {
    final lines = <String>[
      '# BeatzLock export - ${accounts.length} accounts',
      '# Generated ${DateTime.now().toIso8601String()}',
      '#',
      '# THESE ARE YOUR 2FA SECRETS IN PLAIN TEXT.',
      '# Anyone holding this file can generate your codes. Import it where you',
      '# need it, then delete it -- do not leave it in Downloads or a synced',
      '# folder.',
      '',
    ];

    for (final account in accounts) {
      lines.add(
        buildOtpAuthUri(
          secret: account['secret'] ?? '',
          service: account['service'] ?? '',
          issuer: account['issuer'],
          accountLabel: account['account_label'],
        ),
      );
    }
    return '${lines.join('\n')}\n';
  }

  /// Whether [fileContents] is one of this app's encrypted exports.
  ///
  /// Checked before asking for a passphrase, so a plain otpauth file or another
  /// authenticator's export does not prompt for one it does not need.
  static bool looksLikeEncryptedExport(String fileContents) {
    final trimmed = fileContents.trimLeft();
    if (!trimmed.startsWith('{')) return false;
    try {
      final decoded = jsonDecode(fileContents);
      return decoded is Map && decoded['format'] == 'beatzlock-otp-export';
    } catch (_) {
      return false;
    }
  }

  /// Read back an encrypted export. The counterpart of the file above.
  List<Map<String, dynamic>>? decodeEncryptedExport(
    String fileContents,
    String passphrase,
  ) {
    _lastErrorMessage = null;
    try {
      final decoded = jsonDecode(fileContents);
      if (decoded is! Map || decoded['format'] != 'beatzlock-otp-export') {
        _lastErrorMessage = 'That is not a BeatzLock export file.';
        return null;
      }

      final salt = decoded['salt']?.toString() ?? '';
      final payload = decoded['payload']?.toString() ?? '';
      if (salt.isEmpty || payload.isEmpty) {
        _lastErrorMessage = 'That export file is incomplete.';
        return null;
      }

      // Honour the file's own cost, so exports keep opening if the shipped
      // iteration count is raised later.
      final iterations = int.tryParse('${decoded['kdf_iterations'] ?? 0}') ?? 0;
      final key = EncryptionService.deriveKeyFromPassword(
        passphrase,
        'beatzlock_export|$salt',
        iterations: iterations > 0
            ? iterations
            : EncryptionService.passwordKdfIterations,
      );

      final plain = EncryptionService.decryptSensitiveSyncPayload(
        payload,
        key,
        context: exportContext,
      );
      final accounts = jsonDecode(plain);
      if (accounts is! List) {
        _lastErrorMessage = 'That export file could not be read.';
        return null;
      }
      return accounts
          .whereType<Map>()
          .map((a) => Map<String, dynamic>.from(a))
          .toList();
    } on FormatException {
      _lastErrorMessage =
          'That passphrase does not open this file, or the file has been '
          'altered since it was written.';
      return null;
    } catch (e) {
      debugPrint('Export decode failed: $e');
      _lastErrorMessage = 'That export file could not be read.';
      return null;
    }
  }
}
