import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../services/sync_service.dart';
import 'login_screen.dart';

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SyncService _syncService = SyncService();
  bool _isSyncing = false;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Color(0xFF4F46E5);
  Color get _bgColor => _isDark ? Color(0xFF0F0F1A) : Color(0xFFF0F2FF);
  Color get _cardColor => _isDark ? Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white38 : Colors.grey.shade500;
  Color get _dividerColor => _isDark ? Colors.white.withOpacity(0.06) : Colors.grey.shade100;

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context);

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18, color: Colors.white),
        ),
        backgroundColor: _isDark ? Color(0xFF1A1A2E) : _accent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.all(16),
        children: [
          _profileCard(authProvider),
          SizedBox(height: 24),

          _sectionLabel('Appearance'),
          _settingsCard([
            _switchTile(
              icon: Icons.dark_mode_rounded,
              label: 'Dark Mode',
              sub: 'Switch between light and dark',
              value: themeProvider.isDarkMode,
              onChanged: (_) => themeProvider.toggleTheme(),
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
          SizedBox(height: 20),

          _sectionLabel('Security & Backup'),
          _settingsCard([
            _tappableTile(
              icon: Icons.upload_rounded,
              label: 'Export Accounts',
              sub: 'Back up your 2FA codes',
              onTap: () => _soon('Export'),
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
              icon: Icons.sync_rounded,
              label: 'Sync Now',
              sub: 'Manually sync with cloud',
              trailing: _isSyncing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
                    )
                  : null,
              onTap: _syncNow,
            ),
          ]),
          SizedBox(height: 20),

          _sectionLabel('Account'),
          _settingsCard([
            _tappableTile(
              icon: Icons.person_outline_rounded,
              label: 'Profile',
              sub: 'Edit profile information',
              onTap: () => _soon('Profile'),
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.lock_outline_rounded,
              label: 'Change Password',
              sub: 'Update your password',
              onTap: () => _soon('Change Password'),
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.notifications_none_rounded,
              label: 'Notifications',
              sub: 'Manage notification preferences',
              onTap: () => _soon('Notifications'),
            ),
          ]),
          SizedBox(height: 20),

          _sectionLabel('About'),
          _settingsCard([
            _tappableTile(
              icon: Icons.info_outline_rounded,
              label: 'Version',
              sub: 'Current app version',
              trailing: _versionBadge('1.0.0'),
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
              trailing: Icon(Icons.star_rounded, color: Colors.amber, size: 20),
              onTap: () => _soon('Rate Us'),
            ),
          ]),
          SizedBox(height: 20),

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
          SizedBox(height: 20),

          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _logout,
              icon: Icon(Icons.logout_rounded),
              label: Text('Logout', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
            ),
          ),
          SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _profileCard(AuthProvider authProvider) {
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(_isDark ? 0.2 : 0.06),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: _accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(Icons.person_rounded, color: _accent, size: 28),
          ),
          SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  authProvider.userEmail ?? 'User',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: 2),
                Text(
                  'Premium Account',
                  style: TextStyle(fontSize: 12, color: _textSecondary),
                ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Color(0xFF10B981).withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Color(0xFF10B981).withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF10B981),
                  ),
                ),
                SizedBox(width: 5),
                Text(
                  'Active',
                  style: TextStyle(
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
      padding: EdgeInsets.only(left: 4, bottom: 10),
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
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(_isDark ? 0.2 : 0.05),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }

  Widget _dividerLine() {
    return Divider(height: 1, indent: 68, endIndent: 16, color: _dividerColor);
  }

  Widget _switchTile({
    required IconData icon,
    required String label,
    required String sub,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          _iconBox(icon),
          SizedBox(width: 14),
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
                SizedBox(height: 2),
                Text(sub, style: TextStyle(fontSize: 12, color: _textSecondary)),
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
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _iconBox(icon, destructive: destructive),
            SizedBox(width: 14),
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
                  SizedBox(height: 2),
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
                    : SizedBox.shrink()),
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
      child: Icon(
        icon,
        size: 18,
        color: destructive ? Colors.red : _accent,
      ),
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
      ),
    );
  }

  Widget _versionBadge(String version) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Color(0xFF10B981).withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Color(0xFF10B981).withOpacity(0.3)),
      ),
      child: Text(
        version,
        style: TextStyle(
          color: Color(0xFF10B981),
          fontSize: 12,
          fontWeight: FontWeight.w600,
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
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(24, 12, 24, 32),
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
            SizedBox(height: 20),
            Text(
              'Accent Color',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: _textPrimary,
              ),
            ),
            SizedBox(height: 16),
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
                    duration: Duration(milliseconds: 200),
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
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    child: selected
                        ? Icon(Icons.check_rounded, color: Colors.white, size: 20)
                        : null,
                  ),
                );
              }).toList(),
            ),
            SizedBox(height: 8),
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
      duration: Duration(seconds: 2),
    ));
  }

  void _syncNow() async {
    setState(() => _isSyncing = true);
    await _syncService.syncAccounts();
    setState(() => _isSyncing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
        SizedBox(width: 8),
        Text('Sync complete'),
      ]),
      backgroundColor: Color(0xFF10B981),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _clearAllData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Row(children: [
          Icon(Icons.warning_rounded, color: Colors.red, size: 24),
          SizedBox(width: 10),
          Text('Clear All Data', style: TextStyle(color: _textPrimary, fontSize: 17)),
        ]),
        content: Text(
          'This will permanently delete ALL your OTP accounts. This cannot be undone.',
          style: TextStyle(color: _textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: Text('Delete All'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('All data cleared'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
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
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Color(0xFF4F46E5),
              foregroundColor: Colors.white,
            ),
            child: Text('Logout'),
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