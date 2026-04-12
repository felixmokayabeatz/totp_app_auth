// lib/screens/home_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import '../models/otp_account.dart';
import '../services/otp_service.dart';
import '../services/sync_service.dart';
import '../services/profile_service.dart';
import '../providers/theme_provider.dart';
import '../providers/auth_provider.dart';
import 'add_account_screen.dart';
import 'settings_screen.dart';
import 'login_screen.dart';
import 'show_qr_screen.dart';
import 'profile_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  final OTPService _otpService = OTPService();
  final SyncService _syncService = SyncService();
  final ProfileService _profileService = ProfileService();

  Map<String, String> currentOTPs = {};
  Map<String, int> timers = {};
  Map<String, bool> blurredCodes = {};
  late AnimationController _animationController;
  String _searchQuery = '';
  bool _isSyncing = false;
  bool _allBlurred = false;
  String? _profilePhotoUrl;
  String? _username;
  Box<OTPAccount>? _userBox;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _animationController.forward();
    _loadData();
  }

  Future<void> _loadData() async {
    await _initUserBox();
    _startTimer();
    _loadProfileData();
  }

  Future<void> _initUserBox() async {
    _userBox = await _syncService.getUserBox();
    print('User box: ${await _syncService.getCurrentUserBoxName()} has ${_userBox?.length ?? 0} accounts');
    if (mounted) setState(() {});
  }

  Future<void> _loadProfileData() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _username = prefs.getString('current_user') ?? 'User');
    final profile = await _profileService.getProfile();
    if (profile != null && mounted) {
      setState(() => _profilePhotoUrl = profile['profile']?['profile_photo']);
    }
  }

  void _startTimer() {
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        _updateAllOTPs();
        _startTimer();
      }
    });
  }

  void _updateAllOTPs() async {
    if (_userBox == null) return;
    final newOTPs = <String, String>{};
    final newTimers = <String, int>{};

    for (var account in _userBox!.values) {
      // generateOTP internally uses the normalised counter – same result every
      // call within the same 30-second window regardless of millisecond drift.
      newOTPs[account.id] = await _otpService.generateOTP(account.secret);
      newTimers[account.id] = _otpService.secondsRemaining();
      blurredCodes.putIfAbsent(account.id, () => false);
    }

    if (mounted) {
      setState(() {
        currentOTPs = newOTPs;
        timers = newTimers;
      });
    }
  }

  void _toggleBlurAll() {
    setState(() {
      _allBlurred = !_allBlurred;
      for (var key in blurredCodes.keys) {
        blurredCodes[key] = _allBlurred;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.isDarkMode;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F0F1A) : const Color(0xFFF0F2FF),
      body: Column(
        children: [
          _buildHeader(isDark),
          _buildSearchBar(isDark),
          Expanded(child: _buildAccountsList(isDark)),
        ],
      ),
    );
  }

  // ─── Header ───────────────────────────────────────────────────────────────
  Widget _buildHeader(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A2E) : const Color(0xFF4F46E5),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
          child: Row(
            children: [
              GestureDetector(
                onTap: () async {
                  final result = await Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileScreen()));
                  if (result == true) _loadProfileData();
                },
                child: Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withOpacity(0.3), width: 2),
                  ),
                  child: ClipOval(
                    child: _profilePhotoUrl != null && _profilePhotoUrl!.isNotEmpty
                        ? Image.network(
                            '${AppConfig.mediaUrl}${_profilePhotoUrl!.replaceFirst('/media/', '')}',
                            fit: BoxFit.cover, width: 44, height: 44,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.white.withOpacity(0.2),
                              child: const Icon(Icons.person, color: Colors.white, size: 24),
                            ),
                          )
                        : Container(
                            color: Colors.white.withOpacity(0.2),
                            child: const Icon(Icons.person, color: Colors.white, size: 24),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('BeatzLock Authenticator',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: 0.3)),
                  Text(_username ?? 'Two-Factor Security',
                      style: const TextStyle(fontSize: 11, color: Colors.white60)),
                ],
              ),
              const Spacer(),
              _headerAction(_allBlurred ? Icons.visibility_rounded : Icons.visibility_off_rounded, _toggleBlurAll,
                  tooltip: _allBlurred ? 'Show codes' : 'Hide codes'),
              _headerAction(Icons.sync_rounded, _syncData, tooltip: 'Sync', loading: _isSyncing),
              _headerAction(Icons.settings_rounded,
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen())),
                  tooltip: 'Settings'),
              _headerAction(
                  isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                  () => Provider.of<ThemeProvider>(context, listen: false).toggleTheme(),
                  tooltip: 'Toggle theme'),
              _headerAction(Icons.logout_rounded, _logout, tooltip: 'Logout'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerAction(IconData icon, VoidCallback onTap, {String? tooltip, bool loading = false}) {
    return Tooltip(
      message: tooltip ?? '',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 40, height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: loading
              ? const Padding(padding: EdgeInsets.all(10),
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  // ─── Search bar ───────────────────────────────────────────────────────────
  Widget _buildSearchBar(bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E32) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1A1A2E), fontSize: 14),
              onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
              decoration: InputDecoration(
                hintText: 'Search accounts…',
                hintStyle: TextStyle(color: isDark ? Colors.white38 : Colors.grey[400], fontSize: 14),
                prefixIcon: Icon(Icons.search_rounded, color: isDark ? Colors.white38 : Colors.grey[400], size: 20),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          GestureDetector(
            onTap: () async {
              final result = await Navigator.push(context, MaterialPageRoute(builder: (_) => AddAccountScreen()));
              if (result == true) { await _initUserBox(); _updateAllOTPs(); }
            },
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: const Color(0xFF4F46E5), borderRadius: BorderRadius.circular(10)),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, color: Colors.white, size: 18),
                  SizedBox(width: 4),
                  Text('Add', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Accounts list ────────────────────────────────────────────────────────
  Widget _buildAccountsList(bool isDark) {
    if (_userBox == null) {
      return const Center(child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4F46E5))));
    }

    var accounts = _userBox!.values.toList();
    if (_searchQuery.isNotEmpty) {
      accounts = accounts
          .where((a) =>
              a.service.toLowerCase().contains(_searchQuery) ||
              (a.issuer?.toLowerCase().contains(_searchQuery) ?? false))
          .toList();
    }

    if (accounts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E32) : Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 20)],
              ),
              child: const Icon(Icons.security_rounded, size: 40, color: Color(0xFF4F46E5)),
            ),
            const SizedBox(height: 20),
            Text('No accounts yet',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : const Color(0xFF1A1A2E))),
            const SizedBox(height: 6),
            Text('Tap Add to get started',
                style: TextStyle(color: isDark ? Colors.white38 : Colors.grey[500], fontSize: 13)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: accounts.length,
      itemBuilder: (context, index) {
        final account = accounts[index];
        final otp = currentOTPs[account.id] ?? '------';
        final timer = timers[account.id] ?? 30;
        final isBlurred = blurredCodes[account.id] ?? false;
        final isExpiring = timer <= 5;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E32) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isExpiring
                  ? Colors.red.withOpacity(0.4)
                  : (isDark ? Colors.white.withOpacity(0.06) : Colors.transparent),
              width: 1.5,
            ),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.2 : 0.06),
                blurRadius: 12, offset: const Offset(0, 3))],
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF4F46E5).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(_getServiceIcon(account.service), color: const Color(0xFF4F46E5), size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(account.service,
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                                  color: isDark ? Colors.white : const Color(0xFF1A1A2E)),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (account.issuer != null)
                            Text(account.issuer!,
                                style: TextStyle(fontSize: 12,
                                    color: isDark ? Colors.white38 : Colors.grey[500]),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: isExpiring
                                ? Colors.red.withOpacity(0.1)
                                : const Color(0xFF4F46E5).withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            isBlurred ? '●●● ●●●' : _formatOtp(otp),
                            style: TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w700,
                              color: isExpiring ? Colors.red : (isDark ? Colors.white : const Color(0xFF1A1A2E)),
                              letterSpacing: 3, fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text('${timer}s',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                                color: isExpiring ? Colors.red : (isDark ? Colors.white38 : Colors.grey[500]))),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: timer / 30,
                    backgroundColor: isDark ? Colors.white10 : Colors.grey[100],
                    valueColor: AlwaysStoppedAnimation<Color>(isExpiring ? Colors.red : const Color(0xFF4F46E5)),
                    minHeight: 4,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _accountAction(Icons.copy_rounded, 'Copy', () => _copyToClipboard(otp), isDark),
                    const SizedBox(width: 8),
                    _accountAction(
                      isBlurred ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                      isBlurred ? 'Show' : 'Hide',
                      () => setState(() => blurredCodes[account.id] = !isBlurred),
                      isDark,
                    ),
                    const SizedBox(width: 8),
                    _accountAction(
                      Icons.qr_code_rounded, 'QR',
                      () => Navigator.push(context, MaterialPageRoute(
                          builder: (_) => ShowQRScreen(
                              secret: account.secret,
                              service: account.service,
                              issuer: account.issuer))),
                      isDark,
                    ),
                    const Spacer(),
                    _accountAction(
                      Icons.delete_outline_rounded, 'Delete',
                      () => _showDeleteAccountDialog(account.id),
                      isDark, destructive: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ─── Delete account dialog ────────────────────────────────────────────────
  void _showDeleteAccountDialog(String accountId) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF1E1E32) : Colors.white;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A2E);
    final textSecondary = isDark ? Colors.white38 : Colors.grey.shade500;

    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: cardColor,
        title: Row(children: [
          const Icon(Icons.delete_outline_rounded, color: Colors.red, size: 24),
          const SizedBox(width: 10),
          Text('Delete Account', style: TextStyle(color: textPrimary, fontSize: 17)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Where should this account be deleted?',
                style: TextStyle(color: textSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            _deleteOptionTile(
              icon: Icons.phone_android_rounded,
              title: 'This device only',
              subtitle: 'Other devices keep the account',
              color: Colors.orange,
              onTap: () => Navigator.pop(context, 'local'),
            ),
            const SizedBox(height: 8),
            _deleteOptionTile(
              icon: Icons.cloud_off_rounded,
              title: 'Everywhere',
              subtitle: 'Removed from all devices & cloud permanently',
              color: Colors.red,
              onTap: () => Navigator.pop(context, 'everywhere'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: Text('Cancel', style: TextStyle(color: textSecondary)),
          ),
        ],
      ),
    );

    if (choice == null || choice == 'cancel') return;

    if (choice == 'local') {
      await _syncService.deleteAccountLocalOnly(accountId);
      setState(() {
        currentOTPs.remove(accountId);
        timers.remove(accountId);
        blurredCodes.remove(accountId);
      });
      _showSnackBar('Account removed from this device', Colors.orange);
    } else if (choice == 'everywhere') {
      _showSnackBar('Deleting everywhere…', Colors.grey);
      final ok = await _syncService.deleteAccountEverywhere(accountId);
      if (ok) {
        setState(() {
          currentOTPs.remove(accountId);
          timers.remove(accountId);
          blurredCodes.remove(accountId);
        });
        _showSnackBar('Account deleted everywhere', Colors.red);
      } else {
        _showSnackBar('Failed to delete from cloud – try again', Colors.red);
      }
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
              width: 36, height: 36,
              decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: color)),
                  Text(subtitle, style: TextStyle(fontSize: 11, color: color.withOpacity(0.7))),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: color.withOpacity(0.5), size: 18),
          ],
        ),
      ),
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────
  String _formatOtp(String otp) {
    if (otp.length == 6) return '${otp.substring(0, 3)} ${otp.substring(3)}';
    return otp;
  }

  Widget _accountAction(IconData icon, String label, VoidCallback onTap, bool isDark, {bool destructive = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: destructive ? Colors.red.withOpacity(0.08)
              : (isDark ? Colors.white.withOpacity(0.06) : Colors.grey[50]),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: destructive ? Colors.red.withOpacity(0.2)
                : (isDark ? Colors.white12 : Colors.grey[200]!),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15,
                color: destructive ? Colors.red : (isDark ? Colors.white60 : Colors.grey[600])),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                color: destructive ? Colors.red : (isDark ? Colors.white60 : Colors.grey[600]))),
          ],
        ),
      ),
    );
  }

  IconData _getServiceIcon(String service) {
    final lower = service.toLowerCase();
    if (lower.contains('google')) return Icons.g_mobiledata_rounded;
    if (lower.contains('github')) return Icons.code_rounded;
    if (lower.contains('facebook')) return Icons.facebook_rounded;
    if (lower.contains('twitter') || lower.contains('x.com')) return Icons.alternate_email_rounded;
    if (lower.contains('microsoft')) return Icons.window_rounded;
    if (lower.contains('amazon') || lower.contains('aws')) return Icons.cloud_rounded;
    if (lower.contains('apple')) return Icons.apple_rounded;
    if (lower.contains('discord')) return Icons.headset_rounded;
    if (lower.contains('slack')) return Icons.message_rounded;
    if (lower.contains('dropbox')) return Icons.folder_rounded;
    if (lower.contains('instagram')) return Icons.camera_alt_rounded;
    return Icons.lock_rounded;
  }

  void _copyToClipboard(String otp) async {
    await Clipboard.setData(ClipboardData(text: otp.replaceAll(' ', '')));
    _showSnackBar('Copied to clipboard', const Color(0xFF10B981));
  }

  void _syncData() async {
    // Check if sync is enabled first
    final syncEnabled = await _syncService.isSyncEnabled();
    
    if (!syncEnabled) {
      _showSnackBar('Sync is disabled. Enable it in Settings → Sync to Cloud', Colors.orange);
      return;
    }
    
    setState(() => _isSyncing = true);
    try {
      final success = await _syncService.syncAccounts();
      setState(() => _isSyncing = false);
      if (success) {
        await _initUserBox();
        _updateAllOTPs();
        _showSnackBar('Sync completed!', Colors.green);
      } else {
        _showSnackBar('No internet or server unavailable', Colors.orange);
      }
    } catch (e) {
      setState(() => _isSyncing = false);
      _showSnackBar('Sync failed', Colors.red);
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(color == Colors.green || color == const Color(0xFF10B981)
            ? Icons.check_circle_rounded : Icons.info_rounded,
            color: Colors.white, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ]),
      backgroundColor: color,
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Logout'),
        content: const Text('Your codes will remain saved on this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4F46E5), foregroundColor: Colors.white),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _syncService.logout();
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => LoginScreen()));
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }
}