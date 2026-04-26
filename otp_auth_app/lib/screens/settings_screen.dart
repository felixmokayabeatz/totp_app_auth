import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../models/app_update_info.dart';
import '../services/app_update_service.dart';
import '../services/sync_service.dart';
import '../services/biometric_service.dart';
import '../services/app_lock_service.dart';
import '../services/secure_storage_service.dart';
import 'login_screen.dart';
import 'notifications_screen.dart';
import 'profile_screen.dart';
import 'dart:async';

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SyncService _syncService = SyncService();
  final BiometricService _biometricService = BiometricService();
  final AppLockService _appLockService = AppLockService();
  final AppUpdateService _appUpdateService = AppUpdateService();

  bool _isSyncing = false;
  bool _isCheckingForUpdates = false;
  bool _isDownloadingBackupCodes = false;
  bool _isLoadingBackupCodeStatus = false;
  bool _syncEnabled = true;
  bool _appLockEnabled = false;
  String _appVersionLabel = '...';
  Timer? _syncPrefTimer;
  AppUpdateInfo? _updateInfo;
  Map<String, dynamic>? _backupCodeStatus;

  @override
  void initState() {
    super.initState();
    _loadSyncPreference();
    _loadAppLockSettings();
    _loadAppVersion();
    _refreshUpdateInfo();
    _loadBackupCodeStatus();
    _syncPrefTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
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
    super.dispose();
  }

  Future<void> _loadSyncPreference() async {
    final enabled = await _syncService.isSyncEnabled();
    if (mounted) setState(() => _syncEnabled = enabled);
  }

  Future<void> _loadAppLockSettings() async {
    final appLockEnabled = await _appLockService.isAppLockEnabled();
    if (mounted) {
      setState(() {
        _appLockEnabled = appLockEnabled;
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

  Future<void> _loadBackupCodeStatus() async {
    if (_isLoadingBackupCodeStatus) return;

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
          content: const Text('Updates are not configured for this platform yet.'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
      return 'Updates are not configured for this platform';
    }

    if (_isCheckingForUpdates) {
      return 'Checking for updates...';
    }

    final info = _updateInfo;
    if (info == null) {
      return 'Check for a newer version';
    }

    if (info.updateAvailable && info.forceUpdate) {
      return 'Required update available: ${info.latestLabel}';
    }

    if (info.updateAvailable) {
      return 'Optional update available: ${info.latestLabel}';
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

  bool get _canChangeAppPin => Platform.isLinux || Platform.isMacOS;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => const Color(0xFF4F46E5);
  Color get _bgColor =>
      _isDark ? const Color(0xFF0F0F1A) : const Color(0xFFF0F2FF);
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white38 : Colors.grey.shade500;
  Color get _dividerColor =>
      _isDark ? Colors.white.withOpacity(0.06) : Colors.grey.shade100;

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
        backgroundColor: _isDark ? const Color(0xFF1A1A2E) : _accent,
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
            _switchTile(
              icon: Icons.dark_mode_rounded,
              label: 'Dark Mode',
              sub: 'Turn dark mode on or off',
              value: themeProvider.themeMode == ThemeMode.dark,
              onChanged: (enabled) => themeProvider
                  .setThemeMode(enabled ? ThemeMode.dark : ThemeMode.light),
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
              sub: 'Save a PDF with your recovery codes',
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
              sub: _backupCodeStatusSubtitle(),
              trailing: _backupCodeStatusTrailing(),
              onTap: _loadBackupCodeStatus,
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.download_rounded,
              label: 'Import Accounts',
              sub: 'Restore from backup',
              onTap: () => _soon('Import'),
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
                  color: const Color(0xFF10B981).withOpacity(0.12),
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

            if (_canChangeAppPin) ...[
              _dividerLine(),
              _tappableTile(
                icon: Icons.pin,
                label: 'Change App PIN',
                sub: 'Use this if your device falls back to the BeatzLock PIN',
                onTap: _changeAppPin,
              ),
            ],

            _tappableTile(
              icon: Icons.sync_rounded,
              label: 'Sync Now',
              sub: _syncEnabled
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
              onTap: _syncEnabled ? _syncNow : null,
            ),
            _dividerLine(),

            // Sync toggle
            _switchTile(
              icon: Icons.cloud_sync_rounded,
              label: 'Sync to Cloud',
              sub: _syncEnabled
                  ? 'Accounts sync automatically'
                  : 'Sync disabled – local only',
              value: _syncEnabled,
              onChanged: (val) async {
                await _syncService.setSyncEnabled(val);
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
              label: 'Profile',
              sub: 'Edit profile information',
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => ProfileScreen())),
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.lock_outline_rounded,
              label: 'Change Password',
              sub: 'Update your password',
              onTap: _showChangePasswordDialog,
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.notifications_none_rounded,
              label: 'Notifications',
              sub: 'View recent security activity',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const NotificationsScreen(),
                ),
              ),
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
              onTap: () => _soon('Privacy Policy'),
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.description_outlined,
              label: 'Terms of Service',
              sub: 'Terms and conditions',
              onTap: () => _soon('Terms of Service'),
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.star_outline_rounded,
              label: 'Rate the App',
              sub: 'Love it? Leave a review',
              trailing:
                  const Icon(Icons.star_rounded, color: Colors.amber, size: 20),
              onTap: () => _soon('Rate Us'),
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
              onPressed: _logout,
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Logout',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade600,
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
    final success = await _appLockService.setupAppPinFromSettings(context);
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('PIN changed successfully'),
            backgroundColor: Colors.green),
      );
    }
  }

  Future<void> _downloadBackupCodes() async {
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

    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
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
    final username = await SecureStorageService()
            .read(SecureStorageService.currentUserKey) ??
        '';

    final otpSent = await _syncService.sendDeleteOtp(username);
    if (!otpSent) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text('Failed to send verification code. Check your connection.'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    final otpController = TextEditingController();
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
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
                border: Border.all(color: Colors.red.withOpacity(0.4)),
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
              Navigator.pop(context, false);
            },
            child: Text('Cancel', style: TextStyle(color: _textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              final code = otpController.text.trim();
              if (code.length != 6) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Enter the 6-digit code'),
                  backgroundColor: Colors.red,
                ));
                return;
              }
              final ok = await _syncService.verifyDeleteOtp(username, code);
              otpController.dispose();
              Navigator.pop(context, ok);
            },
            child: const Text('Delete Everything'),
          ),
        ],
      ),
    );

    if (verified != true) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Invalid code – deletion cancelled'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    final ok = await _syncService.deleteAllEverywhere();
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
          color: color.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
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
                          fontSize: 11, color: color.withOpacity(0.7))),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: color.withOpacity(0.5), size: 18),
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
    bool _obscureCurrent = true;
    bool _obscureNew = true;
    bool _obscureConfirm = true;
    bool _show2FA = false;
    double _passwordStrength = 0.0;
    String _passwordStrengthText = '';
    Color _passwordStrengthColor = Colors.grey;
    double _passwordLength = 16;

    void checkStrength(StateSetter setState) {
      final pw = newPasswordController.text;
      if (pw.isEmpty) {
        setState(() {
          _passwordStrength = 0;
          _passwordStrengthText = '';
        });
        return;
      }
      int score = 0;
      if (pw.length >= 12)
        score += 25;
      else if (pw.length >= 8) score += 15;
      if (pw.contains(RegExp(r'[0-9]'))) score += 25;
      if (pw.contains(RegExp(r'[A-Z]'))) score += 25;
      if (pw.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>_+=\[\]\\;/-]')))
        score += 25;
      setState(() {
        _passwordStrength = score / 100;
        if (score < 50) {
          _passwordStrengthText = 'Weak';
          _passwordStrengthColor = Colors.red;
        } else if (score < 75) {
          _passwordStrengthText = 'Medium';
          _passwordStrengthColor = Colors.orange;
        } else {
          _passwordStrengthText = 'Strong';
          _passwordStrengthColor = Colors.green;
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
      for (int i = pw.length; i < length; i++)
        pw += all[(random + i) % all.length];
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
          title: Text(_show2FA ? 'Verify 2FA Code' : 'Change Password'),
          content: SizedBox(
            width: 350,
            child: _show2FA
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
                        border: Border.all(color: _accent.withOpacity(0.3)),
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
                        _obscureCurrent,
                        () =>
                            setState(() => _obscureCurrent = !_obscureCurrent)),
                    const SizedBox(height: 16),
                    _pwField(newPasswordController, 'New Password', _obscureNew,
                        () => setState(() => _obscureNew = !_obscureNew),
                        onChange: () => checkStrength(setState)),
                    if (newPasswordController.text.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                            child: LinearProgressIndicator(
                                value: _passwordStrength,
                                backgroundColor: Colors.grey.shade300,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    _passwordStrengthColor),
                                minHeight: 4,
                                borderRadius: BorderRadius.circular(2))),
                        const SizedBox(width: 8),
                        Text(_passwordStrengthText,
                            style: TextStyle(
                                color: _passwordStrengthColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 12)),
                      ]),
                    ],
                    const SizedBox(height: 8),
                    Row(children: [
                      Icon(Icons.format_size, size: 18, color: _accent),
                      const SizedBox(width: 8),
                      Text('Length: ${_passwordLength.toInt()}',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: _accent)),
                      Expanded(
                          child: Slider(
                        value: _passwordLength,
                        min: 8,
                        max: 20,
                        divisions: 12,
                        activeColor: _accent,
                        inactiveColor: Colors.grey.shade300,
                        onChanged: (v) => setState(() => _passwordLength = v),
                      )),
                    ]),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () {
                          final pw = generatePassword(_passwordLength.toInt());
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
                        _obscureConfirm,
                        () =>
                            setState(() => _obscureConfirm = !_obscureConfirm)),
                  ]),
          ),
          actions: [
            TextButton(
              onPressed: () {
                currentPasswordController.dispose();
                newPasswordController.dispose();
                confirmPasswordController.dispose();
                otpCodeController.dispose();
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
              onPressed: _show2FA
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
                      if (valid) {
                        final changed = await _syncService.changePassword(
                            currentPasswordController.text,
                            newPasswordController.text);
                        currentPasswordController.dispose();
                        newPasswordController.dispose();
                        confirmPasswordController.dispose();
                        otpCodeController.dispose();
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
                      if (_passwordStrength < 0.5) {
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
                      if (sent) {
                        setState(() => _show2FA = true);
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
              child: Text(_show2FA ? 'Verify & Change' : 'Send Code'),
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
        border: Border.all(color: _accent.withOpacity(0.3)),
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
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(_isDark ? 0.2 : 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3))
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
                color: _accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(16)),
            child: Icon(Icons.person_rounded, color: _accent, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(authProvider.userEmail ?? 'User',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text('Premium Account',
                    style: TextStyle(fontSize: 12, color: _textSecondary)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
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
                const Text('Active',
                    style: TextStyle(
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
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(_isDark ? 0.2 : 0.05),
              blurRadius: 12,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(children: children),
    );
  }

  Widget _dividerLine() =>
      Divider(height: 1, indent: 68, endIndent: 16, color: _dividerColor);

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
            activeColor: Colors.white,
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
            ? Colors.red.withOpacity(0.08)
            : _accent.withOpacity(0.08),
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
      ),
    );
  }

  Widget _versionBadge(String version) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF10B981).withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
      ),
      child: Text(version,
          style: const TextStyle(
              color: Color(0xFF10B981),
              fontSize: 12,
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildUpdateTrailing() {
    if (_isCheckingForUpdates) {
      return SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
      );
    }

    final info = _updateInfo;
    if (info != null && info.updateAvailable) {
      final bgColor = info.forceUpdate
          ? Colors.red.withOpacity(0.12)
          : const Color(0xFF10B981).withOpacity(0.12);
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
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: entry.value,
                      shape: BoxShape.circle,
                      border: selected
                          ? Border.all(color: _textPrimary, width: 3)
                          : null,
                      boxShadow: [
                        BoxShadow(
                            color: entry.value.withOpacity(0.4),
                            blurRadius: 8,
                            offset: const Offset(0, 3))
                      ],
                    ),
                    child: selected
                        ? const Icon(Icons.check_rounded,
                            color: Colors.white, size: 20)
                        : null,
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

  void _soon(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$feature coming soon'),
      backgroundColor: _accent,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      duration: const Duration(seconds: 2),
    ));
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
    setState(() => _isSyncing = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:
          Text(success ? 'Sync complete' : 'Sync failed – check connection'),
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
      await Provider.of<AuthProvider>(context, listen: false).logout();
      await _syncService.logout();
      Navigator.pushAndRemoveUntil(context,
          MaterialPageRoute(builder: (_) => LoginScreen()), (r) => false);
    }
  }
}
