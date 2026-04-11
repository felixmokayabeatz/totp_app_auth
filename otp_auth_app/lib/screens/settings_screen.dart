import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../services/sync_service.dart';
import 'login_screen.dart';

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  final SyncService _syncService = SyncService();
  bool _isSyncing = false;
  
  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 500),
    );
    _animationController.forward();
  }
  
  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.isDarkMode;
    final authProvider = Provider.of<AuthProvider>(context);
    
    return Scaffold(
      backgroundColor: isDark ? Color(0xFF1a1a2e) : Color(0xFF667eea),
      appBar: AppBar(
        title: Text(
          'Settings',
          style: TextStyle(color: isDark ? Colors.white : Color(0xFF667eea), fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: isDark ? Colors.white : Color(0xFF667eea)),
          onPressed: () => Navigator.pop(context),
        ),
      ),
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
        child: FadeTransition(
          opacity: _animationController,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0.2, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: _animationController,
              curve: Curves.easeOut,
            )),
            child: Column(
              children: [
                // Profile Section
                Container(
                  margin: EdgeInsets.all(20),
                  padding: EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.2),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF667eea), Color(0xFF764ba2)],
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 10,
                              offset: Offset(0, 5),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.person,
                          color: Colors.white,
                          size: 30,
                        ),
                      ),
                      SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              authProvider.userEmail ?? 'User',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Premium Account',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.green),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color.fromARGB(255, 0, 255, 8),
                              ),
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Active',
                              style: TextStyle(color: const Color.fromARGB(255, 0, 255, 8), fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.symmetric(horizontal: 20),
                    children: [
                      // Appearance Section
                      _buildSectionHeader(Icons.palette, 'Appearance'),
                      _buildModernCard([
                        _buildSettingTile(
                          icon: Icons.dark_mode,
                          title: 'Dark Mode',
                          subtitle: 'Switch between light and dark theme',
                          trailing: Switch(
                            value: themeProvider.isDarkMode,
                            onChanged: (_) => themeProvider.toggleTheme(),
                            activeColor: Colors.white,
                            activeTrackColor: Color(0xFF667eea),
                          ),
                        ),
                        _buildSettingTile(
                          icon: Icons.color_lens,
                          title: 'Accent Color',
                          subtitle: 'Customize theme color',
                          trailing: Container(
                            width: 40,
                            height: 40,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Container(
                                  width: 30,
                                  height: 30,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: themeProvider.accentColor,
                                    border: Border.all(color: Colors.white, width: 2),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.2),
                                        blurRadius: 4,
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(Icons.edit, color: Colors.white, size: 14),
                              ],
                            ),
                          ),
                          onTap: () => _showColorPicker(context, themeProvider),
                        ),
                      ]),
                      
                      SizedBox(height: 20),
                      
                      // Security Section
                      _buildSectionHeader(Icons.security, 'Security'),
                      _buildModernCard([
                        _buildSettingTile(
                          icon: Icons.qr_code,
                          title: 'Export Accounts',
                          subtitle: 'Backup your 2FA codes to a file',
                          trailing: Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 16),
                          onTap: () => _exportAccounts(context),
                        ),
                        _buildSettingTile(
                          icon: Icons.qr_code_scanner,
                          title: 'Import Accounts',
                          subtitle: 'Restore from backup file',
                          trailing: Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 16),
                          onTap: () => _importAccounts(context),
                        ),
                        _buildSettingTile(
                          icon: Icons.sync,
                          title: 'Sync Now',
                          subtitle: 'Manually sync with cloud',
                          trailing: _isSyncing
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 16),
                          onTap: () => _syncNow(context),
                        ),
                      ]),
                      
                      SizedBox(height: 20),
                      
                      // Account Section
                      _buildSectionHeader(Icons.account_circle, 'Account'),
                      _buildModernCard([
                        _buildSettingTile(
                          icon: Icons.person_outline,
                          title: 'Profile',
                          subtitle: 'Edit profile information',
                          trailing: Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 16),
                          onTap: () => _showComingSoon(context, 'Profile'),
                        ),
                        _buildSettingTile(
                          icon: Icons.lock_outline,
                          title: 'Change Password',
                          subtitle: 'Update your password',
                          trailing: Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 16),
                          onTap: () => _showComingSoon(context, 'Change Password'),
                        ),
                        _buildSettingTile(
                          icon: Icons.email_outlined,
                          title: 'Email Settings',
                          subtitle: 'Manage notification preferences',
                          trailing: Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 16),
                          onTap: () => _showComingSoon(context, 'Email Settings'),
                        ),
                      ]),
                      
                      SizedBox(height: 20),
                      
                      // About Section
                      _buildSectionHeader(Icons.info, 'About'),
                      _buildModernCard([
                        _buildSettingTile(
                          icon: Icons.info_outline,
                          title: 'Version',
                          subtitle: 'Current app version',
                          trailing: Container(
                            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color.fromARGB(255, 0, 255, 8).withOpacity(0.2),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: const Color.fromARGB(255, 1, 255, 10).withOpacity(0.5)),
                            ),
                            child: Text(
                              '1.0.0',
                              style: TextStyle(color: const Color.fromARGB(255, 0, 255, 9), fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        _buildSettingTile(
                          icon: Icons.privacy_tip,
                          title: 'Privacy Policy',
                          subtitle: 'Read our privacy policy',
                          trailing: Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 16),
                          onTap: () => _showComingSoon(context, 'Privacy Policy'),
                        ),
                        _buildSettingTile(
                          icon: Icons.description,
                          title: 'Terms of Service',
                          subtitle: 'Terms and conditions',
                          trailing: Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 16),
                          onTap: () => _showComingSoon(context, 'Terms of Service'),
                        ),
                        _buildSettingTile(
                          icon: Icons.favorite,
                          title: 'Rate Us',
                          subtitle: 'Love this app? Rate it!',
                          trailing: Icon(Icons.star, color: Colors.amber, size: 20),
                          onTap: () => _showComingSoon(context, 'Rate Us'),
                        ),
                      ]),
                      
                      SizedBox(height: 20),
                      
                      // Danger Zone Section
                      _buildSectionHeader(Icons.warning_amber, 'Danger Zone'),
                      _buildModernCard([
                        _buildSettingTile(
                          icon: Icons.delete_forever,
                          title: 'Clear All Data',
                          subtitle: 'Permanently delete all accounts',
                          trailing: Icon(Icons.arrow_forward_ios, color: Colors.red, size: 16),
                          onTap: () => _clearAllData(context),
                          isDestructive: true,
                        ),
                      ]),
                      
                      SizedBox(height: 20),
                      
                      // Logout Button
                      Container(
                        margin: EdgeInsets.only(bottom: 30),
                        child: ElevatedButton.icon(
                          onPressed: () => _logout(context),
                          icon: Icon(Icons.logout, color: Colors.white, size: 20),
                          label: Text(
                            'Logout',
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            minimumSize: Size(double.infinity, 50),
                            backgroundColor: Colors.red.withOpacity(0.8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                            ),
                            elevation: 0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildSectionHeader(IconData icon, String title) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 20),
          SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildModernCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withOpacity(0.2),
        ),
      ),
      child: Column(
        children: children,
      ),
    );
  }
  
  Widget _buildSettingTile({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
    bool isDestructive = false,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Colors.white.withOpacity(0.1),
            ),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isDestructive 
                    ? Colors.red.withOpacity(0.2)
                    : Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: isDestructive ? Colors.red : Colors.white70, size: 22),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isDestructive ? Colors.red : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: isDestructive ? Colors.red.shade200 : Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }
  
  void _showColorPicker(BuildContext context, ThemeProvider themeProvider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark ? Color(0xFF1a1a2e) : Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Choose Accent Color',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black,
              ),
            ),
            SizedBox(height: 20),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: themeProvider.accentColors.asMap().entries.map((entry) {
                return GestureDetector(
                  onTap: () {
                    themeProvider.setAccentColor(entry.key);
                    Navigator.pop(context);
                    _showSuccess(context, 'Accent color changed');
                  },
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: entry.value,
                      shape: BoxShape.circle,
                      border: themeProvider.accentColorIndex == entry.key
                          ? Border.all(color: Colors.white, width: 3)
                          : null,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
            SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
  
  void _showComingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✨ $feature coming soon!'),
        backgroundColor: Color(0xFF667eea),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  
  void _showSuccess(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text(message),
          ],
        ),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  
  void _exportAccounts(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('📦 Export feature coming soon...'), duration: Duration(seconds: 2)),
    );
  }
  
  void _importAccounts(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('📥 Import feature coming soon...'), duration: Duration(seconds: 2)),
    );
  }
  
  void _syncNow(BuildContext context) async {
    setState(() {
      _isSyncing = true;
    });
    
    await _syncService.syncAccounts();
    
    setState(() {
      _isSyncing = false;
    });
    
    _showSuccess(context, 'Sync completed!');
  }
  
  void _clearAllData(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
            SizedBox(width: 12),
            Text('Clear All Data'),
          ],
        ),
        content: Text(
          '⚠️ WARNING: This will permanently delete ALL your OTP accounts.\n\nThis action cannot be undone!',
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
            child: Text('Clear All', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      // Clear all data logic here
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('All data cleared'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
  
  void _logout(BuildContext context) async {
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
      await Provider.of<AuthProvider>(context, listen: false).logout();
      await _syncService.logout();
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => LoginScreen()),
        (route) => false,
      );
    }
  }
}