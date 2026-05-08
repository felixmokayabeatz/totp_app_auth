import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector_windows/file_selector_windows.dart';
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
import '../services/sync_service.dart';
import '../services/app_lock_service.dart';
import '../services/otp_import_service.dart';
import '../services/profile_service.dart';
import '../services/secure_storage_service.dart';
import 'add_account_screen.dart';
import 'device_sessions_screen.dart';
import 'legal_document_screen.dart';
import 'login_screen.dart';
import 'notifications_screen.dart';
import 'profile_screen.dart';

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

  bool _isSyncing = false;
  bool _isCheckingForUpdates = false;
  bool _isInstallingUpdate = false;
  bool _isDownloadingBackupCodes = false;
  bool _isLoadingBackupCodeStatus = false;
  bool _syncEnabled = false;
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
      if (mounted && enabled != _syncEnabled) {
        setState(() => _syncEnabled = enabled);
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
    if (mounted) setState(() => _syncEnabled = enabled);
  }

  Future<void> _loadAppVersion() async {
    final label = await _appUpdateService.getCurrentVersionLabel();
    if (mounted) {
      setState(() {
        _appVersionLabel = label;
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

    final info = await _appUpdateService.checkForUpdate();
    if (!mounted) return;

    setState(() {
      _updateInfo = info;
      _isCheckingForUpdates = false;
    });
  }

  Future<void> _handleUpdateTap() async {
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    final shouldUpdate = await _showUpdateDetailsDialog(info);
    if (shouldUpdate != true || !mounted) return;

    if (_appUpdateService.canSelfUpdate) {
      setState(() => _isInstallingUpdate = true);
      _updateProgressNotifier.value = null;
      unawaited(_showUpdateProgressDialog(info));

      final result = await _appUpdateService.installUpdate(
        info,
        onReceiveProgress: (progress) {
          _updateProgressNotifier.value = progress;
        },
      );
      if (!mounted) return;

      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      setState(() => _isInstallingUpdate = false);

      if (result.started) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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

    if (_isInstallingUpdate) {
      return 'Downloading and starting the updater...';
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
        title: const Text('Settings',
            style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: Colors.white)),
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
            _themeModeTile(
              themeProvider: themeProvider,
            ),
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
                          strokeWidth: 2, color: _accent))
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
              icon: Icons.download_rounded,
              label: 'Import Accounts',
              sub:
                  'Import CSV, otpauth links, or Google Authenticator QR exports',
              onTap: _showImportAccountsDialog,
            ),
            _dividerLine(),

            _tappableTile(
              icon: Icons.lock_outline_rounded,
              label: 'App Lock',
              sub:
                  'Always on. BeatzLock now requires device security or an app PIN every time you reopen it.',
              trailing: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
              sub: !authProvider.isAuthenticated
                  ? 'Sign in to sync across devices'
                  : _syncEnabled
                      ? 'Manually sync with cloud'
                      : 'Cloud sync is disabled',
              trailing: _isSyncing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: _accent))
                  : (_syncEnabled
                      ? null
                      : const Icon(Icons.lock_outline,
                          size: 16, color: Colors.grey)),
              onTap:
                  !authProvider.isAuthenticated ? _openLoginForSync : _syncNow,
            ),
            _dividerLine(),

            // Sync toggle
            _switchTile(
              icon: Icons.cloud_sync_rounded,
              label: 'Sync to Cloud',
              sub: _syncEnabled
                  ? 'Accounts sync automatically'
                  : 'Sync disabled - local only',
              value: authProvider.isAuthenticated && _syncEnabled,
              onChanged: (val) async {
                if (!authProvider.isAuthenticated) {
                  if (val) {
                    await _openLoginForSync();
                  }
                  return;
                }
                await _syncService.setSyncEnabled(val);
                if (!context.mounted) return;
                setState(() => _syncEnabled = val);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(val
                      ? 'Cloud sync enabled on all devices'
                      : 'Cloud sync disabled on all devices'),
                  backgroundColor:
                      val ? const Color(0xFF10B981) : Colors.orange,
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ));
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
                    'Password changes are available after you sign in.')) {
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
                    'Device sessions are available after you sign in.')) {
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
              icon: Icons.notifications_none_rounded,
              label: 'Notifications',
              sub: 'View recent security activity',
              onTap: () async {
                if (!await _requireSignedIn(
                    'Notifications are available after you sign in.')) {
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
              icon: Icons.info_outline_rounded,
              label: 'Version',
              sub: 'Current app version',
              trailing: _versionBadge(_appVersionLabel),
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
              trailing:
                  const Icon(Icons.star_rounded, color: Colors.amber, size: 20),
              onTap: _openRateApp,
            ),
          ]),
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
              icon: Icon(authProvider.isAuthenticated
                  ? Icons.logout_rounded
                  : Icons.login_rounded),
              label: Text(
                  authProvider.isAuthenticated
                      ? 'Sign out to offline mode'
                      : 'Sign in for sync',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: authProvider.isAuthenticated
                    ? Colors.red.shade600
                    : _accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
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
            backgroundColor: Colors.green),
      );
    }
  }

  void _openLegalDocument(String type, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LegalDocumentScreen(
          type: type,
          fallbackTitle: title,
        ),
      ),
    );
  }

  Future<void> _openLoginForSync() async {
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

  Future<bool> _requireSignedIn(String message) async {
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
                                color: Colors.red, fontSize: 12),
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
                    : const Text(
                        'Delete',
                        style: TextStyle(color: Colors.red),
                      ),
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
                            accountUserId: await storage
                                    .read(SecureStorageService.userIdKey) ??
                                '',
                            accountEmail: await storage
                                    .read(SecureStorageService.userEmailKey) ??
                                '',
                            accountUsername: await storage.read(
                                    SecureStorageService.currentUserKey) ??
                                '',
                          );

                          if (!dialogContext.mounted) return;
                          Navigator.pop(dialogContext);
                          if (!mounted) return;

                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(existingRating == null
                                  ? 'Thanks for the review!'
                                  : 'Your review was updated.'),
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
          Text('Comment',
              style: TextStyle(
                  color: _textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(rating.comment,
              style: TextStyle(color: _textPrimary, fontSize: 13, height: 1.5)),
        ],
        if (rating.suggestion.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('Suggestion',
              style: TextStyle(
                  color: _textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(rating.suggestion,
              style: TextStyle(color: _textPrimary, fontSize: 13, height: 1.5)),
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
          color:
              const Color(0xFF16A34A).withValues(alpha: _isDark ? 0.34 : 0.22),
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
            style: TextStyle(
              color: _textPrimary,
              fontSize: 13,
              height: 1.5,
            ),
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
            child: Text(label,
                style: TextStyle(color: _textSecondary, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: _textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
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

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: _cardColor,
          title: Text('Import Accounts', style: TextStyle(color: _textPrimary)),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Scan Google Authenticator transfer QR codes, or choose a CSV export with columns such as Service, Account, Secret.',
                  style: TextStyle(color: _textSecondary, fontSize: 13),
                ),
                if (Platform.isAndroid || Platform.isIOS) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: isImporting
                        ? null
                        : () async {
                            Navigator.pop(dialogContext);
                            final imported = await Navigator.push<bool>(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    const AddAccountScreen(startScanning: true),
                              ),
                            );
                            if (imported == true && mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Text(
                                      'Imported QR accounts successfully.'),
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
                ],
                if (!Platform.isWindows) ...[
                  const SizedBox(height: 12),
                  Text(
                    'CSV file picking is wired for the Windows app build right now.',
                    style:
                        TextStyle(color: Colors.orange.shade600, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: isImporting || isPickingFile || !Platform.isWindows
                      ? null
                      : () async {
                          setDialogState(() {
                            isPickingFile = true;
                            errorText = null;
                          });

                          try {
                            final file = await FileSelectorWindows().openFile(
                              confirmButtonText: 'Import CSV',
                            );
                            if (!dialogContext.mounted) return;

                            if (file == null) {
                              setDialogState(() => isPickingFile = false);
                              return;
                            }

                            final fileName = file.name;
                            if (!fileName.toLowerCase().endsWith('.csv')) {
                              setDialogState(() {
                                selectedEntries = const [];
                                selectedFileName = null;
                                isPickingFile = false;
                                errorText = 'Choose a .csv file.';
                              });
                              return;
                            }

                            final contents = await file.readAsString();
                            final entries =
                                OTPImportService().parseCsv(contents);
                            setDialogState(() {
                              selectedEntries = entries;
                              selectedFileName = fileName;
                              isPickingFile = false;
                              errorText = entries.isEmpty
                                  ? 'No valid TOTP accounts were found in this CSV file.'
                                  : null;
                            });
                          } catch (_) {
                            if (!dialogContext.mounted) return;
                            setDialogState(() {
                              selectedEntries = const [];
                              selectedFileName = null;
                              isPickingFile = false;
                              errorText = 'Could not read that CSV file.';
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
                  label: Text(selectedFileName == null
                      ? 'Choose CSV File'
                      : 'Change CSV File'),
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
                          style: TextStyle(color: _textSecondary, fontSize: 12),
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

                      final result = await _importOtpEntries(selectedEntries);
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

  Future<_ImportResult> _importOtpEntries(List<OTPImportEntry> entries) async {
    final storage = SecureStorageService();
    final userId = await storage.read(SecureStorageService.currentUserKey) ??
        await storage.read(SecureStorageService.localVaultUserKey) ??
        'default_user';
    final userBox = await _syncService.getUserBox();
    final isSignedIn = await _syncService.isLoggedIn();
    var importedCount = 0;
    var skippedCount = 0;

    for (final entry in entries) {
      final duplicate = userBox.values.any((account) {
        return account.service.toLowerCase() == entry.service.toLowerCase() &&
            (account.accountLabel ?? '').toLowerCase() ==
                (entry.accountLabel ?? '').toLowerCase();
      });
      if (duplicate) {
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

      if (isSignedIn) {
        try {
          await _syncService.logAccountAddedNotification(
            serviceName: entry.service,
            accountLabel: entry.accountLabel,
          );
        } catch (_) {}
      }
    }

    if (importedCount > 0 && isSignedIn && await _syncService.isSyncEnabled()) {
      await _syncService.syncAccounts();
    }

    final message = importedCount == 0
        ? 'No new accounts imported.'
        : 'Imported $importedCount account${importedCount == 1 ? '' : 's'}${skippedCount > 0 ? ', skipped $skippedCount duplicate${skippedCount == 1 ? '' : 's'}' : ''}.';
    return _ImportResult(importedCount, skippedCount, message);
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
          content:
              const Text('Unlock with device security or your app PIN first.'),
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
    final savedPath = await _syncService.downloadBackupCodesPdf();
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

  // ─── Clear all data (with local/everywhere choice) ────────────────────────
  void _clearAllData() async {
    // Step 1: ask local-only vs everywhere
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Row(children: [
          const Icon(Icons.warning_rounded, color: Colors.red, size: 24),
          const SizedBox(width: 10),
          Text('Clear All Data',
              style: TextStyle(color: _textPrimary, fontSize: 17)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This will permanently delete ALL your OTP accounts.',
                style: TextStyle(color: _textSecondary, fontSize: 13)),
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: _cardColor,
          title:
              Text('Delete local copy?', style: TextStyle(color: _textPrimary)),
          content: Text(
            'All accounts will be removed from this device. You can re-sync from cloud later.',
            style: TextStyle(color: _textSecondary, fontSize: 13),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white),
              child: const Text('Delete Local'),
            ),
          ],
        ),
      );
      if (confirm != true) return;

      await _syncService.deleteAllLocalOnly();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text(
            'All accounts removed from this device. Sync to restore.'),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      Navigator.pop(context);
      return;
    }

    // ── "Everywhere" path: require OTP ──────────────────────────────────────
    if (!await _syncService.isLoggedIn()) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: _cardColor,
          title:
              Text('Sign in required', style: TextStyle(color: _textPrimary)),
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

    final username = await SecureStorageService()
            .read(SecureStorageService.currentUserKey) ??
        '';

    final otpSent = await _syncService.sendDeleteOtp(username);
    if (!otpSent) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text('Failed to send verification code. Check your connection.'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    final otpController = TextEditingController();
    if (!mounted) return;
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Text('Confirm Deletion', style: TextStyle(color: _textPrimary)),
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
                controller: otpController,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 24,
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold),
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
              otpController.dispose();
              Navigator.pop(dialogContext, false);
            },
            child: Text('Cancel', style: TextStyle(color: _textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              final code = otpController.text.trim();
              if (code.length != 6) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(const SnackBar(
                  content: Text('Enter the 6-digit code'),
                  backgroundColor: Colors.red,
                ));
                return;
              }
              final ok = await _syncService.verifyDeleteOtp(username, code);
              if (!dialogContext.mounted) return;
              otpController.dispose();
              Navigator.pop(dialogContext, ok);
            },
            child: const Text('Delete Everything'),
          ),
        ],
      ),
    );

    if (verified != true) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Invalid code – deletion cancelled'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    final ok = await _syncService.deleteAllEverywhere();
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('All accounts deleted everywhere'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Failed to delete from cloud – try again'),
        backgroundColor: Colors.red,
      ));
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
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: color)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11, color: color.withValues(alpha: 0.7))),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: color.withValues(alpha: 0.5), size: 18),
          ],
        ),
      ),
    );
  }

  // ─── Change password dialog (unchanged from original) ─────────────────────
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(show2FA ? 'Verify 2FA Code' : 'Change Password'),
          content: SizedBox(
            width: 350,
            child: show2FA
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.email_outlined, size: 50, color: _accent),
                    const SizedBox(height: 16),
                    Text('A verification code has been sent to your email',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: _textSecondary)),
                    const SizedBox(height: 20),
                    Container(
                      decoration: BoxDecoration(
                        color: _isDark ? Colors.white12 : Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border:
                            Border.all(color: _accent.withValues(alpha: 0.3)),
                      ),
                      child: TextField(
                        controller: otpCodeController,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 24,
                            letterSpacing: 4,
                            fontWeight: FontWeight.bold),
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: const InputDecoration(
                          hintText: 'Enter 6-digit code',
                          hintStyle: TextStyle(fontSize: 16, letterSpacing: 0),
                          border: InputBorder.none,
                          counterText: '',
                          contentPadding: EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ),
                  ])
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    _pwField(
                        currentPasswordController,
                        'Current Password',
                        obscureCurrent,
                        () => setState(() => obscureCurrent = !obscureCurrent)),
                    const SizedBox(height: 16),
                    _pwField(newPasswordController, 'New Password', obscureNew,
                        () => setState(() => obscureNew = !obscureNew),
                        onChange: () => checkStrength(setState)),
                    if (newPasswordController.text.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                            child: LinearProgressIndicator(
                                value: passwordStrength,
                                backgroundColor: Colors.grey.shade300,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    passwordStrengthColor),
                                minHeight: 4,
                                borderRadius: BorderRadius.circular(2))),
                        const SizedBox(width: 8),
                        Text(passwordStrengthText,
                            style: TextStyle(
                                color: passwordStrengthColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 12)),
                      ]),
                    ],
                    const SizedBox(height: 8),
                    Row(children: [
                      Icon(Icons.format_size, size: 18, color: _accent),
                      const SizedBox(width: 8),
                      Text('Length: ${passwordLength.toInt()}',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: _accent)),
                      Expanded(
                          child: Slider(
                        value: passwordLength,
                        min: 8,
                        max: 20,
                        divisions: 12,
                        activeColor: _accent,
                        inactiveColor: Colors.grey.shade300,
                        onChanged: (v) => setState(() => passwordLength = v),
                      )),
                    ]),
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
                        icon:
                            Icon(Icons.auto_awesome, size: 16, color: _accent),
                        label: Text('Suggest strong password',
                            style: TextStyle(fontSize: 12, color: _accent)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _pwField(
                        confirmPasswordController,
                        'Confirm New Password',
                        obscureConfirm,
                        () => setState(() => obscureConfirm = !obscureConfirm)),
                  ]),
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
                      borderRadius: BorderRadius.circular(10))),
              onPressed: show2FA
                  ? () async {
                      if (otpCodeController.text.length != 6) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Enter 6-digit code'),
                                backgroundColor: Colors.red));
                        return;
                      }
                      final username = await SecureStorageService()
                              .read(SecureStorageService.currentUserKey) ??
                          '';
                      final valid = await _syncService.verify2FACode(
                          username, otpCodeController.text);
                      if (!context.mounted) return;
                      if (valid) {
                        final changed = await _syncService.changePassword(
                            currentPasswordController.text,
                            newPasswordController.text);
                        if (!context.mounted) return;
                        Navigator.pop(context);
                        if (changed) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Password changed! Please login again.'),
                                  backgroundColor: Colors.green));
                          Future.delayed(const Duration(seconds: 2), _logout);
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Failed to change password'),
                                  backgroundColor: Colors.red));
                        }
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Invalid code'),
                                backgroundColor: Colors.red));
                      }
                    }
                  : () async {
                      if (currentPasswordController.text.isEmpty ||
                          newPasswordController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Fill all fields'),
                                backgroundColor: Colors.red));
                        return;
                      }
                      if (newPasswordController.text.length < 8) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Min 8 characters'),
                                backgroundColor: Colors.red));
                        return;
                      }
                      if (newPasswordController.text !=
                          confirmPasswordController.text) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Passwords don\'t match'),
                                backgroundColor: Colors.red));
                        return;
                      }
                      if (passwordStrength < 0.5) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Use a stronger password'),
                                backgroundColor: Colors.red));
                        return;
                      }
                      final username = await SecureStorageService()
                              .read(SecureStorageService.currentUserKey) ??
                          '';
                      final sent = await _syncService.send2FACode(
                          username, currentPasswordController.text);
                      if (!context.mounted) return;
                      if (sent) {
                        setState(() => show2FA = true);
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Code sent to your email'),
                                backgroundColor: Colors.green));
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Invalid current password'),
                                backgroundColor: Colors.red));
                      }
                    },
              child: Text(show2FA ? 'Verify & Change' : 'Send Code'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pwField(TextEditingController ctrl, String label, bool obscure,
      VoidCallback toggleObscure,
      {VoidCallback? onChange}) {
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
            icon: Icon(obscure ? Icons.visibility_off : Icons.visibility,
                color: _textSecondary),
            onPressed: toggleObscure,
          ),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
    );
  }

  // ─── UI helpers ───────────────────────────────────────────────────────────
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
        border:
            Border.all(color: _accent.withValues(alpha: _isDark ? 0.18 : 0.14)),
        boxShadow: [
          BoxShadow(
              color: (_isDark ? Colors.black : _accent)
                  .withValues(alpha: _isDark ? 0.24 : 0.08),
              blurRadius: 16,
              offset: const Offset(0, 3))
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
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.person_rounded,
                        color: _accent,
                        size: 28,
                      ),
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
                        color: _textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                    authProvider.isAuthenticated
                        ? 'Automatic sync enabled'
                        : 'Local codes only',
                    style: TextStyle(fontSize: 12, color: _textSecondary)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: const Color(0xFF10B981).withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: Color(0xFF10B981))),
                const SizedBox(width: 5),
                Text(authProvider.isAuthenticated ? 'Synced' : 'Offline',
                    style: const TextStyle(
                        color: Color(0xFF10B981),
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
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
      child: Text(text.toUpperCase(),
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _textSecondary,
              letterSpacing: 1.0)),
    );
  }

  Widget _settingsCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: _accent.withValues(alpha: _isDark ? 0.14 : 0.08)),
        boxShadow: [
          BoxShadow(
              color: (_isDark ? Colors.black : _accent)
                  .withValues(alpha: _isDark ? 0.22 : 0.045),
              blurRadius: 14,
              offset: const Offset(0, 3))
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
          _iconBox(mode == ThemeMode.system
              ? Icons.brightness_auto_rounded
              : mode == ThemeMode.dark
                  ? Icons.dark_mode_rounded
                  : Icons.light_mode_rounded),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Theme',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: _textPrimary)),
                const SizedBox(height: 2),
                Text(_themeModeSubtitle(mode),
                    style: TextStyle(fontSize: 12, color: _textSecondary)),
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
                Text(label,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: _textPrimary)),
                const SizedBox(height: 2),
                Text(sub,
                    style: TextStyle(fontSize: 12, color: _textSecondary)),
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
                  Text(label,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: color)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(fontSize: 12, color: subColor)),
                ],
              ),
            ),
            trailing ??
                (onTap != null
                    ? Icon(Icons.chevron_right_rounded,
                        color: _isDark ? Colors.white24 : Colors.grey.shade300,
                        size: 20)
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
            color: _isDark ? Colors.white24 : Colors.grey.shade200, width: 2),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF10B981).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
      ),
      child: Text(version,
          style: const TextStyle(
              color: Color(0xFF10B981),
              fontSize: 12,
              fontWeight: FontWeight.w600)),
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
              const SizedBox(height: 14),
              Text(
                _appUpdateService.canSelfUpdate
                    ? 'BeatzLock can download and start this update from settings on Windows and Linux/Kali.'
                    : 'The download page will open so you can install the update.',
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
            label: Text(
              _appUpdateService.canSelfUpdate
                  ? 'Install update'
                  : 'Open download',
            ),
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
                'Installing ${info.latestLabel}',
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
                  'Downloading the update. The installer will start when the download finishes.',
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
                        progress?.speedLabel ?? 'Speed: Calculating...',
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
                  progress?.sizeLabel ?? 'Downloaded: 0 MB',
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
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20))),
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
                        borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 20),
            Text('Accent Color',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: _textPrimary)),
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
                        )
                      ],
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: entry.value,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: selected
                          ? const Icon(Icons.check_rounded,
                              color: Colors.white, size: 20)
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
    if (!_syncEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Sync is disabled. Enable "Sync to Cloud" first.'),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }

    setState(() => _isSyncing = true);
    final success = await _syncService.syncAccounts();
    if (!mounted) return;
    setState(() => _isSyncing = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        success
            ? 'Sync complete'
            : (_syncService.lastErrorMessage ??
                'Sync failed. Check your internet connection.'),
      ),
      backgroundColor: success ? const Color(0xFF10B981) : Colors.red,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Text('Logout', style: TextStyle(color: _textPrimary)),
        content: Text('Your codes will remain saved on this device.',
            style: TextStyle(color: _textSecondary, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: _accent, foregroundColor: Colors.white),
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
