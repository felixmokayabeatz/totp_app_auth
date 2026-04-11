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
    
    // ENFORCE MINIMUM WINDOW SIZE
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
          icon: Icon(Icons.add, color: Colors.white),
          label: Text('Add Account', style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.white.withOpacity(0.2),
          elevation: 0,
        ),
      ),
    );
  }
  
  Widget _buildHeader(bool isDark) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Authenticator',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Text(
                'Secure 2FA Codes',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
          Row(
            children: [
              _buildIconButton(Icons.sync, () => _syncData()),
              _buildIconButton(Icons.settings, () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SettingsScreen()),
              )),
              _buildIconButton(
                isDark ? Icons.light_mode : Icons.dark_mode,
                () => Provider.of<ThemeProvider>(context, listen: false).toggleTheme(),
              ),
              _buildIconButton(Icons.logout, () => _logout()),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildIconButton(IconData icon, VoidCallback onPressed) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: 22),
      onPressed: onPressed,
      padding: EdgeInsets.all(8),
      constraints: BoxConstraints(),
    );
  }
  
  Widget _buildSearchBar() {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(30),
      ),
      child: TextField(
        style: TextStyle(color: Colors.white, fontSize: 14),
        onChanged: (value) {
          setState(() {
            _searchQuery = value.toLowerCase();
          });
        },
        decoration: InputDecoration(
          hintText: 'Search accounts...',
          hintStyle: TextStyle(color: Colors.white60, fontSize: 14),
          prefixIcon: Icon(Icons.search, color: Colors.white70, size: 20),
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
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
            Icon(Icons.qr_code_2, size: 80, color: Colors.white.withOpacity(0.5)),
            SizedBox(height: 16),
            Text('No accounts yet', style: TextStyle(fontSize: 18, color: Colors.white70)),
            SizedBox(height: 8),
            Text('Tap + to add your first account', style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      );
    }
    
    return ListView.builder(
      padding: EdgeInsets.all(12),
      itemCount: accounts.length,
      itemBuilder: (context, index) {
        final account = accounts[index];
        final otp = currentOTPs[account.id] ?? '------';
        final timer = timers[account.id] ?? 30;
        final progress = timer / 30;
        
        return Container(
          margin: EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.2)),
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
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(_getServiceIcon(account.service), color: Colors.white, size: 24),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(account.service, 
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (account.issuer != null)
                            Text(account.issuer!, 
                                style: TextStyle(fontSize: 11, color: Colors.white70),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [Colors.white.withOpacity(0.2), Colors.white.withOpacity(0.1)]),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(otp,
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 2)),
                    ),
                  ],
                ),
                SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: progress,
                          backgroundColor: Colors.white.withOpacity(0.2),
                          valueColor: AlwaysStoppedAnimation<Color>(timer < 5 ? Colors.red : Color(0xFF4CAF50)),
                          minHeight: 4,
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    SizedBox(width: 35, child: Text('${timer}s', style: TextStyle(color: timer < 5 ? Colors.red : Colors.white70, fontSize: 12))),
                    _buildActionButton(Icons.copy, () => _copyToClipboard(otp)),
                    _buildActionButton(Icons.qr_code, () => Navigator.push(context, MaterialPageRoute(builder: (_) => ShowQRScreen(secret: account.secret, service: account.service, issuer: account.issuer)))),
                    _buildActionButton(Icons.delete_outline, () => _deleteAccount(account.id)),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
  
  Widget _buildActionButton(IconData icon, VoidCallback onPressed) {
    return IconButton(
      icon: Icon(icon, color: Colors.white70, size: 18),
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints(),
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
    return Icons.security;
  }
  
  void _copyToClipboard(String otp) async {
    await Clipboard.setData(ClipboardData(text: otp));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('✓ Copied!'), backgroundColor: Colors.green, duration: Duration(seconds: 1), behavior: SnackBarBehavior.floating, width: 100));
  }
  
  void _deleteAccount(String id) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text('Delete Account'),
      content: Text('Are you sure you want to delete this account?'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel')), TextButton(onPressed: () => Navigator.pop(context, true), child: Text('Delete', style: TextStyle(color: Colors.red)))],
    ));
    if (confirmed == true) {
      await Hive.box<OTPAccount>('otp_accounts').delete(id);
      setState(() { currentOTPs.remove(id); timers.remove(id); });
    }
  }
  
  void _syncData() async {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Syncing...'), duration: Duration(seconds: 1)));
    await _syncService.syncAccounts();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sync completed!'), backgroundColor: Colors.green));
  }
  
  void _logout() async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text('Logout'),
      content: Text('Are you sure you want to logout?'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel')), TextButton(onPressed: () => Navigator.pop(context, true), child: Text('Logout', style: TextStyle(color: Colors.red)))],
    ));
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