import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_config.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../models/app_update_info.dart';
import '../services/app_rating_service.dart';
import '../models/otp_account.dart';
import '../services/app_update_service.dart';
import '../services/import_file_picker_service.dart';
import '../services/sync_service.dart';
import '../services/app_lock_service.dart';
import '../services/otp_import_service.dart';
import '../services/otp_vault_snapshot_service.dart';
import '../services/background_passwordless_poll_service.dart';
import '../services/push_messaging_service.dart';
import '../services/profile_service.dart';
import '../services/server_lockdown_service.dart';
import '../services/secure_storage_service.dart';
import 'add_account_screen.dart';
import 'device_sessions_screen.dart';
import 'legal_document_screen.dart';
import 'login_screen.dart';
import 'notifications_screen.dart';
import 'passwords_screen.dart';
import 'passwordless_requests_screen.dart';
import 'profile_screen.dart';
import 'recover_primary_device_screen.dart';
import 'secure_self_text_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SyncService _syncService = SyncService();
  final AppLockService _appLockService = AppLockService();
  final AppUpdateService _appUpdateService = AppUpdateService();
  final AppRatingService _appRatingService = AppRatingService();
  final ProfileService _profileService = ProfileService();
  final ServerLockdownService _serverLockdownService = ServerLockdownService();
  final OtpVaultSnapshotService _otpVaultSnapshotService =
      OtpVaultSnapshotService();

  bool _isSyncing = false;
  bool _isCheckingForUpdates = false;
  bool _isInstallingUpdate = false;
  bool _isDownloadingBackupCodes = false;
  bool _isLoadingBackupCodeStatus = false;
  bool _isLoadingVaultRestorePoints = false;
  bool _cancelVaultRestorePointsLoadRequested = false;
  bool _syncEnabled = false;
  bool _syncLockedOnThisDevice = false;
  bool _serverLockdownEnabled = false;
  bool _updateProgressDialogVisible = false;
  String _appVersionLabel = '...';
  String? _profilePhotoUrl;
  Timer? _syncPrefTimer;
  final ValueNotifier<AppDownloadProgress?> _updateProgressNotifier =
      ValueNotifier<AppDownloadProgress?>(null);
  AppUpdateInfo? _updateInfo;
  Map<String, dynamic>? _backupCodeStatus;

  @override
  void initState() {
    super.initState();
    _loadSyncPreference();
    _loadServerLockdownPreference();
    _loadAppVersion();
    _refreshUpdateInfo();
    _loadBackupCodeStatus();
    _loadProfilePhoto();
    _syncPrefTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!await _syncService.isLoggedIn()) {
        return;
      }
      await _syncService.refreshSyncPreferenceFromServer();
      final enabled = await _syncService.isSyncEnabled();
      final syncLocked = await _syncService.isSyncLockedOnCurrentDevice();
      if (mounted &&
          (enabled != _syncEnabled || syncLocked != _syncLockedOnThisDevice)) {
        setState(() {
          _syncEnabled = enabled;
          _syncLockedOnThisDevice = syncLocked;
        });
      }
    });
  }

  @override
  void dispose() {
    _syncPrefTimer?.cancel();
    _updateProgressNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadSyncPreference() async {
    final enabled = await _syncService.isSyncEnabled();
    final syncLocked = await _syncService.isSyncLockedOnCurrentDevice();
    if (mounted) {
      setState(() {
        _syncEnabled = enabled;
        _syncLockedOnThisDevice = syncLocked;
      });
    }
  }

  Future<void> _loadAppVersion() async {
    final label = await _appUpdateService.getCurrentVersionLabel();
    if (mounted) {
      setState(() {
        _appVersionLabel = label;
      });
    }
  }

  Future<void> _loadServerLockdownPreference() async {
    final enabled = await _serverLockdownService.isEnabled();
    if (mounted) {
      setState(() {
        _serverLockdownEnabled = enabled;
      });
    }
  }

  Future<void> _loadBackupCodeStatus() async {
    if (_isLoadingBackupCodeStatus) return;
    if (!await _syncService.isLoggedIn()) {
      if (mounted) {
        setState(() {
          _backupCodeStatus = null;
          _isLoadingBackupCodeStatus = false;
        });
      }
      return;
    }

    setState(() {
      _isLoadingBackupCodeStatus = true;
    });

    final status = await _syncService.getBackupCodeStatus();
    if (!mounted) return;

    setState(() {
      _backupCodeStatus = status;
      _isLoadingBackupCodeStatus = false;
    });
  }

  Future<void> _loadProfilePhoto() async {
    if (!await _syncService.isLoggedIn()) {
      if (mounted) setState(() => _profilePhotoUrl = null);
      return;
    }

    final profile = await _profileService.getProfile();
    if (!mounted) return;

    setState(() {
      _profilePhotoUrl = profile?['profile']?['profile_photo']?.toString();
    });
  }

  Future<void> _refreshUpdateInfo() async {
    if (_isCheckingForUpdates || _appUpdateService.currentPlatform.isEmpty) {
      return;
    }

    setState(() {
      _isCheckingForUpdates = true;
    });

    try {
      final info = await _appUpdateService.checkForUpdate();
      if (mounted) {
        setState(() {
          _updateInfo = info;
          if (_appVersionLabel == '...' && info != null) {
            _appVersionLabel = info.currentLabel;
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingForUpdates = false;
        });
      }
    }
  }

  Future<void> _handleUpdateTap() async {
    if (!await _requireServerConnection('check for app updates')) {
      return;
    }

    await _refreshUpdateInfo();
    if (!mounted) return;

    final info = _updateInfo;
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _appUpdateService.lastErrorMessage ??
                'Could not check for updates right now.',
          ),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }

    if (!info.updateAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('You are already on the latest version.'),
          backgroundColor: const Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }

    final shouldUpdate = await _showUpdateDetailsDialog(info);
    if (shouldUpdate != true || !mounted) return;

    if (_appUpdateService.canDownloadUpdateInApp) {
      setState(() => _isInstallingUpdate = true);
      _updateProgressNotifier.value = null;
      unawaited(_showUpdateProgressDialog(info));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final result = await _appUpdateService.installUpdate(
        info,
        onReceiveProgress: (progress) {
          _updateProgressNotifier.value = progress;
        },
      );
      if (!mounted) return;

      _dismissUpdateProgressDialog();
      setState(() => _isInstallingUpdate = false);

      if (result.started) {
        if (result.requiresAppExit) {
          final shouldOpenInstaller = await _showInstallingUpdateDialog();
          if (!mounted) return;
          if (shouldOpenInstaller != true) {
            _appUpdateService.clearPreparedUpdate();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                  'Installer launch cancelled. Tap update again when you are ready.',
                ),
                backgroundColor: Colors.orange,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            );
            return;
          }
          try {
            await _appUpdateService.launchPreparedUpdateAndExit();
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Could not start the update after closing: $e'),
                backgroundColor: Colors.red,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            );
          }
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            action: _isAndroidUpdateDownload
                ? SnackBarAction(
                    label: 'Open Downloads',
                    textColor: Colors.white,
                    onPressed: () {
                      unawaited(_openAndroidDownloadsFolder());
                    },
                  )
                : null,
          ),
        );
        return;
      }

      if (result.wasCancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
        return;
      }

      final opened = await _appUpdateService.openUpdate(info);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            opened
                ? '${result.message} Opening the download page instead.'
                : result.message,
          ),
          backgroundColor: opened ? Colors.orange : Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }

    final opened = await _appUpdateService.openUpdate(info);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          opened
              ? 'Opening download for ${info.latestLabel}'
              : 'Could not open the update download link.',
        ),
        backgroundColor: opened ? _accent : Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  String _updateSubtitle() {
    if (_appUpdateService.currentPlatform.isEmpty) {
      return 'Updates are not available for this platform';
    }

    if (_serverLockdownEnabled) {
      return 'Server Lockdown is on. Update checks are blocked.';
    }

    if (_isInstallingUpdate) {
      return _isAndroidUpdateDownload
          ? 'Downloading the APK to Downloads...'
          : 'Downloading the update...';
    }

    if (_isCheckingForUpdates) {
      return 'Checking for updates...';
    }

    final info = _updateInfo;
    if (info == null) {
      return _appUpdateService.lastErrorMessage ?? 'Check for a newer version';
    }

    if (info.updateAvailable && info.forceUpdate) {
      return 'Required: ${info.currentLabel} to ${info.latestLabel}';
    }

    if (info.updateAvailable) {
      return 'Optional: ${info.currentLabel} to ${info.latestLabel}';
    }

    return 'You are using the latest version';
  }

  Future<void> _openAndroidDownloadsFolder() async {
    final opened = await _appUpdateService.openAndroidDownloadsFolder();
    if (!mounted || opened) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _appUpdateService.lastErrorMessage ??
              'Could not open the Downloads folder.',
        ),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Duration _snackDuration(String message) {
    return Duration(seconds: message.length >= 80 ? 5 : 3);
  }

  void _showSettingsSnackBar({
    required String message,
    required Color backgroundColor,
  }) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        duration: _snackDuration(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<bool> _requireServerConnection(String featureSummary) async {
    if (!_serverLockdownEnabled) {
      return true;
    }

    if (!mounted) return false;
    _showSettingsSnackBar(
      message: _serverLockdownService.blockedMessageFor(featureSummary),
      backgroundColor: Colors.orange,
    );
    return false;
  }

  Future<void> _setServerLockdownEnabled(bool enabled) async {
    if (enabled == _serverLockdownEnabled) {
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Text(
          enabled ? 'Turn on Server Lockdown?' : 'Turn off Server Lockdown?',
          style: TextStyle(color: _textPrimary),
        ),
        content: Text(
          enabled
              ? 'This will 100% cut BeatzLock from talking to the internet or server. No sign-in, sync, passwordless, notifications, app updates, profile, ratings, or legal pages will work until you turn it off. Your local vault stays available offline.'
              : 'This will let BeatzLock talk to the internet and server again for sign-in, sync, passwordless, notifications, updates, and other online features.',
          style: TextStyle(color: _textSecondary, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: enabled ? Colors.red : _accent,
              foregroundColor: Colors.white,
            ),
            child: Text(enabled ? 'Turn On' : 'Turn Off'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final unlocked = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !unlocked) {
      return;
    }

    if (enabled) {
      await PushMessagingService().prepareForServerLockdown();
    }

    await _serverLockdownService.setEnabled(enabled);
    await BackgroundPasswordlessPollService().syncRegistration(
      enabled: !enabled,
    );
    await PushMessagingService().applyServerLockdownState(enabled: enabled);

    if (!mounted) return;
    setState(() {
      _serverLockdownEnabled = enabled;
      if (enabled) {
        _updateInfo = null;
      }
    });

    if (!enabled) {
      unawaited(_refreshUpdateInfo());
    }

    _showSettingsSnackBar(
      message: enabled
          ? 'Server Lockdown is on. BeatzLock is now fully offline from the server.'
          : 'Server Lockdown is off. Online features can connect again.',
      backgroundColor: enabled ? Colors.orange : const Color(0xFF10B981),
    );
  }

  bool get _isAndroidUpdateDownload =>
      _appUpdateService.currentPlatform == 'android';

  String get _updateDialogMessage {
    if (_appUpdateService.canSelfUpdate) {
      return 'BeatzLock can download this desktop update now. When the download finishes, BeatzLock will close and open the normal Windows installer or Linux package installer. After the update finishes, click once to reopen BeatzLock.';
    }
    if (_appUpdateService.canDownloadUpdateInApp && _isAndroidUpdateDownload) {
      return 'BeatzLock can download the APK to your Downloads folder from settings. Open the saved APK from Downloads to install it.';
    }
    return 'The download page will open so you can install the update.';
  }

  String get _updateActionLabel {
    if (_appUpdateService.canSelfUpdate) {
      return 'Download update';
    }
    if (_appUpdateService.canDownloadUpdateInApp && _isAndroidUpdateDownload) {
      return 'Download APK';
    }
    return 'Open download';
  }

  String _updateProgressTitle(AppUpdateInfo info) {
    return 'Downloading ${info.latestLabel}';
  }

  String get _updateProgressDescription {
    if (_isAndroidUpdateDownload) {
      return 'Downloading the APK to your Downloads folder. The rate shown is the average transfer speed. Open it from Downloads after the transfer finishes to install the update.';
    }
    return 'Downloading the update. The rate shown is the average transfer speed. When it finishes, BeatzLock will close and open the normal Windows installer or Linux package installer. After the update finishes, click once to reopen BeatzLock.';
  }

  void _dismissUpdateProgressDialog() {
    if (!_updateProgressDialogVisible) {
      return;
    }

    _updateProgressDialogVisible = false;
    Navigator.of(context, rootNavigator: true).pop();
  }

  String _backupCodeStatusSubtitle() {
    if (_isLoadingBackupCodeStatus) {
      return 'Checking recovery code status...';
    }

    final status = _backupCodeStatus;
    if (status == null || status['has_codes'] != true) {
      return 'No active recovery codes yet';
    }

    final remaining = status['remaining_codes'] ?? 0;
    final total = status['total_codes'] ?? 3;
    final lastUsedAt = status['last_used_at'] as String?;
    final lastUsedLabel = lastUsedAt == null
        ? 'Never used'
        : 'Last used ${_formatStatusDate(lastUsedAt)}';

    return '$remaining of $total codes remaining • $lastUsedLabel';
  }

  Widget? _backupCodeStatusTrailing() {
    if (_isLoadingBackupCodeStatus) {
      return SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
      );
    }

    final status = _backupCodeStatus;
    if (status == null || status['has_codes'] != true) {
      return null;
    }

    final remaining = status['remaining_codes'] ?? 0;
    return _versionBadge('$remaining left');
  }

  String _formatStatusDate(String isoDate) {
    final parsed = DateTime.tryParse(isoDate)?.toLocal();
    if (parsed == null) return 'recently';

    final month = parsed.month.toString().padLeft(2, '0');
    final day = parsed.day.toString().padLeft(2, '0');
    final hour = parsed.hour.toString().padLeft(2, '0');
    final minute = parsed.minute.toString().padLeft(2, '0');
    return '${parsed.year}-$month-$day $hour:$minute';
  }

  String _formatSnapshotDate(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }

  Future<void> _showOtpRestorePoints() async {
    if (_isLoadingVaultRestorePoints) return;

    setState(() {
      _isLoadingVaultRestorePoints = true;
      _cancelVaultRestorePointsLoadRequested = false;
    });

    unawaited(_showVaultRestorePointsLoadingDialog());

    try {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted || _cancelVaultRestorePointsLoadRequested) return;
      await _otpVaultSnapshotService.captureDailySnapshotIfNeeded();
      if (!mounted || _cancelVaultRestorePointsLoadRequested) return;
      final snapshots = await _otpVaultSnapshotService.getSnapshots();
      if (!mounted || _cancelVaultRestorePointsLoadRequested) return;

      final signedIn = await _syncService.isLoggedIn();
      if (!mounted || _cancelVaultRestorePointsLoadRequested) return;
      final currentSession =
          signedIn ? await _syncService.getCurrentDeviceSession() : null;
      if (!mounted || _cancelVaultRestorePointsLoadRequested) return;
      final isPrimaryDevice = !signedIn || currentSession?.isPrimary == true;

      _dismissVaultRestorePointsLoadingDialog();

      if (snapshots.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('No vault restore points are available yet.'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
        return;
      }

      final visibleSnapshots = List<OtpVaultSnapshotInfo>.from(snapshots);

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            backgroundColor: _cardColor,
            title: Text(
              'Vault Restore Points',
              style: TextStyle(color: _textPrimary),
            ),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      signedIn
                          ? 'BeatzLock keeps 10 encrypted automatic vault restore points across roughly 24 hours, 1 week, 1 month, 3 months, and up to 6 months, plus your latest manual restore point.'
                          : 'BeatzLock keeps 10 local automatic vault restore points across roughly 24 hours, 1 week, 1 month, 3 months, and up to 6 months, plus your latest manual restore point.',
                      style: TextStyle(
                        color: _textSecondary,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      signedIn
                          ? (isPrimaryDevice
                              ? 'This is your primary device, so you can restore or delete any restore point here.'
                              : 'You can view restore points on this device, but only your primary device can restore or delete them.')
                          : 'Offline vault restore points can be restored on this device.',
                      style: TextStyle(
                        color: _textSecondary,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (visibleSnapshots.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: _isDark ? Colors.white10 : Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _dividerColor),
                        ),
                        child: Text(
                          'No vault restore points are left on this device.',
                          style: TextStyle(
                            color: _textSecondary,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                    for (final snapshot in visibleSnapshots) ...[
                      Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: _isDark ? Colors.white10 : Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _dividerColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _formatSnapshotDate(snapshot.createdAt),
                              style: TextStyle(
                                color: _textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${snapshot.otpAccountCount} OTP account${snapshot.otpAccountCount == 1 ? '' : 's'}'
                              ' • ${snapshot.passwordEntryCount} password${snapshot.passwordEntryCount == 1 ? '' : 's'}',
                              style: TextStyle(
                                color: _textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.end,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: (!signedIn || isPrimaryDevice)
                                        ? () async {
                                            Navigator.pop(dialogContext);
                                            await _restoreOtpSnapshot(snapshot);
                                          }
                                        : null,
                                    icon: const Icon(Icons.restore_rounded),
                                    label: const Text('Restore'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: (!signedIn || isPrimaryDevice)
                                        ? () async {
                                            final deleted =
                                                await _deleteOtpSnapshot(
                                              snapshot,
                                            );
                                            if (!deleted ||
                                                !dialogContext.mounted) {
                                              return;
                                            }
                                            setDialogState(() {
                                              visibleSnapshots.removeWhere(
                                                (item) =>
                                                    item.id == snapshot.id,
                                              );
                                            });
                                          }
                                        : null,
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                    ),
                                    label: const Text('Delete'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton.icon(
                onPressed: (!signedIn || isPrimaryDevice)
                    ? () async {
                        Navigator.pop(dialogContext);
                        await _createManualVaultRestorePoint();
                      }
                    : null,
                icon: const Icon(Icons.add_circle_outline_rounded),
                label: const Text('Create restore point'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      _dismissVaultRestorePointsLoadingDialog();
      if (_cancelVaultRestorePointsLoadRequested) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not load vault restore points right now.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingVaultRestorePoints = false;
          _cancelVaultRestorePointsLoadRequested = false;
        });
      }
    }
  }

  void _cancelVaultRestorePointsLoading() {
    if (!mounted || _cancelVaultRestorePointsLoadRequested) return;
    _cancelVaultRestorePointsLoadRequested = true;
    _dismissVaultRestorePointsLoadingDialog();
  }

  void _dismissVaultRestorePointsLoadingDialog() {
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).popUntil((route) {
      return route is! PopupRoute ||
          route.settings.name != 'vault-restore-loading';
    });
  }

  Future<void> _showVaultRestorePointsLoadingDialog() {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      routeSettings: const RouteSettings(name: 'vault-restore-loading'),
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          backgroundColor: _cardColor,
          content: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: _accent,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Loading vault restore points...',
                      style: TextStyle(
                        color: _textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Checking local snapshots and syncing recent restore points from the server.',
                      style: TextStyle(
                        color: _textSecondary,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: _cancelVaultRestorePointsLoading,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createManualVaultRestorePoint() async {
    final authenticated = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !authenticated) return;

    if (await _syncService.isLoggedIn()) {
      final currentSession = await _syncService.getCurrentDeviceSession();
      if (!mounted) return;
      if (currentSession == null || !currentSession.isPrimary) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Only your primary device can create synced manual restore points.',
            ),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
        return;
      }
    }

    await _otpVaultSnapshotService.captureSnapshot(reason: 'manual_on_demand');
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Created a manual vault restore point for your current OTP accounts and passwords.',
        ),
        backgroundColor: const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _restoreOtpSnapshot(OtpVaultSnapshotInfo snapshot) async {
    final authenticated = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !authenticated) return;

    if (await _syncService.isLoggedIn()) {
      final currentSession = await _syncService.getCurrentDeviceSession();
      if (!mounted) return;
      if (currentSession == null || !currentSession.isPrimary) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Only your primary device can restore synced vault restore points.',
            ),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
        return;
      }
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Text(
          'Restore Vault Snapshot',
          style: TextStyle(color: _textPrimary),
        ),
        content: Text(
          'Restore your vault to ${_formatSnapshotDate(snapshot.createdAt)}? '
          'This will replace the current OTP accounts and password entries on this device.',
          style: TextStyle(color: _textSecondary, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Restore'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final result = await _otpVaultSnapshotService.restoreSnapshot(snapshot.id);
    if (!mounted) return;
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not restore that vault snapshot.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }

    final syncEnabled =
        await _syncService.isLoggedIn() && await _syncService.isSyncEnabled();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          syncEnabled
              ? (result.syncedToCloud
                  ? 'Restored ${result.restoredOtpCount} OTP account${result.restoredOtpCount == 1 ? '' : 's'} and ${result.restoredPasswordCount} password${result.restoredPasswordCount == 1 ? '' : 's'} from ${_formatSnapshotDate(result.snapshotCreatedAt)} and synced that restored state everywhere.'
                  : 'Restored ${result.restoredOtpCount} OTP account${result.restoredOtpCount == 1 ? '' : 's'} and ${result.restoredPasswordCount} password${result.restoredPasswordCount == 1 ? '' : 's'} from ${_formatSnapshotDate(result.snapshotCreatedAt)} on this device, but the server copy could not be updated.')
              : 'Restored ${result.restoredOtpCount} OTP account${result.restoredOtpCount == 1 ? '' : 's'} and ${result.restoredPasswordCount} password${result.restoredPasswordCount == 1 ? '' : 's'} from ${_formatSnapshotDate(result.snapshotCreatedAt)}.',
        ),
        backgroundColor: (!syncEnabled || result.syncedToCloud)
            ? const Color(0xFF10B981)
            : Colors.orange,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<bool> _deleteOtpSnapshot(OtpVaultSnapshotInfo snapshot) async {
    final authenticated = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !authenticated) return false;

    if (await _syncService.isLoggedIn()) {
      final currentSession = await _syncService.getCurrentDeviceSession();
      if (!mounted) return false;
      if (currentSession == null || !currentSession.isPrimary) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Only your primary device can delete synced vault restore points.',
            ),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
        return false;
      }
    }

    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Text(
          'Delete Restore Point',
          style: TextStyle(color: _textPrimary),
        ),
        content: Text(
          'Delete the vault restore point from ${_formatSnapshotDate(snapshot.createdAt)}? This removes it from this device and the encrypted server copy.',
          style: TextStyle(color: _textSecondary, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return false;

    final deleted = await _otpVaultSnapshotService.deleteSnapshot(snapshot.id);
    if (!mounted) return false;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          deleted
              ? 'Deleted the vault restore point from ${_formatSnapshotDate(snapshot.createdAt)}.'
              : 'Could not delete that vault restore point.',
        ),
        backgroundColor: deleted ? Colors.red : Colors.orange,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
    return deleted;
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _accentSecondary => Theme.of(context).colorScheme.secondary;
  Color get _bgColor => Theme.of(context).scaffoldBackgroundColor;
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white38 : Colors.grey.shade500;
  Color get _dividerColor =>
      _isDark ? Colors.white.withValues(alpha: 0.06) : Colors.grey.shade100;

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context);

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _profileCard(authProvider),
          const SizedBox(height: 24),
          _sectionLabel('Appearance'),
          _settingsCard([
            _themeModeTile(themeProvider: themeProvider),
            _dividerLine(),
            _tappableTile(
              icon: Icons.palette_rounded,
              label: 'Accent Color',
              sub: 'Customise theme colour',
              trailing: _colorDot(themeProvider.accentColor),
              onTap: () => _showColorPicker(themeProvider),
            ),
          ]),
          const SizedBox(height: 20),
          _sectionLabel('Security & Backup'),
          _settingsCard([
            _tappableTile(
              icon: Icons.picture_as_pdf_rounded,
              label: 'Download Backup Codes',
              sub: authProvider.isAuthenticated
                  ? 'Save a PDF with your recovery codes'
                  : 'Sign in to generate account recovery codes',
              trailing: _isDownloadingBackupCodes
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _accent,
                      ),
                    )
                  : null,
              onTap: _isDownloadingBackupCodes ? null : _downloadBackupCodes,
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.key_rounded,
              label: 'Recovery Code Status',
              sub: authProvider.isAuthenticated
                  ? _backupCodeStatusSubtitle()
                  : 'Sign in to view recovery code status',
              trailing: _backupCodeStatusTrailing(),
              onTap: authProvider.isAuthenticated
                  ? _loadBackupCodeStatus
                  : () => _requireSignedIn(
                        'Recovery codes are available after you sign in.',
                      ),
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.restore_rounded,
              label: 'Vault Restore Points',
              sub:
                  'Restore your OTP accounts and passwords from recent automatic snapshots',
              trailing: _isLoadingVaultRestorePoints
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _accent,
                      ),
                    )
                  : null,
              onTap:
                  _isLoadingVaultRestorePoints ? null : _showOtpRestorePoints,
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.download_rounded,
              label: 'Import OTP Accounts',
              sub:
                  'Import CSV, otpauth links, or Google Authenticator QR exports',
              onTap: _showImportAccountsDialog,
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.upload_file_rounded,
              label: 'Import Passwords',
              sub:
                  'Import CSV or JSON password exports into your encrypted password vault only',
              onTap: () async {
                if (!await _requireSignedIn(
                  'Password import is available after you sign in.',
                )) {
                  return;
                }
                if (!context.mounted) return;
                final authenticated =
                    await _appLockService.authenticateToUnlock(context);
                if (!context.mounted || !authenticated) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const PasswordsScreen(openImportOnStart: true),
                  ),
                );
              },
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.password_rounded,
              label: 'Passwords',
              sub: authProvider.isAuthenticated
                  ? 'Save encrypted passwords and private notes to your own account vault'
                  : 'Sign in to use the encrypted passwords and notes vault',
              onTap: () async {
                if (!await _requireSignedIn(
                  'The password vault is available after you sign in.',
                )) {
                  return;
                }
                if (!context.mounted) return;
                final authenticated =
                    await _appLockService.authenticateToUnlock(context);
                if (!context.mounted || !authenticated) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PasswordsScreen()),
                );
              },
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.chat_bubble_rounded,
              label: 'Secure Self Text',
              sub: authProvider.isAuthenticated
                  ? 'Send live encrypted texts to yourself across your own devices'
                  : 'Sign in to use your encrypted self-text feed',
              onTap: () async {
                if (!await _requireSignedIn(
                  'Secure self text is available after you sign in.',
                )) {
                  return;
                }
                if (!context.mounted) return;
                final authenticated =
                    await _appLockService.authenticateToUnlock(context);
                if (!context.mounted || !authenticated) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const SecureSelfTextScreen(),
                  ),
                );
              },
            ),
            _dividerLine(),

            _tappableTile(
              icon: Icons.lock_outline_rounded,
              label: 'App Lock',
              sub:
                  'Always on. BeatzLock now requires device security or an app PIN every time you reopen it.',
              trailing: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'Required',
                  style: TextStyle(
                    color: Color(0xFF10B981),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),

            _dividerLine(),
            _tappableTile(
              icon: Icons.pin,
              label: 'Change App PIN',
              sub: 'Set or replace your BeatzLock unlock PIN',
              onTap: _changeAppPin,
            ),

            _tappableTile(
              icon: Icons.sync_rounded,
              label: 'Sync Now',
              sub: _serverLockdownEnabled
                  ? 'Server Lockdown is on. All cloud communication is blocked.'
                  : !authProvider.isAuthenticated
                      ? 'Sign in to sync across devices'
                      : _syncLockedOnThisDevice
                          ? 'Unlock sync on this device first'
                          : _syncEnabled
                              ? 'Manually sync with cloud'
                              : 'Cloud sync is disabled',
              trailing: _isSyncing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _accent,
                      ),
                    )
                  : (_syncEnabled && !_syncLockedOnThisDevice
                      ? null
                      : const Icon(
                          Icons.lock_outline,
                          size: 16,
                          color: Colors.grey,
                        )),
              onTap: !authProvider.isAuthenticated
                  ? () async {
                      if (!await _requireServerConnection(
                        'sign in or sync with the cloud',
                      )) {
                        return;
                      }
                      await _openLoginForSync();
                    }
                  : _serverLockdownEnabled
                      ? () => unawaited(
                            _requireServerConnection('sync with the cloud'),
                          )
                      : (_syncLockedOnThisDevice
                          ? _unlockSyncOnThisDevice
                          : _syncNow),
            ),
            if (authProvider.isAuthenticated && _syncLockedOnThisDevice) ...[
              _dividerLine(),
              _tappableTile(
                icon: Icons.lock_open_rounded,
                label: 'Unlock Sync On This Device',
                sub:
                    'Enter your account password once to restore encrypted cloud sync here',
                onTap: _unlockSyncOnThisDevice,
              ),
            ],
            _dividerLine(),

            // Sync toggle
            _switchTile(
              icon: Icons.cloud_sync_rounded,
              label: 'Sync to Cloud',
              sub: _syncLockedOnThisDevice
                  ? 'Unlock this device first to resume cloud sync'
                  : _syncEnabled
                      ? 'Accounts sync automatically'
                      : 'Sync disabled - local only',
              value: authProvider.isAuthenticated &&
                  _syncEnabled &&
                  !_syncLockedOnThisDevice,
              onChanged: (val) async {
                if (_serverLockdownEnabled) {
                  await _requireServerConnection(
                    'change cloud sync while Server Lockdown is on',
                  );
                  return;
                }
                if (!authProvider.isAuthenticated) {
                  if (val) {
                    await _openLoginForSync();
                  }
                  return;
                }
                if (_syncLockedOnThisDevice) {
                  if (val) {
                    await _unlockSyncOnThisDevice();
                  }
                  return;
                }
                await _syncService.setSyncEnabled(val);
                if (!context.mounted) return;
                setState(() => _syncEnabled = val);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      val
                          ? 'Cloud sync enabled on all devices'
                          : 'Cloud sync disabled on all devices',
                    ),
                    backgroundColor:
                        val ? const Color(0xFF10B981) : Colors.orange,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                );
              },
            ),
            _dividerLine(),
            _switchTile(
              icon: Icons.cloud_off_rounded,
              label: 'Server Lockdown',
              sub: _serverLockdownEnabled
                  ? '100% blocking BeatzLock from talking to the internet or server'
                  : 'Off by default. Cut every server and internet connection from BeatzLock when you need full offline isolation.',
              value: _serverLockdownEnabled,
              onChanged: (val) async {
                await _setServerLockdownEnabled(val);
              },
            ),
          ]),
          const SizedBox(height: 20),
          _sectionLabel('Account'),
          _settingsCard([
            _tappableTile(
              icon: Icons.person_outline_rounded,
              label: authProvider.isAuthenticated ? 'Profile' : 'Sign in',
              sub: authProvider.isAuthenticated
                  ? 'Edit profile information'
                  : 'Enable automatic sync and account tools',
              onTap: authProvider.isAuthenticated
                  ? () async {
                      if (!await _requireServerConnection(
                        'open your online profile',
                      )) {
                        return;
                      }
                      if (!context.mounted) return;
                      await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ProfileScreen()),
                      );
                      if (!mounted) return;
                      await _loadProfilePhoto();
                    }
                  : _openLoginForSync,
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.lock_outline_rounded,
              label: 'Change Password',
              sub: 'Update your password',
              onTap: () async {
                if (await _requireSignedIn(
                  'Password changes are available after you sign in.',
                )) {
                  _showChangePasswordDialog();
                }
              },
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.devices_rounded,
              label: 'Active Devices',
              sub: 'See where your account is signed in',
              onTap: () async {
                if (!await _requireSignedIn(
                  'Device sessions are available after you sign in.',
                )) {
                  return;
                }
                if (!context.mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DeviceSessionsScreen(),
                  ),
                );
              },
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.workspace_premium_rounded,
              label: 'Make This Device Primary',
              sub:
                  'Use app PIN plus password, email code, and recovery code to move primary protection here',
              onTap: () async {
                if (!await _requireSignedIn(
                  'Primary-device recovery is available after you sign in.',
                )) {
                  return;
                }
                if (!context.mounted) return;
                final authenticated =
                    await _appLockService.authenticateToUnlock(context);
                if (!context.mounted || !authenticated) return;
                final changed = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const RecoverPrimaryDeviceScreen(),
                  ),
                );
                if (!context.mounted || changed != true) return;
                await _loadBackupCodeStatus();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text(
                      'This device is now your primary device.',
                    ),
                    backgroundColor: const Color(0xFF10B981),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                );
              },
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.phonelink_lock_rounded,
              label: 'Sign-in Approvals',
              sub: 'Approve passwordless sign-ins from your primary phone',
              onTap: () async {
                if (!await _requireSignedIn(
                  'Passwordless sign-in approvals are available after you sign in.',
                )) {
                  return;
                }
                if (!context.mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const PasswordlessRequestsScreen(),
                  ),
                );
              },
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.notifications_none_rounded,
              label: 'Notifications',
              sub: 'View recent security activity',
              onTap: () async {
                if (!await _requireSignedIn(
                  'Notifications are available after you sign in.',
                )) {
                  return;
                }
                if (!context.mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const NotificationsScreen(),
                  ),
                );
              },
            ),
          ]),
          const SizedBox(height: 20),
          _sectionLabel('About'),
          _settingsCard([
            if (_appUpdateService.currentPlatform.isNotEmpty) ...[
              _tappableTile(
                icon: Icons.system_update_alt_rounded,
                label: 'App Updates',
                sub: _updateSubtitle(),
                trailing: _buildUpdateTrailing(),
                onTap: _handleUpdateTap,
              ),
              _dividerLine(),
            ],
            _tappableTile(
              icon: Icons.open_in_browser_rounded,
              label: 'Manual Download',
              sub: 'Open the downloads page and choose your installer',
              onTap: _openManualDownloadPage,
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.info_outline_rounded,
              label: 'Version',
              sub: 'Current app version',
              trailing: _versionBadge(_appVersionLabel),
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.article_outlined,
              label: 'Release Notes',
              sub: 'See what changed in the current installed version',
              onTap: _showInstalledReleaseNotes,
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.language_rounded,
              label: 'Website',
              sub: 'Open example.com in your browser',
              onTap: _openCreatorWebsite,
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.code_rounded,
              label: 'GitHub',
              sub: 'View github.com/felixmokayabeatz',
              onTap: _openCreatorGithub,
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.privacy_tip_outlined,
              label: 'Privacy Policy',
              sub: 'Read our privacy policy',
              onTap: () => _openLegalDocument('privacy', 'Privacy Policy'),
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.description_outlined,
              label: 'Terms of Service',
              sub: 'Terms and conditions',
              onTap: () => _openLegalDocument('terms', 'Terms of Service'),
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.star_outline_rounded,
              label: 'Rate the App',
              sub: 'Love it? Leave a review',
              trailing: const Icon(
                Icons.star_rounded,
                color: Colors.amber,
                size: 20,
              ),
              onTap: _openRateApp,
            ),
          ]),
          const SizedBox(height: 12),
          Text.rich(
            TextSpan(
              style: TextStyle(
                color: _textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              children: [
                const TextSpan(text: 'Developed with love '),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Icon(Icons.favorite_rounded, size: 14, color: _accent),
                ),
                TextSpan(text: ' by Felix Mokaya © ${DateTime.now().year}'),
              ],
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          _sectionLabel('Danger Zone'),
          _settingsCard([
            _tappableTile(
              icon: Icons.delete_forever_rounded,
              label: 'Clear All Data',
              sub: 'Permanently delete all accounts',
              destructive: true,
              onTap: _clearAllData,
            ),
          ]),
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed:
                  authProvider.isAuthenticated ? _logout : _openLoginForSync,
              icon: Icon(
                authProvider.isAuthenticated
                    ? Icons.logout_rounded
                    : Icons.login_rounded,
              ),
              label: Text(
                authProvider.isAuthenticated
                    ? 'Sign out to offline mode'
                    : 'Sign in for sync',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: authProvider.isAuthenticated
                    ? Colors.red.shade600
                    : _accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _changeAppPin() async {
    final messenger = ScaffoldMessenger.of(context);
    final success = await _appLockService.setupAppPinFromSettings(context);
    if (!mounted) return;
    if (success) {
      if (await _syncService.isLoggedIn()) {
        final deviceLabel = await _syncService.getCurrentDeviceLabel();
        if (!context.mounted) return;
        unawaited(
          _syncService.logAppPinChangedNotification(deviceLabel: deviceLabel),
        );
      }

      messenger.showSnackBar(
        const SnackBar(
          content: Text('PIN changed successfully'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _openLegalDocument(String type, String title) async {
    if (!await _requireServerConnection('load legal documents')) {
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LegalDocumentScreen(type: type, fallbackTitle: title),
      ),
    );
  }

  Future<void> _openLoginForSync() async {
    if (!await _requireServerConnection(
      'sign in and reconnect to online tools',
    )) {
      return;
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const LoginScreen(returnToPreviousOnOffline: true),
      ),
    );
    if (!mounted) return;
    await _loadSyncPreference();
    await _loadBackupCodeStatus();
    await _loadProfilePhoto();
  }

  Future<void> _unlockSyncOnThisDevice() async {
    if (!await _requireSignedIn(
      'Unlocking sync is available after you sign in.',
    )) {
      return;
    }
    if (!mounted) return;

    final passwordController = TextEditingController();
    var isSubmitting = false;
    var attemptedUnlock = false;
    String? errorText;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          backgroundColor: _cardColor,
          title: Text(
            'Unlock Sync On This Device',
            style: TextStyle(color: _textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter your account password once to restore the encryption key for synced OTPs, passwords, and secure text on this device.',
                style: TextStyle(
                  color: _textSecondary,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                obscureText: true,
                enabled: !isSubmitting,
                decoration: InputDecoration(
                  labelText: 'Account password',
                  border: const OutlineInputBorder(),
                  errorText: errorText,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed:
                  isSubmitting ? null : () => Navigator.pop(dialogContext),
              child: const Text('Not now'),
            ),
            ElevatedButton(
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final password = passwordController.text;
                      if (password.isEmpty) {
                        setDialogState(() {
                          errorText = 'Enter your password to unlock sync.';
                        });
                        return;
                      }

                      setDialogState(() {
                        isSubmitting = true;
                        errorText = null;
                      });
                      attemptedUnlock = true;

                      final unlocked = await _syncService
                          .unlockSyncAfterPasswordless(password);
                      if (!dialogContext.mounted) return;

                      if (unlocked) {
                        Navigator.pop(dialogContext);
                        return;
                      }

                      setDialogState(() {
                        isSubmitting = false;
                        errorText = _syncService.lastErrorMessage ??
                            'Could not unlock sync on this device.';
                      });
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
              ),
              child: isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Unlock sync'),
            ),
          ],
        ),
      ),
    );

    passwordController.dispose();
    if (!mounted) return;

    await _loadSyncPreference();
    if (!mounted) return;
    if (!attemptedUnlock) {
      return;
    }
    final unlocked = !_syncLockedOnThisDevice;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          unlocked
              ? 'Sync unlocked on this device.'
              : 'Sync stayed locked on this device.',
        ),
        backgroundColor: unlocked ? const Color(0xFF10B981) : Colors.orange,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<bool> _requireSignedIn(String message) async {
    if (!await _requireServerConnection('reach signed-in server features')) {
      return false;
    }

    if (!mounted) return false;
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    if (authProvider.isAuthenticated && await _syncService.isLoggedIn()) {
      return true;
    }

    if (!mounted) return false;
    final signIn = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Text('Sign in required', style: TextStyle(color: _textPrimary)),
        content: Text(
          '$message\n\nYou can keep using local codes offline. Sign in when you want automatic cross-platform sync.',
          style: TextStyle(color: _textSecondary, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );

    if (signIn == true && mounted) {
      await _openLoginForSync();
    }
    return false;
  }

  Future<void> _openRateApp() async {
    if (!await _requireServerConnection('view or send app ratings')) {
      return;
    }

    if (!await _requireSignedIn('Only signed-in users can send app reviews.')) {
      return;
    }

    final currentPlatform = _appUpdateService.currentPlatform.isEmpty
        ? 'unknown'
        : _appUpdateService.currentPlatform;
    final reviewerKey = await _ratingReviewerKey();
    AppRating? existingRating;
    String savedDisplayName = '';
    AppRatingSummary? platformSummary;
    try {
      final lookup = await _appRatingService.fetchMyRating(
        reviewerKey: reviewerKey,
        platform: currentPlatform,
      );
      existingRating = lookup.rating;
      savedDisplayName = lookup.displayName;
    } catch (_) {
      existingRating = null;
      savedDisplayName = '';
    }
    try {
      platformSummary = await _appRatingService.fetchPlatformSummary(
        platform: currentPlatform,
      );
    } catch (_) {
      platformSummary = null;
    }

    if (!mounted) return;

    final commentController = TextEditingController();
    final suggestionController = TextEditingController();
    final displayNameController = TextEditingController();
    displayNameController.text =
        (existingRating?.displayName == 'Anonymous user'
            ? ''
            : (existingRating?.displayName ?? savedDisplayName));
    commentController.text = existingRating?.comment ?? '';
    suggestionController.text = existingRating?.suggestion ?? '';

    var selectedStars = (existingRating?.stars ?? 5).clamp(1, 5).toInt();
    var isSubmitting = false;
    var isDeleting = false;
    var isEditing = existingRating == null;
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          backgroundColor: _cardColor,
          title: Text('Rate BeatzLock', style: TextStyle(color: _textPrimary)),
          content: SizedBox(
            width: 430,
            child: SingleChildScrollView(
              child: existingRating != null && !isEditing
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (platformSummary != null) ...[
                          _buildPlatformSummaryCard(
                            platformLabel: existingRating.platformDisplay,
                            summary: platformSummary,
                          ),
                          const SizedBox(height: 16),
                        ],
                        _buildExistingRatingPreview(existingRating),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          existingRating == null
                              ? 'Rate this platform build and leave a comment or suggestion for the public BeatzLock ratings page.'
                              : 'Edit or delete your rating for this platform only. Your other platform reviews stay on the same account record.',
                          style: TextStyle(color: _textSecondary, fontSize: 13),
                        ),
                        if (platformSummary != null) ...[
                          const SizedBox(height: 14),
                          _buildPlatformSummaryCard(
                            platformLabel: existingRating?.platformDisplay ??
                                _platformLabelFromSlug(currentPlatform),
                            summary: platformSummary,
                          ),
                        ],
                        const SizedBox(height: 16),
                        TextField(
                          controller: displayNameController,
                          enabled: !isSubmitting,
                          maxLength: 80,
                          decoration: const InputDecoration(
                            labelText: 'Display name',
                            hintText: 'Name to show on the public ratings page',
                            helperText:
                                'Leave this blank and we will show Anonymous user.',
                            border: OutlineInputBorder(),
                            counterText: '',
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(5, (index) {
                            final star = index + 1;
                            final selected = star <= selectedStars;
                            return IconButton(
                              tooltip: '$star star${star == 1 ? '' : 's'}',
                              onPressed: isSubmitting
                                  ? null
                                  : () => setDialogState(() {
                                        selectedStars = star;
                                        errorText = null;
                                      }),
                              icon: Icon(
                                selected
                                    ? Icons.star_rounded
                                    : Icons.star_outline_rounded,
                                color: Colors.amber,
                                size: 34,
                              ),
                            );
                          }),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: commentController,
                          enabled: !isSubmitting,
                          minLines: 3,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            labelText: 'Comment',
                            hintText: 'What do you like or dislike?',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: suggestionController,
                          enabled: !isSubmitting,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Suggestion',
                            hintText: 'What should improve next?',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        if (errorText != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            errorText!,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSubmitting || isDeleting
                  ? null
                  : () async {
                      final uri = Uri.parse(AppConfig.rateAppUrl);
                      final opened = await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                      if (!opened && dialogContext.mounted) {
                        setDialogState(() {
                          errorText = 'Could not open the ratings page.';
                        });
                      }
                    },
              child: const Text('View Ratings'),
            ),
            TextButton(
              onPressed: (isSubmitting || isDeleting)
                  ? null
                  : () => Navigator.pop(dialogContext),
              child: Text('Cancel', style: TextStyle(color: _textSecondary)),
            ),
            if (existingRating != null)
              TextButton(
                onPressed: (isSubmitting || isDeleting)
                    ? null
                    : () async {
                        final confirmed = await showDialog<bool>(
                          context: dialogContext,
                          builder: (confirmContext) => AlertDialog(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            backgroundColor: _cardColor,
                            title: Text(
                              'Delete review?',
                              style: TextStyle(color: _textPrimary),
                            ),
                            content: Text(
                              'This removes only your ${existingRating!.platformDisplay} review. Reviews from your other platforms stay intact.',
                              style: TextStyle(
                                color: _textSecondary,
                                fontSize: 13,
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(confirmContext, false),
                                child: const Text('Cancel'),
                              ),
                              ElevatedButton(
                                onPressed: () =>
                                    Navigator.pop(confirmContext, true),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );

                        if (confirmed != true) {
                          return;
                        }

                        setDialogState(() {
                          isDeleting = true;
                          errorText = null;
                        });

                        try {
                          final deleted = await _appRatingService.deleteRating(
                            reviewerKey: reviewerKey,
                            platform: currentPlatform,
                          );
                          if (!dialogContext.mounted) return;
                          Navigator.pop(dialogContext);
                          if (!mounted) return;

                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                deleted
                                    ? 'Your review for this platform was deleted.'
                                    : 'No review was found for this platform.',
                              ),
                              backgroundColor:
                                  deleted ? Colors.orange : _accent,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          );
                        } catch (_) {
                          if (!dialogContext.mounted) return;
                          setDialogState(() {
                            isDeleting = false;
                            errorText =
                                'Could not delete right now. Please try again.';
                          });
                        }
                      },
                child: isDeleting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.red,
                        ),
                      )
                    : const Text('Delete', style: TextStyle(color: Colors.red)),
              ),
            if (existingRating != null && !isEditing)
              ElevatedButton(
                onPressed: (isSubmitting || isDeleting)
                    ? null
                    : () => setDialogState(() {
                          isEditing = true;
                          errorText = null;
                        }),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Edit'),
              )
            else
              ElevatedButton(
                onPressed: (isSubmitting || isDeleting)
                    ? null
                    : () async {
                        final comment = commentController.text.trim();
                        final suggestion = suggestionController.text.trim();
                        final displayName = displayNameController.text.trim();
                        if (comment.isEmpty && suggestion.isEmpty) {
                          setDialogState(() {
                            errorText =
                                'Add a comment or suggestion before submitting.';
                          });
                          return;
                        }

                        setDialogState(() {
                          isSubmitting = true;
                          errorText = null;
                        });

                        try {
                          final packageInfo = await PackageInfo.fromPlatform();
                          final deviceLabel =
                              await _syncService.getCurrentDeviceLabel();
                          final storage = SecureStorageService();
                          await _appRatingService.submitRating(
                            reviewerKey: reviewerKey,
                            platform: currentPlatform,
                            displayName: displayName,
                            stars: selectedStars,
                            comment: comment,
                            suggestion: suggestion,
                            appVersion: packageInfo.version,
                            buildNumber: packageInfo.buildNumber,
                            deviceLabel: deviceLabel,
                            accountUserId: await storage.read(
                                  SecureStorageService.userIdKey,
                                ) ??
                                '',
                            accountEmail: await storage.read(
                                  SecureStorageService.userEmailKey,
                                ) ??
                                '',
                            accountUsername: await storage.read(
                                  SecureStorageService.currentUserKey,
                                ) ??
                                '',
                          );

                          if (!dialogContext.mounted) return;
                          Navigator.pop(dialogContext);
                          if (!mounted) return;

                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                existingRating == null
                                    ? 'Thanks for the review!'
                                    : 'Your review was updated.',
                              ),
                              backgroundColor: const Color(0xFF10B981),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          );
                        } catch (_) {
                          if (!dialogContext.mounted) return;
                          setDialogState(() {
                            isSubmitting = false;
                            errorText =
                                'Could not submit right now. Please try again.';
                          });
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                ),
                child: isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(existingRating == null ? 'Submit' : 'Save Edit'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openManualDownloadPage() async {
    if (!await _requireServerConnection('open manual downloads')) {
      return;
    }

    final confirmed = await _confirmExternalBrowserLaunch(
      title: 'Open Browser?',
      message:
          'This will open the BeatzLock manual download page in your browser so you can choose and download an installer.',
      continueLabel: 'Open Browser',
    );
    if (confirmed != true || !mounted) return;

    final opened = await _appUpdateService.openManualDownloadPage(_updateInfo);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          opened
              ? 'Opening the manual download page.'
              : 'Could not open the manual download page.',
        ),
        backgroundColor: opened ? _accent : Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _openCreatorWebsite() {
    return _openExternalLink(
      title: 'Open Website?',
      message: 'This will open example.com in your browser.',
      successMessage: 'Opening FelixMokayabeatz website.',
      failureMessage: 'Could not open the website.',
      url: AppConfig.creatorWebsiteUrl,
    );
  }

  Future<void> _openCreatorGithub() {
    return _openExternalLink(
      title: 'Open GitHub?',
      message:
          'This will open the FelixMokayabeatz GitHub profile in your browser.',
      successMessage: 'Opening GitHub profile.',
      failureMessage: 'Could not open the GitHub profile.',
      url: AppConfig.creatorGithubUrl,
    );
  }

  Future<void> _openExternalLink({
    required String title,
    required String message,
    required String successMessage,
    required String failureMessage,
    required String url,
  }) async {
    if (!await _requireServerConnection('open websites and internet pages')) {
      return;
    }

    final confirmed = await _confirmExternalBrowserLaunch(
      title: title,
      message: message,
      continueLabel: 'Open Browser',
    );
    if (confirmed != true || !mounted) return;

    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(opened ? successMessage : failureMessage),
        backgroundColor: opened ? _accent : Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<bool?> _confirmExternalBrowserLaunch({
    required String title,
    required String message,
    required String continueLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        backgroundColor: _cardColor,
        title: Text(title, style: TextStyle(color: _textPrimary)),
        content: Text(
          message,
          style: TextStyle(color: _textSecondary, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
            ),
            child: Text(continueLabel),
          ),
        ],
      ),
    );
  }

  Future<String> _ratingReviewerKey() async {
    final storage = SecureStorageService();
    final rawUser = (await storage.read(SecureStorageService.userIdKey)) ??
        (await storage.read(SecureStorageService.userEmailKey)) ??
        (await storage.read(SecureStorageService.currentUserKey));
    if (rawUser == null || rawUser.trim().isEmpty) {
      throw StateError('Signed-in user required to rate the app.');
    }
    final normalized = rawUser.trim().toLowerCase();
    final digest = sha256.convert(
      utf8.encode('beatzlock_rating_v1|$normalized'),
    );
    return digest.toString();
  }

  Widget _buildExistingRatingPreview(AppRating rating) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'You already rated this platform. You can edit or delete just this platform review here, while your other platform reviews stay on the same account record.',
          style: TextStyle(color: _textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 16),
        Center(child: _starStrip(rating.stars, size: 30)),
        const SizedBox(height: 14),
        _ratingMetaLine('Name', rating.displayName),
        _ratingMetaLine('Platform', rating.platformDisplay),
        _ratingMetaLine('Original date', _formatRatingDate(rating.createdAt)),
        _ratingMetaLine('Last edited', _formatRatingDate(rating.updatedAt)),
        if (rating.adminReply.isNotEmpty) ...[
          const SizedBox(height: 14),
          _buildReplyStatusCard(rating),
        ],
        if (rating.comment.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            'Comment',
            style: TextStyle(
              color: _textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            rating.comment,
            style: TextStyle(color: _textPrimary, fontSize: 13, height: 1.5),
          ),
        ],
        if (rating.suggestion.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            'Suggestion',
            style: TextStyle(
              color: _textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            rating.suggestion,
            style: TextStyle(color: _textPrimary, fontSize: 13, height: 1.5),
          ),
        ],
      ],
    );
  }

  Widget _buildReplyStatusCard(AppRating rating) {
    final repliedOn = rating.adminRepliedAt != null
        ? 'Replied on ${_formatRatingDate(rating.adminRepliedAt)}'
        : 'Reply available for this platform';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16A34A).withValues(alpha: _isDark ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(
            0xFF16A34A,
          ).withValues(alpha: _isDark ? 0.34 : 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: const Color(0xFF22C55E),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'BeatzLock replied',
                style: TextStyle(
                  color: _textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            repliedOn,
            style: TextStyle(
              color: _textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            rating.adminReply,
            style: TextStyle(color: _textPrimary, fontSize: 13, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _ratingMetaLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(color: _textSecondary, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: _textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformSummaryCard({
    required String platformLabel,
    required AppRatingSummary summary,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _accent.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(Icons.insights_rounded, color: _accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$platformLabel average: ${summary.average.toStringAsFixed(1)} / 5 from ${summary.count} review${summary.count == 1 ? '' : 's'}',
              style: TextStyle(
                color: _textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _platformLabelFromSlug(String platform) {
    switch (platform) {
      case 'android':
        return 'Android (APK)';
      case 'windows':
        return 'Windows (EXE)';
      case 'linux':
        return 'Linux';
      case 'macos':
        return 'macOS';
      case 'ios':
        return 'iOS';
      default:
        return 'Unknown';
    }
  }

  Widget _starStrip(int stars, {double size = 20}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (index) {
        return Icon(
          index < stars ? Icons.star_rounded : Icons.star_outline_rounded,
          color: Colors.amber,
          size: size,
        );
      }),
    );
  }

  String _formatRatingDate(DateTime? value) {
    if (value == null) return 'Unavailable';
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }

  Future<void> _showImportAccountsDialog() async {
    List<OTPImportEntry> selectedEntries = const [];
    bool isImporting = false;
    bool isPickingFile = false;
    String? selectedFileName;
    String? errorText;
    final filePicker = ImportFilePickerService();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          backgroundColor: _cardColor,
          title: Text(
            'Import OTP Accounts',
            style: TextStyle(color: _textPrimary),
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Scan a Google Authenticator transfer QR, or choose a CSV, JSON, TXT, or otpauth export file.',
                    style: TextStyle(color: _textSecondary, fontSize: 13),
                  ),
                  if (Platform.isAndroid || Platform.isIOS) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: isImporting
                            ? null
                            : () async {
                                Navigator.pop(dialogContext);
                                final imported = await Navigator.push<bool>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const AddAccountScreen(
                                      startScanning: true,
                                    ),
                                  ),
                                );
                                if (imported == true && mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: const Text(
                                        'Success. Account added.',
                                      ),
                                      backgroundColor: const Color(0xFF10B981),
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                  );
                                }
                              },
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: const Text('Scan transfer QR'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (filePicker.canPickOtpImportFile)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: isImporting || isPickingFile
                            ? null
                            : () async {
                                setDialogState(() {
                                  isPickingFile = true;
                                  errorText = null;
                                });

                                try {
                                  final file =
                                      await filePicker.pickOtpImportFile();
                                  if (!dialogContext.mounted) return;

                                  if (file == null) {
                                    setDialogState(() => isPickingFile = false);
                                    return;
                                  }

                                  final entries = OTPImportService().parse(
                                    file.content,
                                    preserveDuplicates: true,
                                  );
                                  setDialogState(() {
                                    selectedEntries = entries;
                                    selectedFileName = file.fileName;
                                    isPickingFile = false;
                                    errorText = entries.isEmpty
                                        ? 'No valid OTP accounts were found in ${file.fileName}.'
                                        : null;
                                  });
                                } catch (_) {
                                  if (!dialogContext.mounted) return;
                                  setDialogState(() {
                                    selectedEntries = const [];
                                    selectedFileName = null;
                                    isPickingFile = false;
                                    errorText =
                                        'Could not read that import file.';
                                  });
                                }
                              },
                        icon: isPickingFile
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: _accent,
                                ),
                              )
                            : const Icon(Icons.upload_file_rounded),
                        label: Text(
                          selectedFileName == null
                              ? 'Choose Import File'
                              : 'Change Import File',
                        ),
                      ),
                    )
                  else
                    Text(
                      'File import is available on Android and Windows right now.',
                      style: TextStyle(
                        color: Colors.orange.shade700,
                        fontSize: 12,
                      ),
                    ),
                  if (selectedFileName != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _isDark ? Colors.white10 : Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _dividerColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            selectedFileName!,
                            style: TextStyle(
                              color: _textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${selectedEntries.length} account${selectedEntries.length == 1 ? '' : 's'} ready to import',
                            style: TextStyle(
                              color: _textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (errorText != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      errorText!,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed:
                  isImporting ? null : () => Navigator.pop(dialogContext),
              child: Text('Cancel', style: TextStyle(color: _textSecondary)),
            ),
            ElevatedButton(
              onPressed: isImporting || selectedEntries.isEmpty
                  ? null
                  : () async {
                      setDialogState(() {
                        isImporting = true;
                        errorText = null;
                      });

                      final result = await _importOtpEntries(
                        selectedEntries,
                        sourceLabel: selectedFileName,
                      );
                      if (!dialogContext.mounted) return;
                      Navigator.pop(dialogContext);
                      if (!mounted) return;

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(result.message),
                          backgroundColor: result.importedCount > 0
                              ? const Color(0xFF10B981)
                              : Colors.orange,
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      );
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
              ),
              child: isImporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Import'),
            ),
          ],
        ),
      ),
    );
  }

  Future<_ImportResult> _importOtpEntries(
    List<OTPImportEntry> entries, {
    String? sourceLabel,
  }) async {
    final storage = SecureStorageService();
    final userId = await storage.read(SecureStorageService.currentUserKey) ??
        await storage.read(SecureStorageService.localVaultUserKey) ??
        'default_user';
    final userBox = await _syncService.getUserBox();
    final isSignedIn = await _syncService.isLoggedIn();
    final existingKeys = userBox.values
        .map(
          (account) => _otpIdentityKey(account.service, account.accountLabel),
        )
        .toSet();
    var importedCount = 0;
    var skippedCount = 0;

    for (final entry in entries) {
      final identityKey = _otpIdentityKey(entry.service, entry.accountLabel);
      if (existingKeys.contains(identityKey)) {
        skippedCount++;
        continue;
      }

      final account = OTPAccount(
        id: '${DateTime.now().millisecondsSinceEpoch}_$importedCount',
        service: entry.service,
        secret: entry.secret,
        issuer: entry.issuer,
        accountLabel: entry.accountLabel,
        createdAt: DateTime.now(),
        userId: userId,
      );
      await userBox.put(account.id, account);
      importedCount++;
    }

    if (isSignedIn && importedCount > 0) {
      try {
        await _syncService.logAccountsImportedNotification(
          importedCount: importedCount,
          skippedCount: skippedCount,
          sourceLabel: sourceLabel,
        );
      } catch (_) {}
    }

    if (importedCount > 0 && isSignedIn && await _syncService.isSyncEnabled()) {
      await _syncService.syncAccounts();
    }

    final message = importedCount == 0
        ? 'No new accounts imported.'
        : 'Imported $importedCount account${importedCount == 1 ? '' : 's'}${skippedCount > 0 ? ', skipped $skippedCount duplicate${skippedCount == 1 ? '' : 's'}' : ''}.';
    return _ImportResult(importedCount, skippedCount, message);
  }

  String _otpIdentityKey(String service, String? accountLabel) {
    return [
      service.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' '),
      (accountLabel ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' '),
    ].join('|');
  }

  Future<void> _downloadBackupCodes() async {
    if (!await _requireSignedIn(
      'Backup-code PDFs are tied to your synced account and primary device.',
    )) {
      return;
    }

    if (!mounted) return;
    final authenticated = await _appLockService.authenticateToUnlock(context);
    if (!mounted) return;
    if (!authenticated) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Unlock with device security or your app PIN first.',
          ),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }

    setState(() => _isDownloadingBackupCodes = true);
    final savedPath = await _syncService.downloadBackupCodesPdf(
      preferDarkTheme: _isDark,
    );
    if (!mounted) return;
    setState(() => _isDownloadingBackupCodes = false);

    if (savedPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _syncService.lastErrorMessage ??
                'Could not download backup codes right now.',
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }

    await _loadBackupCodeStatus();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Row(
          children: [
            Icon(Icons.picture_as_pdf_rounded, color: _accent),
            const SizedBox(width: 10),
            Text('Backup Codes Saved', style: TextStyle(color: _textPrimary)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your BeatzLock backup codes PDF was downloaded successfully.',
              style: TextStyle(color: _textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Text(
              savedPath,
              style: TextStyle(
                color: _textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close', style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
  }

  // ========== EXISTING METHODS (unchanged from your original) ==========

  // --- Clear all data (with local/everywhere choice) ------------------------
  void _clearAllData() async {
    // Step 1: ask local-only vs everywhere
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Row(
          children: [
            const Icon(Icons.warning_rounded, color: Colors.red, size: 24),
            const SizedBox(width: 10),
            Text(
              'Clear All Data',
              style: TextStyle(color: _textPrimary, fontSize: 17),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will permanently delete ALL your OTP accounts.',
              style: TextStyle(color: _textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _deleteOptionTile(
              icon: Icons.phone_android_rounded,
              title: 'This device only',
              subtitle:
                  'Other devices keep their copies. You can re-sync from cloud later.',
              color: Colors.orange,
              onTap: () => Navigator.pop(context, 'local'),
            ),
            const SizedBox(height: 8),
            _deleteOptionTile(
              icon: Icons.cloud_off_rounded,
              title: 'Everywhere (all devices + cloud)',
              subtitle: 'Permanent. Requires OTP verification.',
              color: Colors.red,
              onTap: () => Navigator.pop(context, 'everywhere'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: Text('Cancel', style: TextStyle(color: _textSecondary)),
          ),
        ],
      ),
    );

    if (choice == null || choice == 'cancel') return;

    if (choice == 'local') {
      if (!mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          backgroundColor: _cardColor,
          title: Text(
            'Delete local copy?',
            style: TextStyle(color: _textPrimary),
          ),
          content: Text(
            'All accounts will be removed from this device. You can re-sync from cloud later.',
            style: TextStyle(color: _textSecondary, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete Local'),
            ),
          ],
        ),
      );
      if (confirm != true) return;

      if (!mounted) return;
      final unlocked = await _appLockService.authenticateToUnlock(context);
      if (!mounted || !unlocked) return;

      await _otpVaultSnapshotService.captureSnapshot(reason: 'pre_delete_all');
      await _syncService.deleteAllLocalOnly();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: const Text(
              'All accounts removed from this device. Sync to restore.',
            ),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      return;
    }

    // -- "Everywhere" path: require OTP --------------------------------------
    if (!await _syncService.isLoggedIn()) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          backgroundColor: _cardColor,
          title: Text(
            'Sign in required',
            style: TextStyle(color: _textPrimary),
          ),
          content: Text(
            'Cloud deletion is not possible while you are using BeatzLock offline. You can delete the local copy on this device, or sign in first to delete synced accounts everywhere.',
            style: TextStyle(color: _textSecondary, fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Got it'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _openLoginForSync();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
              ),
              child: const Text('Sign in'),
            ),
          ],
        ),
      );
      return;
    }

    final username = await SecureStorageService().read(
          SecureStorageService.currentUserKey,
        ) ??
        '';

    final otpSent = await _syncService.sendDeleteOtp(username);
    if (!otpSent) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Failed to send verification code. Check your connection.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    var otpCode = '';
    if (!mounted) return;
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          backgroundColor: _cardColor,
          title: Text(
            'Confirm Deletion',
            style: TextStyle(color: _textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.email_outlined, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(
                'A 6-digit verification code was sent to your email. Enter it to permanently delete ALL accounts everywhere.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(
                  color: _isDark ? Colors.white12 : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                ),
                child: TextField(
                  onChanged: (value) {
                    setDialogState(() => otpCode = value);
                  },
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 24,
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                  ),
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    hintText: '000000',
                    hintStyle: TextStyle(fontSize: 18, letterSpacing: 2),
                    border: InputBorder.none,
                    counterText: '',
                    contentPadding: EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
              },
              child: Text('Cancel', style: TextStyle(color: _textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final code = otpCode.trim();
                if (code.length != 6) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(
                      content: Text('Enter the 6-digit code'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  return;
                }
                final ok = await _syncService.verifyDeleteOtp(username, code);
                if (!dialogContext.mounted) return;
                Navigator.pop(dialogContext, ok);
              },
              child: const Text('Delete Everything'),
            ),
          ],
        ),
      ),
    );

    if (verified != true) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid code – deletion cancelled'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    await _otpVaultSnapshotService.captureSnapshot(reason: 'pre_delete_all');
    final ok = await _syncService.deleteAllEverywhere();
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All accounts deleted everywhere'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to delete from cloud – try again'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _deleteOptionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: color.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: color.withValues(alpha: 0.5),
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  // --- Change password dialog (unchanged from original) ---------------------
  void _showChangePasswordDialog() {
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    final otpCodeController = TextEditingController();
    bool obscureCurrent = true;
    bool obscureNew = true;
    bool obscureConfirm = true;
    bool show2FA = false;
    double passwordStrength = 0.0;
    String passwordStrengthText = '';
    Color passwordStrengthColor = Colors.grey;
    double passwordLength = 16;

    void checkStrength(StateSetter setState) {
      final pw = newPasswordController.text;
      if (pw.isEmpty) {
        setState(() {
          passwordStrength = 0;
          passwordStrengthText = '';
        });
        return;
      }
      int score = 0;
      if (pw.length >= 12) {
        score += 25;
      } else if (pw.length >= 8) {
        score += 15;
      }
      if (pw.contains(RegExp(r'[0-9]'))) score += 25;
      if (pw.contains(RegExp(r'[A-Z]'))) score += 25;
      if (pw.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>_+=\[\]\\;/-]'))) {
        score += 25;
      }
      setState(() {
        passwordStrength = score / 100;
        if (score < 50) {
          passwordStrengthText = 'Weak';
          passwordStrengthColor = Colors.red;
        } else if (score < 75) {
          passwordStrengthText = 'Medium';
          passwordStrengthColor = Colors.orange;
        } else {
          passwordStrengthText = 'Strong';
          passwordStrengthColor = Colors.green;
        }
      });
    }

    String generatePassword(int length) {
      const up = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
      const lo = 'abcdefghijkmnopqrstuvwxyz';
      const nu = '23456789';
      const sy = r'!@#$%^&*()_+-=[]{}|;:,.<>?';
      final random = DateTime.now().millisecondsSinceEpoch;
      String pw = up[random % up.length] +
          lo[(random + 1) % lo.length] +
          nu[(random + 2) % nu.length] +
          sy[(random + 3) % sy.length];
      final all = up + lo + nu + sy;
      for (int i = pw.length; i < length; i++) {
        pw += all[(random + i) % all.length];
      }
      final chars = pw.split('');
      for (int i = chars.length - 1; i > 0; i--) {
        final j = (random + i) % (i + 1);
        final t = chars[i];
        chars[i] = chars[j];
        chars[j] = t;
      }
      return chars.join();
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(show2FA ? 'Verify 2FA Code' : 'Change Password'),
          content: SizedBox(
            width: 350,
            child: show2FA
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.email_outlined, size: 50, color: _accent),
                      const SizedBox(height: 16),
                      Text(
                        'A verification code has been sent to your email',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: _textSecondary),
                      ),
                      const SizedBox(height: 20),
                      Container(
                        decoration: BoxDecoration(
                          color: _isDark ? Colors.white12 : Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _accent.withValues(alpha: 0.3),
                          ),
                        ),
                        child: TextField(
                          controller: otpCodeController,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 24,
                            letterSpacing: 4,
                            fontWeight: FontWeight.bold,
                          ),
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          decoration: const InputDecoration(
                            hintText: 'Enter 6-digit code',
                            hintStyle: TextStyle(
                              fontSize: 16,
                              letterSpacing: 0,
                            ),
                            border: InputBorder.none,
                            counterText: '',
                            contentPadding: EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _pwField(
                        currentPasswordController,
                        'Current Password',
                        obscureCurrent,
                        () => setState(() => obscureCurrent = !obscureCurrent),
                      ),
                      const SizedBox(height: 16),
                      _pwField(
                        newPasswordController,
                        'New Password',
                        obscureNew,
                        () => setState(() => obscureNew = !obscureNew),
                        onChange: () => checkStrength(setState),
                      ),
                      if (newPasswordController.text.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: LinearProgressIndicator(
                                value: passwordStrength,
                                backgroundColor: Colors.grey.shade300,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  passwordStrengthColor,
                                ),
                                minHeight: 4,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              passwordStrengthText,
                              style: TextStyle(
                                color: passwordStrengthColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(Icons.format_size, size: 18, color: _accent),
                          const SizedBox(width: 8),
                          Text(
                            'Length: ${passwordLength.toInt()}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: _accent,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: passwordLength,
                              min: 8,
                              max: 20,
                              divisions: 12,
                              activeColor: _accent,
                              inactiveColor: Colors.grey.shade300,
                              onChanged: (v) =>
                                  setState(() => passwordLength = v),
                            ),
                          ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () {
                            final pw = generatePassword(passwordLength.toInt());
                            setState(() {
                              newPasswordController.text = pw;
                              confirmPasswordController.text = pw;
                              checkStrength(setState);
                            });
                          },
                          icon: Icon(
                            Icons.auto_awesome,
                            size: 16,
                            color: _accent,
                          ),
                          label: Text(
                            'Suggest strong password',
                            style: TextStyle(fontSize: 12, color: _accent),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _pwField(
                        confirmPasswordController,
                        'Confirm New Password',
                        obscureConfirm,
                        () => setState(() => obscureConfirm = !obscureConfirm),
                      ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: Text('Cancel', style: TextStyle(color: _textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: show2FA
                  ? () async {
                      if (otpCodeController.text.length != 6) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Enter 6-digit code'),
                            backgroundColor: Colors.red,
                          ),
                        );
                        return;
                      }
                      final username = await SecureStorageService().read(
                            SecureStorageService.currentUserKey,
                          ) ??
                          '';
                      final valid = await _syncService.verify2FACode(
                        username,
                        otpCodeController.text,
                      );
                      if (!context.mounted) return;
                      if (valid) {
                        final changed = await _syncService.changePassword(
                          currentPasswordController.text,
                          newPasswordController.text,
                        );
                        if (!context.mounted) return;
                        Navigator.pop(context);
                        if (changed) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Password changed! Please login again.',
                              ),
                              backgroundColor: Colors.green,
                            ),
                          );
                          Future.delayed(const Duration(seconds: 2), _logout);
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Failed to change password'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Invalid code'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    }
                  : () async {
                      if (currentPasswordController.text.isEmpty ||
                          newPasswordController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Fill all fields'),
                            backgroundColor: Colors.red,
                          ),
                        );
                        return;
                      }
                      if (newPasswordController.text.length < 8) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Min 8 characters'),
                            backgroundColor: Colors.red,
                          ),
                        );
                        return;
                      }
                      if (newPasswordController.text !=
                          confirmPasswordController.text) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Passwords don\'t match'),
                            backgroundColor: Colors.red,
                          ),
                        );
                        return;
                      }
                      if (passwordStrength < 0.5) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Use a stronger password'),
                            backgroundColor: Colors.red,
                          ),
                        );
                        return;
                      }
                      final username = await SecureStorageService().read(
                            SecureStorageService.currentUserKey,
                          ) ??
                          '';
                      final sent = await _syncService.send2FACode(
                        username,
                        currentPasswordController.text,
                      );
                      if (!context.mounted) return;
                      if (sent) {
                        setState(() => show2FA = true);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Code sent to your email'),
                            backgroundColor: Colors.green,
                          ),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Invalid current password'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
              child: Text(show2FA ? 'Verify & Change' : 'Send Code'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pwField(
    TextEditingController ctrl,
    String label,
    bool obscure,
    VoidCallback toggleObscure, {
    VoidCallback? onChange,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _isDark ? Colors.white12 : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _accent.withValues(alpha: 0.3)),
      ),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        onChanged: onChange != null ? (_) => onChange() : null,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: _textSecondary),
          prefixIcon: Icon(Icons.lock_outline, color: _accent),
          suffixIcon: IconButton(
            icon: Icon(
              obscure ? Icons.visibility_off : Icons.visibility,
              color: _textSecondary,
            ),
            onPressed: toggleObscure,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
    );
  }

  // --- UI helpers -----------------------------------------------------------
  Widget _profileCard(AuthProvider authProvider) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _isDark
              ? [
                  Color.lerp(_cardColor, _accent, 0.12)!,
                  Color.lerp(_cardColor, _accentSecondary, 0.08)!,
                ]
              : [
                  Color.lerp(Colors.white, _accent, 0.08)!,
                  Color.lerp(Colors.white, _accentSecondary, 0.06)!,
                ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _accent.withValues(alpha: _isDark ? 0.18 : 0.14),
        ),
        boxShadow: [
          BoxShadow(
            color: (_isDark ? Colors.black : _accent).withValues(
              alpha: _isDark ? 0.24 : 0.08,
            ),
            blurRadius: 16,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  _accent.withValues(alpha: 0.18),
                  _accentSecondary.withValues(alpha: 0.12),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _accent.withValues(alpha: 0.18)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: _profilePhotoUrl != null && _profilePhotoUrl!.isNotEmpty
                  ? Image.network(
                      '${AppConfig.mediaUrl}${_profilePhotoUrl!.replaceFirst('/media/', '')}',
                      fit: BoxFit.cover,
                      width: 52,
                      height: 52,
                      errorBuilder: (_, __, ___) =>
                          Icon(Icons.person_rounded, color: _accent, size: 28),
                    )
                  : Icon(Icons.person_rounded, color: _accent, size: 28),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  authProvider.isAuthenticated
                      ? (authProvider.userEmail ?? 'Signed in')
                      : 'Offline vault',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  authProvider.isAuthenticated
                      ? 'Automatic sync enabled'
                      : 'Local codes only',
                  style: TextStyle(fontSize: 12, color: _textSecondary),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color(0xFF10B981).withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF10B981),
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  authProvider.isAuthenticated ? 'Synced' : 'Offline',
                  style: const TextStyle(
                    color: Color(0xFF10B981),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: _textSecondary,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  Widget _settingsCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _accent.withValues(alpha: _isDark ? 0.14 : 0.08),
        ),
        boxShadow: [
          BoxShadow(
            color: (_isDark ? Colors.black : _accent).withValues(
              alpha: _isDark ? 0.22 : 0.045,
            ),
            blurRadius: 14,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }

  Widget _dividerLine() =>
      Divider(height: 1, indent: 68, endIndent: 16, color: _dividerColor);

  Widget _themeModeTile({required ThemeProvider themeProvider}) {
    final mode = themeProvider.themeMode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          _iconBox(
            mode == ThemeMode.system
                ? Icons.brightness_auto_rounded
                : mode == ThemeMode.dark
                    ? Icons.dark_mode_rounded
                    : Icons.light_mode_rounded,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Theme',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: _textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _themeModeSubtitle(mode),
                  style: TextStyle(fontSize: 12, color: _textSecondary),
                ),
                const SizedBox(height: 10),
                SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto_rounded, size: 16),
                      label: Text('System'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode_rounded, size: 16),
                      label: Text('Light'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode_rounded, size: 16),
                      label: Text('Dark'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (selection) {
                    themeProvider.setThemeMode(selection.first);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _themeModeSubtitle(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.system => 'Following this device',
      ThemeMode.light => 'Light mode',
      ThemeMode.dark => 'Dark mode',
    };
  }

  Widget _switchTile({
    required IconData icon,
    required String label,
    required String sub,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          _iconBox(icon),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: _textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: TextStyle(fontSize: 12, color: _textSecondary),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: Colors.white,
            activeTrackColor: _accent,
            inactiveThumbColor: Colors.grey.shade400,
            inactiveTrackColor: _isDark ? Colors.white12 : Colors.grey.shade200,
          ),
        ],
      ),
    );
  }

  Widget _tappableTile({
    required IconData icon,
    required String label,
    required String sub,
    Widget? trailing,
    VoidCallback? onTap,
    bool destructive = false,
  }) {
    final color = destructive ? Colors.red : _textPrimary;
    final subColor = destructive ? Colors.red.shade300 : _textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _iconBox(icon, destructive: destructive),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(fontSize: 12, color: subColor)),
                ],
              ),
            ),
            trailing ??
                (onTap != null
                    ? Icon(
                        Icons.chevron_right_rounded,
                        color: _isDark ? Colors.white24 : Colors.grey.shade300,
                        size: 20,
                      )
                    : const SizedBox.shrink()),
          ],
        ),
      ),
    );
  }

  Widget _iconBox(IconData icon, {bool destructive = false}) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: destructive
            ? Colors.red.withValues(alpha: 0.08)
            : _accent.withValues(alpha: 0.08),
        border: Border.all(
          color: destructive
              ? Colors.red.withValues(alpha: 0.14)
              : _accent.withValues(alpha: 0.14),
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 18, color: destructive ? Colors.red : _accent),
    );
  }

  Widget _colorDot(Color color) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: _isDark ? Colors.white24 : Colors.grey.shade200,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.24),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
    );
  }

  Widget _versionBadge(String version) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 164),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF10B981).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xFF10B981).withValues(alpha: 0.3),
          ),
        ),
        child: Text(
          version,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF10B981),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildUpdateTrailing() {
    if (_isCheckingForUpdates || _isInstallingUpdate) {
      return SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
      );
    }

    final info = _updateInfo;
    if (info != null && info.updateAvailable) {
      final bgColor = info.forceUpdate
          ? Colors.red.withValues(alpha: 0.12)
          : const Color(0xFF10B981).withValues(alpha: 0.12);
      final fgColor = info.forceUpdate ? Colors.red : const Color(0xFF10B981);

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          info.forceUpdate ? 'Required' : 'Update',
          style: TextStyle(
            color: fgColor,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return Icon(
      Icons.refresh_rounded,
      color: _isDark ? Colors.white24 : Colors.grey.shade300,
      size: 20,
    );
  }

  Future<void> _showInstalledReleaseNotes() {
    return _showInstalledReleaseNotesDialog();
  }

  Future<void> _showInstalledReleaseNotesDialog() async {
    final result = await _appUpdateService.getInstalledReleaseNotes();
    if (!mounted) return;

    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Row(
          children: [
            Icon(Icons.article_outlined, color: _accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Release Notes',
                style: TextStyle(color: _textPrimary, fontSize: 18),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 420),
          child: Scrollbar(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _dividerColor),
                    ),
                    child: Text(
                      'Current installed version: ${result.versionLabel}',
                      style: TextStyle(
                        color: _textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    result.notes.trim(),
                    style: TextStyle(
                      color: _textSecondary,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showUpdateDetailsDialog(AppUpdateInfo info) {
    final releaseNotes = info.releaseNotes.trim();
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Row(
          children: [
            Icon(Icons.system_update_alt_rounded, color: _accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                info.forceUpdate ? 'Required update' : 'Update available',
                style: TextStyle(color: _textPrimary, fontSize: 18),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _updateVersionLine('Current', info.currentLabel),
              const SizedBox(height: 8),
              _updateVersionLine('Latest', info.latestLabel),
              const SizedBox(height: 8),
              _updateVersionLine('Package', info.targetLabel),
              const SizedBox(height: 14),
              Text(
                _updateDialogMessage,
                style: TextStyle(color: _textSecondary, fontSize: 13),
              ),
              if (info.reason.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  info.reason.trim(),
                  style: TextStyle(color: _textPrimary, fontSize: 13),
                ),
              ],
              if (releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Release notes',
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _dividerColor),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: Scrollbar(
                      child: SingleChildScrollView(
                        child: Text(
                          releaseNotes,
                          style: TextStyle(
                            color: _textSecondary,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Later'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.system_update_alt_rounded, size: 18),
            label: Text(_updateActionLabel),
          ),
        ],
      ),
    );
  }

  Widget _updateVersionLine(String label, String version) {
    return Row(
      children: [
        SizedBox(
          width: 62,
          child: Text(
            label,
            style: TextStyle(
              color: _textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            version,
            style: TextStyle(
              color: _textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showUpdateProgressDialog(AppUpdateInfo info) {
    _updateProgressDialogVisible = true;
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Row(
          children: [
            Icon(Icons.system_update_alt_rounded, color: _accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _updateProgressTitle(info),
                style: TextStyle(color: _textPrimary, fontSize: 17),
              ),
            ),
          ],
        ),
        content: ValueListenableBuilder<AppDownloadProgress?>(
          valueListenable: _updateProgressNotifier,
          builder: (context, progress, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _updateProgressDescription,
                  style: TextStyle(color: _textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        progress?.percentLabel ?? 'Preparing download...',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        progress?.speedLabel ?? 'Rate: Calculating...',
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(value: progress?.ratio),
                const SizedBox(height: 10),
                Text(
                  progress?.etaLabel ?? 'ETA: Calculating...',
                  style: TextStyle(
                    color: _textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  progress?.sizeLabel ?? 'Downloaded: 0 MiB',
                  style: TextStyle(
                    color: _textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              _appUpdateService.cancelUpdateDownload();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    ).whenComplete(() {
      _updateProgressDialogVisible = false;
    });
  }

  Future<bool?> _showInstallingUpdateDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Row(
          children: [
            Icon(Icons.system_update_alt_rounded, color: _accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Open Installer Now?',
                style: TextStyle(color: _textPrimary, fontSize: 18),
              ),
            ),
          ],
        ),
        content: Text(
          'The update has finished downloading. BeatzLock will close and open the normal Windows installer or Linux package installer. Do you want to continue now?',
          style: TextStyle(color: _textSecondary, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Open Installer'),
          ),
        ],
      ),
    );
  }

  void _showColorPicker(ThemeProvider themeProvider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: _cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: _isDark ? Colors.white24 : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Accent Color',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: _textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 14,
              runSpacing: 14,
              children: themeProvider.accentColors.asMap().entries.map((entry) {
                final selected = themeProvider.accentColorIndex == entry.key;
                return GestureDetector(
                  onTap: () {
                    themeProvider.setAccentColor(entry.key);
                    Navigator.pop(context);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 54,
                    height: 54,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: selected
                          ? Border.all(color: entry.value, width: 2)
                          : Border.all(color: Colors.transparent, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: selected
                              ? entry.value.withValues(alpha: 0.32)
                              : Colors.transparent,
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: entry.value,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: selected
                          ? const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 20,
                            )
                          : null,
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _syncNow() async {
    if (_syncLockedOnThisDevice) {
      await _unlockSyncOnThisDevice();
      return;
    }

    if (!_syncEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Sync is disabled. Enable "Sync to Cloud" first.',
          ),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
      return;
    }

    setState(() => _isSyncing = true);
    final success = await _syncService.syncAccounts();
    if (!mounted) return;
    setState(() => _isSyncing = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Sync complete'
              : (_syncService.lastErrorMessage ??
                  'Sync failed. Check your internet connection.'),
        ),
        backgroundColor: success ? const Color(0xFF10B981) : Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Text('Logout', style: TextStyle(color: _textPrimary)),
        content: Text(
          'Your codes will remain saved on this device.',
          style: TextStyle(color: _textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _syncService.logout();
      if (!mounted) return;
      await Provider.of<AuthProvider>(context, listen: false).continueOffline();
      if (!mounted) return;
      Navigator.pop(context);
    }
  }
}

class _ImportResult {
  const _ImportResult(this.importedCount, this.skippedCount, this.message);

  final int importedCount;
  final int skippedCount;
  final String message;
}
