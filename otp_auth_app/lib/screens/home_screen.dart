import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import '../models/otp_account.dart';
import '../services/otp_service.dart';
import '../services/sync_service.dart';
import '../providers/theme_provider.dart';
import 'add_account_screen.dart';
import 'settings_screen.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  final OTPService _otpService = OTPService();
  final SyncService _syncService = SyncService();
  Map<String, String> currentOTPs = {};
  Map<String, int> timers = {};
  late AnimationController _animationController;
  String _searchQuery = '';
  
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
    }
    
    setState(() {
      currentOTPs = newOTPs;
      timers = newTimers;
    });
  }
  
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.isDarkMode;
    
    return Scaffold(
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
              _buildSearchBar(isDark),
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
        icon: Icon(Icons.add, color: Colors.white),
        label: Text('Add Account', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.white.withOpacity(0.2),
        elevation: 0,
      ),
    );
  }
  
  Widget _buildHeader(bool isDark) {
    return Container(
      padding: EdgeInsets.all(24),
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
              SizedBox(height: 4),
              Text(
                'Secure 2FA Codes',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                icon: Icon(Icons.sync, color: Colors.white),
                onPressed: () => _syncData(),
              ),
              IconButton(
                icon: Icon(Icons.settings, color: Colors.white),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SettingsScreen()),
                ),
              ),
              IconButton(
                icon: Icon(
                  isDark ? Icons.light_mode : Icons.dark_mode,
                  color: Colors.white,
                ),
                onPressed: () {
                  final tp = Provider.of<ThemeProvider>(context, listen: false);
                  tp.toggleTheme();
                },
              ),
              // LOGOUT BUTTON ADDED HERE
              IconButton(
                icon: Icon(Icons.logout, color: Colors.white),
                onPressed: () => _logout(),
                tooltip: 'Logout',
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildSearchBar(bool isDark) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(30),
      ),
      child: TextField(
        style: TextStyle(color: Colors.white),
        onChanged: (value) {
          setState(() {
            _searchQuery = value.toLowerCase();
          });
        },
        decoration: InputDecoration(
          hintText: 'Search accounts...',
          hintStyle: TextStyle(color: Colors.white70),
          prefixIcon: Icon(Icons.search, color: Colors.white70),
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: 15),
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
            Text(
              'No accounts yet',
              style: TextStyle(fontSize: 20, color: Colors.white70),
            ),
            SizedBox(height: 10),
            Text(
              'Tap + to add your first account',
              style: TextStyle(color: Colors.white54),
            ),
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
        
        return FadeTransition(
          opacity: _animationController,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0.5, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: _animationController,
              curve: Interval(index * 0.05, 1.0, curve: Curves.easeOut),
            )),
            child: Container(
              margin: EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withOpacity(0.2),
                ),
              ),
              child: Stack(
                children: [
                  Container(
                    padding: EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Icon(
                                          _getServiceIcon(account.service),
                                          color: Colors.white,
                                          size: 24,
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
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                            if (account.issuer != null)
                                              Text(
                                                account.issuer!,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.white70,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.white.withOpacity(0.2),
                                    Colors.white.withOpacity(0.1),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.3),
                                ),
                              ),
                              child: Text(
                                otp,
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  letterSpacing: 4,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: LinearProgressIndicator(
                                  value: progress,
                                  backgroundColor: Colors.white.withOpacity(0.2),
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    timer < 5 ? Colors.red : Colors.green,
                                  ),
                                  minHeight: 6,
                                ),
                              ),
                            ),
                            SizedBox(width: 12),
                            Text(
                              '${timer}s',
                              style: TextStyle(
                                color: timer < 5 ? Colors.red : Colors.white70,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(width: 8),
                            IconButton(
                              icon: Icon(Icons.copy, color: Colors.white70, size: 20),
                              onPressed: () => _copyToClipboard(otp),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline, color: Colors.white70, size: 20),
                              onPressed: () => _deleteAccount(account.id),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    right: 20,
                    top: 20,
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.fiber_manual_record, color: Colors.green, size: 8),
                          SizedBox(width: 4),
                          Text('Active', style: TextStyle(color: Colors.green, fontSize: 10)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
  
  IconData _getServiceIcon(String service) {
    final lower = service.toLowerCase();
    if (lower.contains('google')) return Icons.g_mobiledata;
    if (lower.contains('github')) return Icons.code;
    if (lower.contains('facebook')) return Icons.facebook;
    if (lower.contains('twitter')) return Icons.chat;
    if (lower.contains('microsoft') || lower.contains('outlook')) return Icons.window;
    if (lower.contains('amazon')) return Icons.shopping_cart;
    if (lower.contains('discord')) return Icons.gamepad;
    if (lower.contains('slack')) return Icons.message;
    return Icons.security;
  }
  
  void _copyToClipboard(String otp) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('OTP $otp copied!'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 1),
      ),
    );
  }
  
  void _deleteAccount(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Account'),
        content: Text('Are you sure you want to delete this account?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      final otpBox = Hive.box<OTPAccount>('otp_accounts');
      await otpBox.delete(id);
      setState(() {
        currentOTPs.remove(id);
        timers.remove(id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Account deleted!'), backgroundColor: Colors.red),
      );
    }
  }
  
  void _syncData() async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Syncing...'), duration: Duration(seconds: 1)),
    );
    await _syncService.syncAccounts();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Sync completed!'), backgroundColor: Colors.green, duration: Duration(seconds: 1)),
    );
  }
  
  void _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Logout'),
        content: Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Logout', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      await _syncService.logout();
      Navigator.pushReplacement(
        context, 
        MaterialPageRoute(builder: (_) => LoginScreen()),
      );
    }
  }
  
  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }
}