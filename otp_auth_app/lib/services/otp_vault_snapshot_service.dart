import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/otp_account.dart';
import 'sync_service.dart';

class OtpVaultSnapshotInfo {
  const OtpVaultSnapshotInfo({
    required this.id,
    required this.createdAt,
    required this.accountCount,
    required this.reason,
  });

  final String id;
  final DateTime createdAt;
  final int accountCount;
  final String reason;
}

class OtpVaultSnapshotRestoreResult {
  const OtpVaultSnapshotRestoreResult({
    required this.restoredCount,
    required this.snapshotCreatedAt,
  });

  final int restoredCount;
  final DateTime snapshotCreatedAt;
}

class OtpVaultSnapshotService {
  static const _snapshotBoxName = 'otp_vault_snapshots';
  static const _retentionTargetsInDays = [1, 3, 7, 14, 30, 90, 180];

  final SyncService _syncService = SyncService();

  Future<void> captureDailySnapshotIfNeeded() async {
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
    }
  }

  Future<void> captureSnapshot({String reason = 'manual'}) async {
    final userBoxName = await _syncService.getCurrentUserBoxName();
    final userBox = await _syncService.getUserBox();
    final snapshotBox = await _openSnapshotBox();
    final now = DateTime.now().toUtc();
    final snapshotId = now.microsecondsSinceEpoch.toString();

    final accounts = userBox.values
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

    await snapshotBox.put(snapshotId, {
      'id': snapshotId,
      'box_name': userBoxName,
      'created_at': now.toIso8601String(),
      'account_count': accounts.length,
      'reason': reason,
      'accounts': accounts,
    });

    await _pruneSnapshots(userBoxName);
  }

  Future<List<OtpVaultSnapshotInfo>> getSnapshots() async {
    final records = await _recordsForCurrentVault();
    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return records
        .map(
          (record) => OtpVaultSnapshotInfo(
            id: record.id,
            createdAt: record.createdAt,
            accountCount: record.accountCount,
            reason: record.reason,
          ),
        )
        .toList(growable: false);
  }

  Future<OtpVaultSnapshotRestoreResult?> restoreSnapshot(
    String snapshotId,
  ) async {
    final snapshotBox = await _openSnapshotBox();
    final raw = snapshotBox.get(snapshotId);
    if (raw is! Map) return null;

    final record = _SnapshotRecord.fromMap(Map<dynamic, dynamic>.from(raw));
    final currentBoxName = await _syncService.getCurrentUserBoxName();
    if (record.boxName != currentBoxName) {
      return null;
    }

    await captureSnapshot(reason: 'pre_restore_backup');

    final userBox = await _syncService.getUserBox();
    await userBox.clear();

    for (final account in record.accounts) {
      final createdAt = DateTime.tryParse(
            account['created_at']?.toString() ?? '',
          ) ??
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

    return OtpVaultSnapshotRestoreResult(
      restoredCount: record.accounts.length,
      snapshotCreatedAt: record.createdAt,
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
        .map((item) => _SnapshotRecord.fromMap(Map<dynamic, dynamic>.from(item)))
        .where((record) => record.boxName == boxName)
        .toList();
  }

  Future<void> _pruneSnapshots(String boxName) async {
    final snapshotBox = await _openSnapshotBox();
    final records = snapshotBox.values
        .whereType<Map>()
        .map((item) => _SnapshotRecord.fromMap(Map<dynamic, dynamic>.from(item)))
        .where((record) => record.boxName == boxName)
        .toList();
    if (records.length <= _retentionTargetsInDays.length) {
      return;
    }

    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final keepIds = <String>{records.first.id};
    final now = DateTime.now().toUtc();

    for (final targetDays in _retentionTargetsInDays) {
      _SnapshotRecord? bestMatch;
      var bestDistance = 1 << 30;
      for (final record in records) {
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
}

class _SnapshotRecord {
  const _SnapshotRecord({
    required this.id,
    required this.boxName,
    required this.createdAt,
    required this.accountCount,
    required this.reason,
    required this.accounts,
  });

  final String id;
  final String boxName;
  final DateTime createdAt;
  final int accountCount;
  final String reason;
  final List<Map<String, dynamic>> accounts;

  factory _SnapshotRecord.fromMap(Map<dynamic, dynamic> raw) {
    final createdAt = DateTime.tryParse(
          raw['created_at']?.toString() ?? '',
        ) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final rawAccounts = raw['accounts'];
    final accounts = rawAccounts is List
        ? rawAccounts
            .whereType<Map>()
            .map((item) => jsonDecode(jsonEncode(item)) as Map<String, dynamic>)
            .toList(growable: false)
        : const <Map<String, dynamic>>[];

    return _SnapshotRecord(
      id: raw['id']?.toString() ?? '',
      boxName: raw['box_name']?.toString() ?? '',
      createdAt: createdAt.toUtc(),
      accountCount:
          int.tryParse(raw['account_count']?.toString() ?? '') ?? accounts.length,
      reason: raw['reason']?.toString() ?? 'snapshot',
      accounts: accounts,
    );
  }
}
