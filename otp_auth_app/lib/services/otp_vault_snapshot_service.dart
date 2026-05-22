import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/otp_account.dart';
import '../models/password_entry.dart';
import 'encryption_service.dart';
import 'sync_service.dart';

class OtpVaultSnapshotInfo {
  const OtpVaultSnapshotInfo({
    required this.id,
    required this.createdAt,
    required this.otpAccountCount,
    required this.passwordEntryCount,
    required this.reason,
  });

  final String id;
  final DateTime createdAt;
  final int otpAccountCount;
  final int passwordEntryCount;
  final String reason;
}

class OtpVaultSnapshotRestoreResult {
  const OtpVaultSnapshotRestoreResult({
    required this.restoredOtpCount,
    required this.restoredPasswordCount,
    required this.snapshotCreatedAt,
    required this.syncedToCloud,
  });

  final int restoredOtpCount;
  final int restoredPasswordCount;
  final DateTime snapshotCreatedAt;
  final bool syncedToCloud;
}

class OtpVaultSnapshotService {
  static const _snapshotBoxName = 'otp_vault_snapshots';
  static const _cloudDataType = 'otp_restore_points';
  static const _automaticRetentionTargetsInDays = [
    1,
    2,
    3,
    7,
    14,
    30,
    60,
    90,
    120,
    180,
  ];

  final SyncService _syncService = SyncService();

  Future<void> captureDailySnapshotIfNeeded() async {
    await _refreshFromCloudIfAvailable();
    final snapshots = await _recordsForCurrentVault();
    if (snapshots.isEmpty) {
      await captureSnapshot(reason: 'automatic_daily');
      return;
    }

    snapshots.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final latest = snapshots.first;
    final age = DateTime.now().difference(latest.createdAt);
    if (age >= const Duration(hours: 24)) {
      await captureSnapshot(reason: 'automatic_daily');
      return;
    }

    await _syncSnapshotsToCloud();
  }

  Future<void> captureSnapshot({
    String reason = 'manual',
    bool syncToCloud = true,
  }) async {
    final userBoxName = await _syncService.getCurrentUserBoxName();
    final userBox = await _syncService.getUserBox();
    final passwordBox = await _syncService.getPasswordBox();
    final snapshotBox = await _openSnapshotBox();
    final now = DateTime.now().toUtc();
    final snapshotId = now.microsecondsSinceEpoch.toString();

    final otpAccounts = userBox.values
        .map(
          (account) => {
            'id': account.id,
            'service': account.service,
            'secret': account.secret,
            'issuer': account.issuer,
            'account_label': account.accountLabel,
            'created_at': account.createdAt.toIso8601String(),
          },
        )
        .toList(growable: false);

    final passwordEntries = passwordBox.values
        .map(
          (entry) => {
            'id': entry.id,
            'title': entry.title,
            'username': entry.username,
            'encrypted_password': entry.encryptedPassword,
            'encrypted_note': entry.encryptedNote,
            'server_ip': entry.serverIP,
            'created_at': entry.createdAt.toIso8601String(),
            'updated_at': entry.updatedAt.toIso8601String(),
          },
        )
        .toList(growable: false);

    await snapshotBox.put(snapshotId, {
      'id': snapshotId,
      'box_name': userBoxName,
      'created_at': now.toIso8601String(),
      'account_count': otpAccounts.length,
      'password_count': passwordEntries.length,
      'reason': reason,
      'accounts': otpAccounts,
      'password_entries': passwordEntries,
    });

    await _pruneSnapshots(userBoxName);
    if (syncToCloud) {
      await _syncSnapshotsToCloud();
    }
  }

  Future<List<OtpVaultSnapshotInfo>> getSnapshots() async {
    await _refreshFromCloudIfAvailable();
    final records = await _recordsForCurrentVault();
    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await _syncSnapshotsToCloud();
    return records
        .map(
          (record) => OtpVaultSnapshotInfo(
            id: record.id,
            createdAt: record.createdAt,
            otpAccountCount: record.otpAccountCount,
            passwordEntryCount: record.passwordEntryCount,
            reason: record.reason,
          ),
        )
        .toList(growable: false);
  }

  Future<bool> deleteSnapshot(
    String snapshotId, {
    bool syncToCloud = true,
  }) async {
    await _refreshFromCloudIfAvailable();
    final snapshotBox = await _openSnapshotBox();
    final raw = snapshotBox.get(snapshotId);
    if (raw is! Map) return false;

    final record = _SnapshotRecord.fromMap(Map<dynamic, dynamic>.from(raw));
    final currentBoxName = await _syncService.getCurrentUserBoxName();
    if (record.boxName != currentBoxName) {
      return false;
    }

    await snapshotBox.delete(snapshotId);
    if (syncToCloud) {
      await _syncSnapshotsToCloud();
    }
    return true;
  }

  Future<OtpVaultSnapshotRestoreResult?> restoreSnapshot(
    String snapshotId, {
    bool syncToCloud = true,
  }) async {
    await _refreshFromCloudIfAvailable();
    final snapshotBox = await _openSnapshotBox();
    final raw = snapshotBox.get(snapshotId);
    if (raw is! Map) return null;

    final record = _SnapshotRecord.fromMap(Map<dynamic, dynamic>.from(raw));
    final currentBoxName = await _syncService.getCurrentUserBoxName();
    if (record.boxName != currentBoxName) {
      return null;
    }

    final userBox = await _syncService.getUserBox();
    final passwordBox = await _syncService.getPasswordBox();
    await userBox.clear();
    await passwordBox.clear();

    for (final account in record.accounts) {
      final createdAt =
          DateTime.tryParse(account['created_at']?.toString() ?? '') ??
              record.createdAt;
      final restored = OTPAccount(
        id: account['id']?.toString() ?? '',
        service: account['service']?.toString() ?? 'Imported Account',
        secret: account['secret']?.toString() ?? '',
        issuer: account['issuer']?.toString(),
        createdAt: createdAt,
        accountLabel: account['account_label']?.toString(),
      );
      await userBox.put(restored.id, restored);
    }

    for (final entry in record.passwordEntries) {
      final createdAt =
          DateTime.tryParse(entry['created_at']?.toString() ?? '') ??
              record.createdAt;
      final restored = PasswordEntry(
        id: entry['id']?.toString() ?? '',
        title: entry['title']?.toString() ?? 'Password',
        username: entry['username']?.toString() ?? '',
        password: entry['encrypted_password']?.toString() ?? '',
        serverIP: entry['server_ip']?.toString(),
        createdAt: createdAt,
        updatedAt: DateTime.tryParse(entry['updated_at']?.toString() ?? '') ??
            createdAt,
      );
      final encryptedNote = entry['encrypted_note']?.toString();
      restored.encryptedNote =
          encryptedNote == null || encryptedNote.trim().isEmpty
              ? null
              : encryptedNote;
      await passwordBox.put(restored.id, restored);
    }

    var syncedToCloud = false;
    if (syncToCloud && await _shouldUseCloudSnapshots()) {
      final restoredOtpIds = record.accounts
          .map((account) => account['id']?.toString() ?? '')
          .where((id) => id.trim().isNotEmpty)
          .toList(growable: false);
      final restoredPasswordIds = record.passwordEntries
          .map((entry) => entry['id']?.toString() ?? '')
          .where((id) => id.trim().isNotEmpty)
          .toList(growable: false);
      final prepared = await _syncService.clearRestoredAccountTombstones(
        restoredOtpIds,
      );
      await _syncService.clearRestoredPasswordDeletionMarkers(
        restoredPasswordIds,
      );
      if (prepared) {
        final syncedAccounts =
            await _syncService.uploadCurrentAccountsAsAuthoritative();
        final syncedPasswords =
            await _syncService.uploadCurrentPasswordsAsAuthoritative();
        syncedToCloud = syncedAccounts && syncedPasswords;
      }
    }

    return OtpVaultSnapshotRestoreResult(
      restoredOtpCount: record.accounts.length,
      restoredPasswordCount: record.passwordEntries.length,
      snapshotCreatedAt: record.createdAt,
      syncedToCloud: syncedToCloud,
    );
  }

  Future<Box<dynamic>> _openSnapshotBox() async {
    if (!Hive.isBoxOpen(_snapshotBoxName)) {
      await Hive.openBox(_snapshotBoxName);
    }
    return Hive.box(_snapshotBoxName);
  }

  Future<List<_SnapshotRecord>> _recordsForCurrentVault() async {
    final boxName = await _syncService.getCurrentUserBoxName();
    final snapshotBox = await _openSnapshotBox();
    return snapshotBox.values
        .whereType<Map>()
        .map(
          (item) => _SnapshotRecord.fromMap(Map<dynamic, dynamic>.from(item)),
        )
        .where((record) => record.boxName == boxName)
        .toList();
  }

  Future<void> _replaceRecordsForCurrentVault(
    List<_SnapshotRecord> records,
  ) async {
    final boxName = await _syncService.getCurrentUserBoxName();
    final snapshotBox = await _openSnapshotBox();
    final keysToDelete = snapshotBox.keys.where((key) {
      final raw = snapshotBox.get(key);
      if (raw is! Map) return false;
      return raw['box_name']?.toString() == boxName;
    }).toList(growable: false);

    for (final key in keysToDelete) {
      await snapshotBox.delete(key);
    }

    for (final record in records) {
      await snapshotBox.put(record.id, record.toMap());
    }
  }

  Future<void> _refreshFromCloudIfAvailable() async {
    if (!await _shouldUseCloudSnapshots()) {
      return;
    }

    final encryptionKey = await _syncService.getAvailableEncryptionKey();
    if (encryptionKey == null || encryptionKey.isEmpty) {
      return;
    }

    final remote = await _syncService.getEncryptedSyncData(_cloudDataType);
    if (remote == null) {
      return;
    }

    final encryptedContent = remote['encrypted_content']?.toString() ?? '';
    if (encryptedContent.isEmpty) {
      return;
    }

    try {
      final decrypted = EncryptionService.simpleDecrypt(
        encryptedContent,
        encryptionKey,
      );
      if (decrypted.trim().isEmpty) {
        return;
      }

      final rawList = jsonDecode(decrypted);
      if (rawList is! List) {
        return;
      }

      final records = rawList
          .whereType<Map>()
          .map((item) => _SnapshotRecord.fromMap(item))
          .toList(growable: false);
      await _replaceRecordsForCurrentVault(records);
    } catch (_) {
      // Keep the local copy if the cloud snapshot payload cannot be read.
    }
  }

  Future<void> _syncSnapshotsToCloud() async {
    if (!await _shouldUseCloudSnapshots()) {
      return;
    }

    final encryptionKey = await _syncService.getAvailableEncryptionKey();
    if (encryptionKey == null || encryptionKey.isEmpty) {
      return;
    }

    final records = await _recordsForCurrentVault();
    final payload =
        records.map((record) => record.toMap()).toList(growable: false);
    final encrypted = EncryptionService.simpleEncrypt(
      jsonEncode(payload),
      encryptionKey,
    );

    final existing = await _syncService.getEncryptedSyncData(_cloudDataType);
    final existingVersion =
        int.tryParse(existing?['version']?.toString() ?? '0') ?? 0;
    await _syncService.uploadEncryptedSyncData(
      _cloudDataType,
      encryptedContent: encrypted,
      version: existingVersion + 1,
      deletedAccounts: 'N/A',
    );
  }

  Future<bool> _shouldUseCloudSnapshots() async {
    if (!await _syncService.isLoggedIn()) {
      return false;
    }
    return _syncService.isSyncEnabled();
  }

  Future<void> _pruneSnapshots(String boxName) async {
    final snapshotBox = await _openSnapshotBox();
    final records = snapshotBox.values
        .whereType<Map>()
        .map(
          (item) => _SnapshotRecord.fromMap(Map<dynamic, dynamic>.from(item)),
        )
        .where((record) => record.boxName == boxName)
        .toList();
    if (records.isEmpty) {
      return;
    }

    final automaticRecords = records
        .where((record) => !_isManualSnapshot(record.reason))
        .toList(growable: false);
    final manualRecords = records
        .where((record) => _isManualSnapshot(record.reason))
        .toList(growable: false);

    if (automaticRecords.length <= _automaticRetentionTargetsInDays.length &&
        manualRecords.length <= 1) {
      return;
    }

    automaticRecords.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    manualRecords.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final keepIds = <String>{};
    if (automaticRecords.isNotEmpty) {
      keepIds.add(automaticRecords.first.id);
    }
    if (manualRecords.isNotEmpty) {
      keepIds.add(manualRecords.first.id);
    }
    final now = DateTime.now().toUtc();

    for (final targetDays in _automaticRetentionTargetsInDays) {
      _SnapshotRecord? bestMatch;
      var bestDistance = 1 << 30;
      for (final record in automaticRecords) {
        final ageDays = now.difference(record.createdAt).inDays;
        final distance = (ageDays - targetDays).abs();
        if (bestMatch == null || distance < bestDistance) {
          bestMatch = record;
          bestDistance = distance;
        }
      }
      if (bestMatch != null) {
        keepIds.add(bestMatch.id);
      }
    }

    for (final record in records) {
      if (keepIds.contains(record.id)) continue;
      await snapshotBox.delete(record.id);
    }
  }

  bool _isManualSnapshot(String reason) {
    final normalized = reason.trim().toLowerCase();
    return normalized == 'manual' || normalized == 'manual_on_demand';
  }
}

class _SnapshotRecord {
  const _SnapshotRecord({
    required this.id,
    required this.boxName,
    required this.createdAt,
    required this.otpAccountCount,
    required this.passwordEntryCount,
    required this.reason,
    required this.accounts,
    required this.passwordEntries,
  });

  final String id;
  final String boxName;
  final DateTime createdAt;
  final int otpAccountCount;
  final int passwordEntryCount;
  final String reason;
  final List<Map<String, dynamic>> accounts;
  final List<Map<String, dynamic>> passwordEntries;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'box_name': boxName,
      'created_at': createdAt.toIso8601String(),
      'account_count': otpAccountCount,
      'password_count': passwordEntryCount,
      'reason': reason,
      'accounts': accounts,
      'password_entries': passwordEntries,
    };
  }

  factory _SnapshotRecord.fromMap(Map<dynamic, dynamic> raw) {
    final createdAt = DateTime.tryParse(raw['created_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final rawAccounts = raw['accounts'];
    final accounts = rawAccounts is List
        ? rawAccounts
            .whereType<Map>()
            .map(
              (item) => jsonDecode(jsonEncode(item)) as Map<String, dynamic>,
            )
            .toList(growable: false)
        : const <Map<String, dynamic>>[];
    final rawPasswordEntries = raw['password_entries'];
    final passwordEntries = rawPasswordEntries is List
        ? rawPasswordEntries
            .whereType<Map>()
            .map(
              (item) => jsonDecode(jsonEncode(item)) as Map<String, dynamic>,
            )
            .toList(growable: false)
        : const <Map<String, dynamic>>[];

    return _SnapshotRecord(
      id: raw['id']?.toString() ?? '',
      boxName: raw['box_name']?.toString() ?? '',
      createdAt: createdAt.toUtc(),
      otpAccountCount: int.tryParse(raw['account_count']?.toString() ?? '') ??
          accounts.length,
      passwordEntryCount:
          int.tryParse(raw['password_count']?.toString() ?? '') ??
              passwordEntries.length,
      reason: raw['reason']?.toString() ?? 'snapshot',
      accounts: accounts,
      passwordEntries: passwordEntries,
    );
  }
}
