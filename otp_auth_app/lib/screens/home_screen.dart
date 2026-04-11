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
  bool _hasInternetError = false;
  String? _profilePhotoUrl;
  String? _username;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 500),
    );
    _animationController.forward();
    _startTimer();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _username = prefs.getString('current_user') ?? 'User';
    });
    
    final profile = await _profileService.getProfile();
    if (profile != null && mounted) {
      setState(() {
        _profilePhotoUrl = profile['profile']?['profile_photo'];
      });
    }
  }

  void _startTimer() {
    Future.delayed(Duration(seconds: 1), () {
      if (mounted) {
        _updateAllOTPs();
        _startTimer();
      }
    });
  }

  void _updateAllOTPs() async {
    final otpBox = Hive.box<OTPAccount>('otp_accounts');
    final newOTPs = <String, String>{};
    final newTimers = <String, int>{};
    final userId = await _getUserId();

    for (var account in otpBox.values) {
      final secret = account.getSecret(userId);
      newOTPs[account.id] = await _otpService.generateOTP(secret);
      newTimers[account.id] = 30 - (DateTime.now().second % 30);
      if (!blurredCodes.containsKey(account.id)) {
        blurredCodes[account.id] = false;
      }
    }

    if (mounted) {
      setState(() {
        currentOTPs = newOTPs;
        timers = newTimers;
      });
    }
  }

  Future<String> _getUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('current_user') ?? 'default_user';
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
      backgroundColor: isDark ? Color(0xFF0F0F1A) : Color(0xFFF0F2FF),
      body: Column(
        children: [
          _buildHeader(isDark),
          _buildSearchBar(isDark),
          Expanded(child: _buildAccountsList(isDark)),
        ],
      ),
    );
  }

  Widget _buildHeader(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Color(0xFF1A1A2E) : Color(0xFF4F46E5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 12, 16),
          child: Row(
            children: [
              // Profile Photo - Clickable to go to Profile Settings
              GestureDetector(
                onTap: () async {
                  final result = await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => ProfileScreen()),
                  );
                  if (result == true) {
                    _loadProfileData();
                  }
                },
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withOpacity(0.3),
                      width: 2,
                    ),
                  ),
                  child: ClipOval(
                    child: _profilePhotoUrl != null && _profilePhotoUrl!.isNotEmpty
                        ? Image.network(
                            'http://localhost:8000$_profilePhotoUrl',
                            fit: BoxFit.cover,
                            width: 44,
                            height: 44,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                color: Colors.white.withOpacity(0.2),
                                child: Icon(
                                  Icons.person,
                                  color: Colors.white,
                                  size: 24,
                                ),
                              );
                            },
                          )
                        : Container(
                            color: Colors.white.withOpacity(0.2),
                            child: Icon(
                              Icons.person,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                  ),
                ),
              ),
              SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'BeatzLock Authenticator',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.3,
                    ),
                  ),
                  Text(
                    _username ?? 'Two-Factor Security',
                    style: TextStyle(fontSize: 11, color: Colors.white60),
                  ),
                ],
              ),
              Spacer(),
              _headerAction(
                _allBlurred ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                _toggleBlurAll,
                tooltip: _allBlurred ? 'Show codes' : 'Hide codes',
              ),
              _headerAction(
                Icons.sync_rounded,
                _syncData,
                tooltip: 'Sync',
                loading: _isSyncing,
              ),
              _headerAction(
                Icons.settings_rounded,
                () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen())),
                tooltip: 'Settings',
              ),
              _headerAction(
                isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                () => Provider.of<ThemeProvider>(context, listen: false).toggleTheme(),
                tooltip: 'Toggle theme',
              ),
              _headerAction(
                Icons.logout_rounded,
                _logout,
                tooltip: 'Logout',
              ),
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
          width: 40,
          height: 40,
          margin: EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: loading
              ? Padding(
                  padding: EdgeInsets.all(10),
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    return Container(
      margin: EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: isDark ? Color(0xFF1E1E32) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              style: TextStyle(
                color: isDark ? Colors.white : Color(0xFF1A1A2E),
                fontSize: 14,
              ),
              onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
              decoration: InputDecoration(
                hintText: 'Search accounts…',
                hintStyle: TextStyle(color: isDark ? Colors.white38 : Colors.grey[400], fontSize: 14),
                prefixIcon: Icon(Icons.search_rounded, color: isDark ? Colors.white38 : Colors.grey[400], size: 20),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          GestureDetector(
            onTap: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => AddAccountScreen()),
              );
              if (result == true) _updateAllOTPs();
            },
            child: Container(
              margin: EdgeInsets.only(right: 8),
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Color(0xFF4F46E5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, color: Colors.white, size: 18),
                  SizedBox(width: 4),
                  Text(
                    'Add',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountsList(bool isDark) {
    final otpBox = Hive.box<OTPAccount>('otp_accounts');
    var accounts = otpBox.values.toList();

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
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: isDark ? Color(0xFF1E1E32) : Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 20),
                ],
              ),
              child: Icon(Icons.security_rounded, size: 40, color: Color(0xFF4F46E5)),
            ),
            SizedBox(height: 20),
            Text(
              'No accounts yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : Color(0xFF1A1A2E),
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Tap Add to get started',
              style: TextStyle(color: isDark ? Colors.white38 : Colors.grey[500], fontSize: 13),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: accounts.length,
      itemBuilder: (context, index) {
        final account = accounts[index];
        final otp = currentOTPs[account.id] ?? '------';
        final timer = timers[account.id] ?? 30;
        final isBlurred = blurredCodes[account.id] ?? false;
        final isExpiring = timer <= 5;

        return AnimatedContainer(
          duration: Duration(milliseconds: 300),
          margin: EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: isDark ? Color(0xFF1E1E32) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isExpiring
                  ? Colors.red.withOpacity(0.4)
                  : (isDark ? Colors.white.withOpacity(0.06) : Colors.transparent),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.2 : 0.06),
                blurRadius: 12,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Color(0xFF4F46E5).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _getServiceIcon(account.service),
                        color: Color(0xFF4F46E5),
                        size: 22,
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            account.service,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white : Color(0xFF1A1A2E),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (account.issuer != null)
                            Text(
                              account.issuer!,
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? Colors.white38 : Colors.grey[500],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: isExpiring
                                ? Colors.red.withOpacity(0.1)
                                : Color(0xFF4F46E5).withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            isBlurred ? '●●● ●●●' : _formatOtp(otp),
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: isExpiring
                                  ? Colors.red
                                  : (isDark ? Colors.white : Color(0xFF1A1A2E)),
                              letterSpacing: 3,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '${timer}s',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: isExpiring ? Colors.red : (isDark ? Colors.white38 : Colors.grey[500]),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: timer / 30,
                    backgroundColor: isDark ? Colors.white10 : Colors.grey[100],
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isExpiring ? Colors.red : Color(0xFF4F46E5),
                    ),
                    minHeight: 4,
                  ),
                ),
                SizedBox(height: 12),
                Row(
                  children: [
                    _accountAction(
                      Icons.copy_rounded,
                      'Copy',
                      () => _copyToClipboard(otp),
                      isDark,
                    ),
                    SizedBox(width: 8),
                    _accountAction(
                      isBlurred ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                      isBlurred ? 'Show' : 'Hide',
                      () => setState(() => blurredCodes[account.id] = !isBlurred),
                      isDark,
                    ),
                    SizedBox(width: 8),
                    _accountAction(
                      Icons.qr_code_rounded,
                      'QR',
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ShowQRScreen(
                            secret: account.secret,
                            service: account.service,
                            issuer: account.issuer,
                          ),
                        ),
                      ),
                      isDark,
                    ),
                    Spacer(),
                    _accountAction(
                      Icons.delete_outline_rounded,
                      'Delete',
                      () => _deleteAccount(account.id),
                      isDark,
                      destructive: true,
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

  String _formatOtp(String otp) {
    if (otp.length == 6) return '${otp.substring(0, 3)} ${otp.substring(3)}';
    return otp;
  }

  Widget _accountAction(IconData icon, String label, VoidCallback onTap, bool isDark, {bool destructive = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: destructive
              ? Colors.red.withOpacity(0.08)
              : (isDark ? Colors.white.withOpacity(0.06) : Colors.grey[50]),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: destructive
                ? Colors.red.withOpacity(0.2)
                : (isDark ? Colors.white12 : Colors.grey[200]!),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: destructive ? Colors.red : (isDark ? Colors.white60 : Colors.grey[600]),
            ),
            SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: destructive ? Colors.red : (isDark ? Colors.white60 : Colors.grey[600]),
              ),
            ),
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
        SizedBox(width: 8),
        Text('Copied to clipboard'),
      ]),
      backgroundColor: Color(0xFF10B981),
      duration: Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _deleteAccount(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Delete Account'),
        content: Text('This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await Hive.box<OTPAccount>('otp_accounts').delete(id);
      setState(() {
        currentOTPs.remove(id);
        timers.remove(id);
        blurredCodes.remove(id);
      });
    }
  }

  void _syncData() async {
    setState(() => _isSyncing = true);
    
    try {
      final success = await _syncService.syncAccounts();
      
      setState(() => _isSyncing = false);
      
      if (success) {
        _showSnackBar('Sync completed!', Colors.green);
        setState(() => _hasInternetError = false);
      } else {
        _showSnackBar('No internet connection or server unavailable', Colors.orange);
        setState(() => _hasInternetError = true);
      }
    } catch (e) {
      setState(() => _isSyncing = false);
      _showSnackBar('Sync failed: ${e.toString().substring(0, 50)}...', Colors.red);
      setState(() => _hasInternetError = true);
    }
  }
  
  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(
        children: [
          Icon(
            color == Colors.green ? Icons.check_circle_rounded : Icons.error_rounded,
            color: Colors.white,
            size: 20,
          ),
          SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
      backgroundColor: color,
      duration: Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Logout'),
        content: Text('Your codes will remain saved on this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Color(0xFF4F46E5), foregroundColor: Colors.white),
            child: Text('Logout'),
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