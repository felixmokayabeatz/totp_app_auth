import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../services/sync_service.dart';
import 'login_screen.dart';
import 'profile_screen.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/otp_account.dart';

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
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
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
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ProfileScreen()),
                );
              },
            ),
            _dividerLine(),
            _tappableTile(
              icon: Icons.lock_outline_rounded,
              label: 'Change Password',
              sub: 'Update your password',
              onTap: () => _showChangePasswordDialog(),
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

  void _showChangePasswordDialog() {
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    bool _obscureCurrent = true;
    bool _obscureNew = true;
    bool _obscureConfirm = true;
    bool _show2FA = false;
    String _otpCode = '';
    double _passwordStrength = 0.0;
    String _passwordStrengthText = '';
    Color _passwordStrengthColor = Colors.grey;
    double _passwordLength = 16;

    void _checkPasswordStrength() {
      final password = newPasswordController.text;
      if (password.isEmpty) {
        setState(() {
          _passwordStrength = 0.0;
          _passwordStrengthText = '';
          _passwordStrengthColor = Colors.grey;
        });
        return;
      }
      
      int score = 0;
      if (password.length >= 12) score += 25;
      else if (password.length >= 8) score += 15;
      if (password.contains(RegExp(r'[0-9]'))) score += 25;
      if (password.contains(RegExp(r'[A-Z]'))) score += 25;
      if (password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>_+=\[\]\\;/-]'))) score += 25;
      
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

    String _generateStrongPassword(int length) {
      const uppercase = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
      const lowercase = 'abcdefghijkmnopqrstuvwxyz';
      const numbers = '23456789';
      const symbols = r'!@#$%^&*()_+-=[]{}|;:,.<>?';
      
      String password = '';
      final random = DateTime.now().millisecondsSinceEpoch;
      
      password += uppercase[random % uppercase.length];
      password += lowercase[(random + 1) % lowercase.length];
      password += numbers[(random + 2) % numbers.length];
      password += symbols[(random + 3) % symbols.length];
      
      final allChars = uppercase + lowercase + numbers + symbols;
      for (int i = password.length; i < length; i++) {
        final randomIndex = (random + i) % allChars.length;
        password += allChars[randomIndex];
      }
      
      List<String> chars = password.split('');
      for (int i = chars.length - 1; i > 0; i--) {
        final j = (random + i) % (i + 1);
        final temp = chars[i];
        chars[i] = chars[j];
        chars[j] = temp;
      }
      
      return chars.join();
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text(_show2FA ? 'Verify 2FA Code' : 'Change Password'),
            content: Container(
              width: 350,
              child: _show2FA
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.email_outlined, size: 50, color: _accent),
                        SizedBox(height: 16),
                        Text(
                          'A verification code has been sent to your email',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: _textSecondary),
                        ),
                        SizedBox(height: 20),
                        Container(
                          decoration: BoxDecoration(
                            color: _isDark ? Colors.white12 : Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _accent.withOpacity(0.3)),
                          ),
                          child: TextField(
                            onChanged: (value) => _otpCode = value,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 24, letterSpacing: 4, fontWeight: FontWeight.bold),
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            decoration: InputDecoration(
                              hintText: '000000',
                              hintStyle: TextStyle(fontSize: 24, letterSpacing: 4),
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
                        // Current Password
                        Container(
                          decoration: BoxDecoration(
                            color: _isDark ? Colors.white12 : Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _accent.withOpacity(0.3)),
                          ),
                          child: TextField(
                            controller: currentPasswordController,
                            obscureText: _obscureCurrent,
                            decoration: InputDecoration(
                              labelText: 'Current Password',
                              labelStyle: TextStyle(color: _textSecondary),
                              prefixIcon: Icon(Icons.lock_outline, color: _accent),
                              suffixIcon: IconButton(
                                icon: Icon(_obscureCurrent ? Icons.visibility_off : Icons.visibility, color: _textSecondary),
                                onPressed: () => setState(() => _obscureCurrent = !_obscureCurrent),
                              ),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                            ),
                          ),
                        ),
                        SizedBox(height: 16),
                        
                        // New Password
                        Container(
                          decoration: BoxDecoration(
                            color: _isDark ? Colors.white12 : Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _accent.withOpacity(0.3)),
                          ),
                          child: TextField(
                            controller: newPasswordController,
                            obscureText: _obscureNew,
                            onChanged: (_) => _checkPasswordStrength(),
                            decoration: InputDecoration(
                              labelText: 'New Password',
                              labelStyle: TextStyle(color: _textSecondary),
                              prefixIcon: Icon(Icons.lock_outline, color: _accent),
                              suffixIcon: IconButton(
                                icon: Icon(_obscureNew ? Icons.visibility_off : Icons.visibility, color: _textSecondary),
                                onPressed: () => setState(() => _obscureNew = !_obscureNew),
                              ),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                            ),
                          ),
                        ),
                        
                        // Password Strength
                        if (newPasswordController.text.isNotEmpty) ...[
                          SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: LinearProgressIndicator(
                                  value: _passwordStrength,
                                  backgroundColor: Colors.grey.shade300,
                                  valueColor: AlwaysStoppedAnimation<Color>(_passwordStrengthColor),
                                  minHeight: 4,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              SizedBox(width: 8),
                              Text(
                                _passwordStrengthText,
                                style: TextStyle(
                                  color: _passwordStrengthColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                        
                        // Password Length Slider
                        SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.format_size, size: 18, color: _accent),
                            SizedBox(width: 8),
                            Text(
                              'Length: ${_passwordLength.toInt()}',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: _accent),
                            ),
                            Expanded(
                              child: Slider(
                                value: _passwordLength,
                                min: 8,
                                max: 20,
                                divisions: 12,
                                activeColor: _accent,
                                inactiveColor: Colors.grey.shade300,
                                onChanged: (value) {
                                  setState(() {
                                    _passwordLength = value;
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                        
                        // Suggest Password Button
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () {
                              final strongPassword = _generateStrongPassword(_passwordLength.toInt());
                              setState(() {
                                newPasswordController.text = strongPassword;
                                _checkPasswordStrength();
                              });
                            },
                            icon: Icon(Icons.auto_awesome, size: 16, color: _accent),
                            label: Text(
                              'Suggest strong password',
                              style: TextStyle(fontSize: 12, color: _accent),
                            ),
                          ),
                        ),
                        
                        SizedBox(height: 8),
                        
                        // Confirm Password
                        Container(
                          decoration: BoxDecoration(
                            color: _isDark ? Colors.white12 : Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _accent.withOpacity(0.3)),
                          ),
                          child: TextField(
                            controller: confirmPasswordController,
                            obscureText: _obscureConfirm,
                            decoration: InputDecoration(
                              labelText: 'Confirm New Password',
                              labelStyle: TextStyle(color: _textSecondary),
                              prefixIcon: Icon(Icons.lock_outline, color: _accent),
                              suffixIcon: IconButton(
                                icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility, color: _textSecondary),
                                onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                              ),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Cancel', style: TextStyle(color: _textSecondary)),
              ),
              ElevatedButton(
                onPressed: _show2FA
                    ? () async {
                        if (_otpCode.length != 6) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Please enter 6-digit code'), backgroundColor: Colors.red),
                          );
                          return;
                        }
                        
                        final prefs = await SharedPreferences.getInstance();
                        final username = prefs.getString('current_user') ?? '';
                        
                        final isValid = await _syncService.verify2FACode(username, _otpCode);
                        
                        if (isValid) {
                          final changed = await _syncService.changePassword(
                            currentPasswordController.text,
                            newPasswordController.text,
                          );
                          
                          if (changed) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Password changed successfully! Please login again.'),
                                backgroundColor: Colors.green,
                              ),
                            );
                            Future.delayed(Duration(seconds: 2), () {
                              _logout();
                            });
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Failed to change password'), backgroundColor: Colors.red),
                            );
                          }
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Invalid verification code'), backgroundColor: Colors.red),
                          );
                        }
                      }
                    : () async {
                        if (currentPasswordController.text.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Please enter current password'), backgroundColor: Colors.red),
                          );
                          return;
                        }
                        if (newPasswordController.text.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Please enter new password'), backgroundColor: Colors.red),
                          );
                          return;
                        }
                        if (newPasswordController.text.length < 8) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Password must be at least 8 characters'), backgroundColor: Colors.red),
                          );
                          return;
                        }
                        if (newPasswordController.text != confirmPasswordController.text) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('New passwords do not match'), backgroundColor: Colors.red),
                          );
                          return;
                        }
                        if (_passwordStrength < 0.5) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Please use a stronger password'), backgroundColor: Colors.red),
                          );
                          return;
                        }
                        
                        final prefs = await SharedPreferences.getInstance();
                        final username = prefs.getString('current_user') ?? '';
                        
                        final sent = await _syncService.send2FACode(username, currentPasswordController.text);
                        
                        if (sent) {
                          setState(() {
                            _show2FA = true;
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('2FA code sent to your email!'), backgroundColor: Colors.green),
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Invalid current password'), backgroundColor: Colors.red),
                          );
                        }
                      },
                child: Text(_show2FA ? 'Verify & Change' : 'Send Code'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          );
        },
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
      final otpBox = Hive.box<OTPAccount>('otp_accounts');
      await otpBox.clear();
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