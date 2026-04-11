import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import '../models/otp_account.dart';
import '../services/otp_service.dart';
import '../services/sync_service.dart';
import '../providers/theme_provider.dart';
import 'add_account_screen.dart';
import 'settings_screen.dart';
import 'login_screen.dart';
import 'show_qr_screen.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  final OTPService _otpService = OTPService();
  final SyncService _syncService = SyncService();
  Map<String, String> currentOTPs = {};
  Map<String, int> timers = {};
  Map<String, bool> blurredCodes = {};
  late AnimationController _animationController;
  String _searchQuery = '';
  bool _isSyncing = false;
  
  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 500),
    );
    _animationController.forward();
    _startTimer();
  }
  
  void _startTimer() {
    Future.delayed(Duration(seconds: 1), () {
      if (mounted) {
        _updateAllOTPs();
        _startTimer();
      }
    });
  }
  
  void _updateAllOTPs() {
    final otpBox = Hive.box<OTPAccount>('otp_accounts');
    final newOTPs = <String, String>{};
    final newTimers = <String, int>{};
    
    for (var account in otpBox.values) {
      newOTPs[account.id] = _otpService.generateOTP(account.secret);
      newTimers[account.id] = 30 - (DateTime.now().second % 30);
      if (!blurredCodes.containsKey(account.id)) {
        blurredCodes[account.id] = false;
      }
    }
    
    setState(() {
      currentOTPs = newOTPs;
      timers = newTimers;
    });
  }
  
  void _toggleBlurAll() {
    final allBlurred = blurredCodes.isNotEmpty && blurredCodes.values.every((blurred) => blurred == true);
    setState(() {
      for (var key in blurredCodes.keys) {
        blurredCodes[key] = !allBlurred;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(allBlurred ? '🔓 Codes visible' : '🔒 Codes hidden'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.isDarkMode;
    
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: 900,
        minHeight: 700,
      ),
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [Color(0xFF1a1a2e), Color(0xFF16213e)]
                  : [Color(0xFF667eea), Color(0xFF764ba2)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                _buildHeader(isDark),
                _buildSearchBar(),
                Expanded(
                  child: _buildAccountsList(),
                ),
              ],
            ),
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final result = await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => AddAccountScreen()),
            );
            if (result == true) {
              _updateAllOTPs();
            }
          },
          icon: Icon(Icons.add, color: Colors.white, size: 28),
          label: Text('Add Account', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          backgroundColor: Colors.white.withOpacity(0.2),
          elevation: 0,
        ),
      ),
    );
  }
  
  Widget _buildHeader(bool isDark) {
    final allBlurred = blurredCodes.isNotEmpty && blurredCodes.values.every((blurred) => blurred == true);
    
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 20, 24, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Authenticator',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1,
                ),
              ),
              Text(
                'Secure 2FA Codes',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
          Row(
            children: [
              _buildIconButton(
                allBlurred ? Icons.visibility : Icons.visibility_off,
                () => _toggleBlurAll(),
                allBlurred ? "Show Codes" : "Hide Codes",
              ),
              _buildIconButton(Icons.sync, () => _syncData(), "Sync", isSyncing: _isSyncing),
              _buildIconButton(Icons.settings, () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SettingsScreen()),
              ), "Settings"),
              _buildIconButton(
                isDark ? Icons.light_mode : Icons.dark_mode,
                () => Provider.of<ThemeProvider>(context, listen: false).toggleTheme(),
                "Theme",
              ),
              _buildIconButton(Icons.logout, () => _logout(), "Logout"),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildIconButton(IconData icon, VoidCallback onPressed, String tooltip, {bool isSyncing = false}) {
    return Tooltip(
      message: tooltip,
      child: Container(
        margin: EdgeInsets.only(left: 4),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: IconButton(
          icon: isSyncing 
              ? SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Icon(icon, color: Colors.white, size: 24),
          onPressed: onPressed,
          padding: EdgeInsets.all(10),
          constraints: BoxConstraints(),
        ),
      ),
    );
  }
  
  Widget _buildSearchBar() {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(30),
      ),
      child: TextField(
        style: TextStyle(color: Colors.white, fontSize: 15),
        onChanged: (value) {
          setState(() {
            _searchQuery = value.toLowerCase();
          });
        },
        decoration: InputDecoration(
          hintText: 'Search accounts...',
          hintStyle: TextStyle(color: Colors.white60, fontSize: 15),
          prefixIcon: Icon(Icons.search, color: Colors.white70, size: 22),
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        ),
      ),
    );
  }
  
  Widget _buildAccountsList() {
    final otpBox = Hive.box<OTPAccount>('otp_accounts');
    var accounts = otpBox.values.toList();
    
    if (_searchQuery.isNotEmpty) {
      accounts = accounts.where((account) =>
        account.service.toLowerCase().contains(_searchQuery) ||
        (account.issuer?.toLowerCase().contains(_searchQuery) ?? false)
      ).toList();
    }
    
    if (accounts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.qr_code_2, size: 100, color: Colors.white.withOpacity(0.5)),
            SizedBox(height: 20),
            Text('No accounts yet', style: TextStyle(fontSize: 20, color: Colors.white70, fontWeight: FontWeight.w500)),
            SizedBox(height: 10),
            Text('Tap + to add your first account', style: TextStyle(color: Colors.white54, fontSize: 14)),
          ],
        ),
      );
    }
    
    return ListView.builder(
      padding: EdgeInsets.all(16),
      itemCount: accounts.length,
      itemBuilder: (context, index) {
        final account = accounts[index];
        final otp = currentOTPs[account.id] ?? '------';
        final timer = timers[account.id] ?? 30;
        final progress = timer / 30;
        final isBlurred = blurredCodes[account.id] ?? false;
        
        return TweenAnimationBuilder(
          tween: Tween<double>(begin: 0, end: 1),
          duration: Duration(milliseconds: 300 + (index * 50)),
          builder: (context, value, child) {
            return Transform.translate(
              offset: Offset(0, 20 * (1 - value)),
              child: Opacity(
                opacity: value,
                child: Container(
                  margin: EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.2)),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              // Service Icon
                              Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.white.withOpacity(0.3),
                                      Colors.white.withOpacity(0.1),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Icon(_getServiceIcon(account.service), color: Colors.white, size: 32),
                              ),
                              SizedBox(width: 16),
                              
                              // Service Name
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      account.service, 
                                      style: TextStyle(
                                        fontSize: 18, 
                                        fontWeight: FontWeight.bold, 
                                        color: Colors.white
                                      ),
                                      maxLines: 1, 
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (account.issuer != null)
                                      Text(
                                        account.issuer!, 
                                        style: TextStyle(
                                          fontSize: 13, 
                                          color: Colors.white70
                                        ),
                                        maxLines: 1, 
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),
                              
                              // OTP Code with Live Badge
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  // Live Badge
                                  Container(
                                    margin: EdgeInsets.only(bottom: 6),
                                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: timer < 5 ? Colors.red : Color(0xFF4CAF50),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 6,
                                          height: 6,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Colors.white,
                                          ),
                                        ),
                                        SizedBox(width: 4),
                                        Text(
                                          'LIVE',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 8,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // OTP Code with Wiggle Animation
                                  _buildOtpWithWiggle(otp, isBlurred, timer),
                                ],
                              ),
                            ],
                          ),
                          
                          SizedBox(height: 16),
                          
                          // Progress Bar
                          Row(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    backgroundColor: Colors.white.withOpacity(0.2),
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      timer < 5 ? Colors.red : Color(0xFF4CAF50),
                                    ),
                                    minHeight: 8,
                                  ),
                                ),
                              ),
                              SizedBox(width: 12),
                              Container(
                                width: 45,
                                child: Text(
                                  '${timer}s',
                                  style: TextStyle(
                                    color: timer < 5 ? Colors.red : Colors.white70,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                          
                          SizedBox(height: 12),
                          
                          // Action Buttons
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              _buildActionButton(Icons.copy, 'Copy OTP', () => _copyToClipboard(otp)),
                              SizedBox(width: 8),
                              _buildActionButton(Icons.qr_code, 'Show QR', () => Navigator.push(
                                context, 
                                MaterialPageRoute(builder: (_) => ShowQRScreen(
                                  secret: account.secret, 
                                  service: account.service, 
                                  issuer: account.issuer
                                ))
                              )),
                              SizedBox(width: 8),
                              _buildActionButton(Icons.delete_outline, 'Delete', () => _deleteAccount(account.id), isDestructive: true),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
  
  Widget _buildOtpWithWiggle(String otp, bool isBlurred, int timer) {
    if (timer < 5) {
      return TweenAnimationBuilder(
        tween: Tween<double>(begin: -0.02, end: 0.02),
        duration: Duration(milliseconds: 100),
        builder: (context, value, child) {
          return Transform.rotate(
            angle: value,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.red.withOpacity(0.3),
                    Colors.red.withOpacity(0.1),
                  ],
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.red.withOpacity(0.5)),
              ),
              child: Text(
                isBlurred ? '●●●●●●' : otp,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 3,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          );
        },
      );
    }
    
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.white.withOpacity(0.2),
            Colors.white.withOpacity(0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.3)),
      ),
      child: Text(
        isBlurred ? '●●●●●●' : otp,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          letterSpacing: 3,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
  
  Widget _buildActionButton(IconData icon, String label, VoidCallback onPressed, {bool isDestructive = false}) {
    return Tooltip(
      message: label,
      child: Container(
        decoration: BoxDecoration(
          color: isDestructive 
              ? Colors.red.withOpacity(0.2)
              : Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: IconButton(
          icon: Icon(icon, color: isDestructive ? Colors.red : Colors.white70, size: 22),
          onPressed: onPressed,
          padding: EdgeInsets.all(10),
          constraints: BoxConstraints(minWidth: 40, minHeight: 40),
        ),
      ),
    );
  }
  
  IconData _getServiceIcon(String service) {
    final lower = service.toLowerCase();
    if (lower.contains('google')) return Icons.g_mobiledata;
    if (lower.contains('github')) return Icons.code;
    if (lower.contains('facebook')) return Icons.facebook;
    if (lower.contains('twitter')) return Icons.chat;
    if (lower.contains('microsoft')) return Icons.window;
    if (lower.contains('amazon')) return Icons.shopping_cart;
    if (lower.contains('apple')) return Icons.apple;
    if (lower.contains('discord')) return Icons.gamepad;
    if (lower.contains('slack')) return Icons.message;
    return Icons.security;
  }
  
  void _copyToClipboard(String otp) async {
    await Clipboard.setData(ClipboardData(text: otp));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text('OTP copied to clipboard!'),
          ],
        ),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  
  void _deleteAccount(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
            SizedBox(width: 12),
            Text('Delete Account'),
          ],
        ),
        content: Text(
          'Are you sure you want to delete this account?\n\nThis action cannot be undone and the OTP codes will be lost.',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(fontSize: 16)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text('Delete', style: TextStyle(fontSize: 16)),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Account deleted successfully'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
  
  void _syncData() async {
    setState(() {
      _isSyncing = true;
    });
    
    await _syncService.syncAccounts();
    
    setState(() {
      _isSyncing = false;
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text('Sync completed!'),
          ],
        ),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  
  void _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.logout, color: Color(0xFF667eea), size: 28),
            SizedBox(width: 12),
            Text('Logout'),
          ],
        ),
        content: Text('Are you sure you want to logout?\n\nYour OTP codes will remain saved on this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(fontSize: 16)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Color(0xFF667eea),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text('Logout', style: TextStyle(fontSize: 16)),
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