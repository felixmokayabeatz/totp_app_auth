import 'package:flutter/material.dart';
import '../services/sync_service.dart';
import '../services/secure_storage_service.dart';
import '../providers/auth_provider.dart';
import 'home_screen.dart';
import 'passwordless_login_screen.dart';
import 'recover_primary_device_screen.dart';
import '../services/push_messaging_service.dart';
import '../services/server_lockdown_service.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'dart:async';

enum _PasswordlessLoginOutcome {
  approved,
  cancelled,
  fallbackToPassword,
  failed,
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.returnToPreviousOnOffline = false});

  final bool returnToPreviousOnOffline;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _otpCodeController = TextEditingController();
  final _resetEmailController = TextEditingController();
  final _resetNewPasswordController = TextEditingController();
  final _resetConfirmPasswordController = TextEditingController();
  final _resetOtpCodeController = TextEditingController();

  final SyncService _syncService = SyncService();

  bool _isLogin = true;
  bool _isLoading = false;
  bool _show2FA = false;
  bool _showForgotPassword = false;
  bool _showResetPassword = false;
  bool _useRecoveryCodeFor2FA = false;
  bool _useRecoveryCodeForReset = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _obscureResetPassword = true;
  bool _obscureResetConfirmPassword = true;
  String? _pendingLoginEmail;
  String? _resetEmail;
  double _passwordLength = 16;
  double _resetPasswordLength = 16;
  int _resendCooldown = 0;
  Timer? _resendTimer;
  int _resetResendCooldown = 0;
  Timer? _resetResendTimer;
  bool _serverLockdownEnabled = false;

  static const String _syncValueMessage =
      'You can use BeatzLock offline. Sign in only when you want automatic cross-platform sync.';


  double _passwordStrength = 0.0;
  String _passwordStrengthText = '';
  Color _passwordStrengthColor = Colors.grey;
  List<String> _passwordSuggestions = [];


  double _resetPasswordStrength = 0.0;
  String _resetPasswordStrengthText = '';
  Color _resetPasswordStrengthColor = Colors.grey;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_checkPasswordStrength);
    _resetNewPasswordController.addListener(_checkResetPasswordStrength);
    unawaited(_loadServerLockdownState());
  }

  Future<void> _loadServerLockdownState() async {
    final enabled = await ServerLockdownService().isEnabled();
    if (!mounted) return;
    setState(() {
      _serverLockdownEnabled = enabled;
    });
  }

  void _checkPasswordStrength() {
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(() {
        _passwordStrength = 0.0;
        _passwordStrengthText = '';
        _passwordStrengthColor = Colors.grey;
        _passwordSuggestions = [];
      });
      return;
    }

    int score = 0;
    List<String> suggestions = [];

    if (password.length >= 12) {
      score += 25;
    } else if (password.length >= 8) {
      score += 15;
    } else {
      suggestions.add('Use at least 8 characters (12+ recommended)');
    }

    if (password.contains(RegExp(r'[0-9]'))) {
      score += 25;
    } else {
      suggestions.add('Add a number');
    }

    if (password.contains(RegExp(r'[A-Z]'))) {
      score += 25;
    } else {
      suggestions.add('Add an uppercase letter');
    }

    if (password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>_+=\[\]\\;/-]'))) {
      score += 25;
    } else {
      suggestions.add('Add a special character (!@#\$%^&*)');
    }

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
      _passwordSuggestions = suggestions;
    });
  }

  void _checkResetPasswordStrength() {
    final password = _resetNewPasswordController.text;
    if (password.isEmpty) {
      setState(() {
        _resetPasswordStrength = 0.0;
        _resetPasswordStrengthText = '';
        _resetPasswordStrengthColor = Colors.grey;
      });
      return;
    }

    int score = 0;
    List<String> suggestions = [];

    if (password.length >= 12) {
      score += 25;
    } else if (password.length >= 8) {
      score += 15;
    } else {
      suggestions.add('Use at least 8 characters (12+ recommended)');
    }

    if (password.contains(RegExp(r'[0-9]'))) {
      score += 25;
    } else {
      suggestions.add('Add a number');
    }

    if (password.contains(RegExp(r'[A-Z]'))) {
      score += 25;
    } else {
      suggestions.add('Add an uppercase letter');
    }

    if (password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>_+=\[\]\\;/-]'))) {
      score += 25;
    } else {
      suggestions.add('Add a special character (!@#\$%^&*)');
    }

    setState(() {
      _resetPasswordStrength = score / 100;
      if (score < 50) {
        _resetPasswordStrengthText = 'Weak';
        _resetPasswordStrengthColor = Colors.red;
      } else if (score < 75) {
        _resetPasswordStrengthText = 'Medium';
        _resetPasswordStrengthColor = Colors.orange;
      } else {
        _resetPasswordStrengthText = 'Strong';
        _resetPasswordStrengthColor = Colors.green;
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

  void _suggestStrongPassword() {
    final length = _passwordLength.toInt();
    final strongPassword = _generateStrongPassword(length);
    setState(() {
      _passwordController.text = strongPassword;
      _confirmPasswordController.text = strongPassword;
      _checkPasswordStrength();
    });
    _showSuccess('Strong password generated! ($length characters)');
  }

  void _suggestResetStrongPassword() {
    final length = _resetPasswordLength.toInt();
    final strongPassword = _generateStrongPassword(length);
    setState(() {
      _resetNewPasswordController.text = strongPassword;
      _resetConfirmPasswordController.text = strongPassword;
      _checkResetPasswordStrength();
    });
    _showSuccess('Strong password generated! ($length characters)');
  }

  void _startResendTimer() {
    _resendTimer?.cancel();
    setState(() {
      _resendCooldown = 60;
    });
    _resendTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendCooldown <= 1) {
        timer.cancel();
        setState(() {
          _resendCooldown = 0;
        });
      } else {
        setState(() {
          _resendCooldown--;
        });
      }
    });
  }

  void _resend2FACode() async {
    if (_serverLockdownEnabled) {
      _showError(
        ServerLockdownService().blockedMessageFor(
          'request email verification codes',
        ),
      );
      return;
    }
    if (_resendCooldown > 0) {
      _showError('Please wait $_resendCooldown seconds before resending');
      return;
    }
    if (_pendingLoginEmail == null) {
      _showError('Session expired. Please login again.');
      return;
    }
    setState(() {
      _isLoading = true;
    });
    final sent = await _syncService.send2FACode(
      _pendingLoginEmail!,
      _passwordController.text,
    );
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
    if (sent) {
      _startResendTimer();
      _showSuccess('New 2FA code sent to your email!');
    } else {
      _showError('Failed to send code. Please try again.');
    }
  }

  void _startResetResendTimer() {
    _resetResendTimer?.cancel();
    setState(() {
      _resetResendCooldown = 60;
    });
    _resetResendTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resetResendCooldown <= 1) {
        timer.cancel();
        setState(() {
          _resetResendCooldown = 0;
        });
      } else {
        setState(() {
          _resetResendCooldown--;
        });
      }
    });
  }

  void _resendResetCode() async {
    if (_serverLockdownEnabled) {
      _showError(
        ServerLockdownService().blockedMessageFor(
          'request password reset codes',
        ),
      );
      return;
    }
    if (_resetResendCooldown > 0) {
      _showError('Please wait $_resetResendCooldown seconds before resending');
      return;
    }
    if (_resetEmail == null && _resetEmailController.text.isEmpty) {
      _showError(
        'No email address found. Please go back and enter your email again.',
      );
      return;
    }
    final email = _resetEmail ?? _resetEmailController.text;
    setState(() {
      _isLoading = true;
    });
    final sent = await _syncService.sendPasswordResetCode(email);
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
    if (sent) {
      _startResetResendTimer();
      _showSuccess('New reset code sent to your email!');
    } else {
      _showError('Failed to send code. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final accent = colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inputCardColor =
        isDark ? const Color(0xFF1E1E32) : Colors.grey.shade50;
    final inputBorderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : accent.withValues(alpha: 0.3);
    final inputLabelColor = isDark ? Colors.white70 : Colors.grey.shade700;
    final inputTextColor = isDark ? Colors.white : const Color(0xFF1A1A2E);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [accent, colorScheme.secondary],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(24),
            child: Card(
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.security, size: 80, color: accent),
                    SizedBox(height: 20),
                    Text(
                      _show2FA
                          ? 'Enter 2FA Code'
                          : (_showResetPassword
                              ? 'Reset Password'
                              : (_showForgotPassword
                                  ? 'Forgot Password'
                                  : (_isLogin
                                      ? 'Welcome to BeatzLock'
                                      : 'Create BeatzLock Account'))),
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 30),
                    if (_showForgotPassword && !_showResetPassword) ...[
                      Text(
                        'Enter your email address to reset your password',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'No email access right now? You can use a recovery code on the next step.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      SizedBox(height: 20),
                      TextFormField(
                        controller: _resetEmailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          labelText: 'Email Address',
                          prefixIcon: Icon(Icons.email),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _sendResetCode,
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: _isLoading
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                'Send Reset Code',
                                style: TextStyle(fontSize: 18),
                              ),
                      ),
                      TextButton(
                        onPressed: () async {
                          if (_resetEmailController.text.trim().isEmpty) {
                            _showError('Please enter your email address');
                            return;
                          }
                          setState(() {
                            _isLoading = true;
                          });
                          final exists =
                              await _syncService.checkRecoveryEmailExists(
                            _resetEmailController.text.trim(),
                          );
                          if (!mounted) return;
                          setState(() {
                            _isLoading = false;
                          });
                          if (!exists) {
                            _showError(
                              _syncService.lastErrorMessage ??
                                  'No account found with this email address',
                            );
                            return;
                          }
                          setState(() {
                            _resetEmail = _resetEmailController.text.trim();
                            _showResetPassword = true;
                            _useRecoveryCodeForReset = true;
                            _resetOtpCodeController.clear();
                          });
                        },
                        child: Text('Use Recovery Code Instead'),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _showForgotPassword = false;
                            _resetEmailController.clear();
                          });
                        },
                        child: Text('Back to Login'),
                      ),
                    ] else if (_showResetPassword) ...[
                      Text(
                        _useRecoveryCodeForReset
                            ? 'Use one of your 10-character recovery codes to reset your password'
                            : 'A verification code has been sent to your email',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                      SizedBox(height: 16),






                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.55),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.orange.shade700,
                              size: 22,
                            ),
                            SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Before you reset',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w800,
                                      color: inputTextColor,
                                    ),
                                  ),
                                  SizedBox(height: 5),
                                  Text(
                                    'Your synced accounts are locked with a key made from your '
                                    'current password. Resetting it does not unlock them, so '
                                    'unless you still have your recovery codes PDF, your synced '
                                    'copy cannot be opened again.\n\n'
                                    'Accounts already on a signed-in device are not affected and '
                                    'stay on that device. If you can still open BeatzLock '
                                    'anywhere, back those up before resetting.',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      height: 1.45,
                                      color: inputTextColor.withValues(
                                        alpha: 0.85,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 20),
                      TextFormField(
                        controller: _resetOtpCodeController,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 24,
                          letterSpacing: 4,
                          color: inputTextColor,
                        ),
                        keyboardType: _useRecoveryCodeForReset
                            ? TextInputType.text
                            : TextInputType.number,
                        maxLength: _useRecoveryCodeForReset ? 10 : 6,
                        decoration: InputDecoration(
                          labelText: _useRecoveryCodeForReset
                              ? 'Enter 10-character recovery code'
                              : 'Enter 6-digit code',
                          labelStyle: TextStyle(color: inputLabelColor),
                          filled: true,
                          fillColor: inputCardColor,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: inputBorderColor),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: inputBorderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: accent, width: 1.4),
                          ),
                          counterText: '',
                        ),
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(
                            _useRecoveryCodeForReset ? 10 : 6,
                          ),
                          if (_useRecoveryCodeForReset)
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[A-Za-z0-9]'),
                            )
                          else
                            FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () {
                            setState(() {
                              _useRecoveryCodeForReset =
                                  !_useRecoveryCodeForReset;
                              _resetOtpCodeController.clear();
                            });
                          },
                          child: Text(
                            _useRecoveryCodeForReset
                                ? 'Use email code instead'
                                : 'Use recovery code instead',
                          ),
                        ),
                      ),
                      SizedBox(height: 16),
                      Container(
                        decoration: BoxDecoration(
                          color: inputCardColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: inputBorderColor),
                        ),
                        child: TextField(
                          controller: _resetNewPasswordController,
                          obscureText: _obscureResetPassword,
                          onChanged: (_) => _checkResetPasswordStrength(),
                          style: TextStyle(color: inputTextColor),
                          decoration: InputDecoration(
                            labelText: 'New Password',
                            labelStyle: TextStyle(color: inputLabelColor),
                            prefixIcon: Icon(Icons.lock_outline, color: accent),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureResetPassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: Colors.grey,
                              ),
                              onPressed: () => setState(
                                () => _obscureResetPassword =
                                    !_obscureResetPassword,
                              ),
                            ),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                          ),
                        ),
                      ),
                      if (_resetNewPasswordController.text.isNotEmpty) ...[
                        SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: LinearProgressIndicator(
                                value: _resetPasswordStrength,
                                backgroundColor: Colors.grey.shade300,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  _resetPasswordStrengthColor,
                                ),
                                minHeight: 4,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            SizedBox(width: 8),
                            Text(
                              _resetPasswordStrengthText,
                              style: TextStyle(
                                color: _resetPasswordStrengthColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                      SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(Icons.format_size, size: 18, color: accent),
                          SizedBox(width: 8),
                          Text(
                            'Length: ${_resetPasswordLength.toInt()}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: accent,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: _resetPasswordLength,
                              min: 8,
                              max: 20,
                              divisions: 12,
                              activeColor: accent,
                              inactiveColor: Colors.grey.shade300,
                              onChanged: (value) {
                                setState(() {
                                  _resetPasswordLength = value;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _suggestResetStrongPassword,
                          icon: Icon(
                            Icons.auto_awesome,
                            size: 16,
                            color: accent,
                          ),
                          label: Text(
                            'Suggest strong password',
                            style: TextStyle(fontSize: 12, color: accent),
                          ),
                        ),
                      ),
                      SizedBox(height: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: inputCardColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: inputBorderColor),
                        ),
                        child: TextField(
                          controller: _resetConfirmPasswordController,
                          obscureText: _obscureResetConfirmPassword,
                          style: TextStyle(color: inputTextColor),
                          decoration: InputDecoration(
                            labelText: 'Confirm New Password',
                            labelStyle: TextStyle(color: inputLabelColor),
                            prefixIcon: Icon(Icons.lock_outline, color: accent),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureResetConfirmPassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: Colors.grey,
                              ),
                              onPressed: () => setState(
                                () => _obscureResetConfirmPassword =
                                    !_obscureResetConfirmPassword,
                              ),
                            ),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _resetPassword,
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: _isLoading
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                _useRecoveryCodeForReset
                                    ? 'Reset with Recovery Code'
                                    : 'Reset Password',
                                style: TextStyle(fontSize: 18),
                              ),
                      ),
                      const SizedBox(height: 12),
                      if (!_useRecoveryCodeForReset)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton(
                              onPressed: _resetResendCooldown == 0
                                  ? _resendResetCode
                                  : null,
                              child: Text(
                                _resetResendCooldown > 0
                                    ? 'Resend code (${_resetResendCooldown}s)'
                                    : 'Resend code',
                                style: TextStyle(
                                  color: _resetResendCooldown > 0
                                      ? Colors.grey
                                      : accent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _showResetPassword = false;
                            _showForgotPassword = false;
                            _useRecoveryCodeForReset = false;
                            _resetOtpCodeController.clear();
                            _resetNewPasswordController.clear();
                            _resetConfirmPasswordController.clear();
                            _resetResendCooldown = 0;
                            _resetResendTimer?.cancel();
                          });
                        },
                        child: Text('Back to Login'),
                      ),
                    ] else if (!_show2FA) ...[

                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.email),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      SizedBox(height: 16),


                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: Colors.grey,
                            ),
                            onPressed: () {
                              setState(() {
                                _obscurePassword = !_obscurePassword;
                              });
                            },
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),


                      if (!_isLogin && _passwordController.text.isNotEmpty) ...[
                        SizedBox(height: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: LinearProgressIndicator(
                                    value: _passwordStrength,
                                    backgroundColor: Colors.grey.shade300,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      _passwordStrengthColor,
                                    ),
                                    minHeight: 6,
                                    borderRadius: BorderRadius.circular(3),
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
                            if (_passwordSuggestions.isNotEmpty) ...[
                              SizedBox(height: 8),
                              Container(
                                padding: EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.amber.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '💡 Tips to improve:',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.amber.shade900,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    ..._passwordSuggestions.map(
                                      (suggestion) => Padding(
                                        padding: EdgeInsets.only(
                                          left: 8,
                                          bottom: 2,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.tips_and_updates,
                                              size: 12,
                                              color: Colors.amber.shade700,
                                            ),
                                            SizedBox(width: 4),
                                            Text(
                                              suggestion,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.amber.shade800,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],


                      if (!_isLogin) ...[
                        SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.format_size, size: 18, color: accent),
                            SizedBox(width: 8),
                            Text(
                              'Length: ${_passwordLength.toInt()}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: accent,
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                value: _passwordLength,
                                min: 8,
                                max: 20,
                                divisions: 12,
                                activeColor: accent,
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
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _suggestStrongPassword,
                            icon: Icon(
                              Icons.auto_awesome,
                              size: 16,
                              color: accent,
                            ),
                            label: Text(
                              'Suggest strong password',
                              style: TextStyle(fontSize: 12, color: accent),
                            ),
                          ),
                        ),
                      ],


                      if (!_isLogin) ...[
                        SizedBox(height: 8),
                        TextFormField(
                          controller: _confirmPasswordController,
                          obscureText: _obscureConfirmPassword,
                          decoration: InputDecoration(
                            labelText: 'Confirm Password',
                            prefixIcon: Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureConfirmPassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: Colors.grey,
                              ),
                              onPressed: () {
                                setState(() {
                                  _obscureConfirmPassword =
                                      !_obscureConfirmPassword;
                                });
                              },
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ],

                      SizedBox(height: 24),

                      ElevatedButton(
                        onPressed: _isLoading ? null : _submitLogin,
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: _isLoading
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                _isLogin ? 'Login' : 'Register',
                                style: TextStyle(fontSize: 18),
                              ),
                      ),

                      SizedBox(height: 16),

                      if (_isLogin) ...[
                        if (_serverLockdownEnabled) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.orange.withValues(alpha: 0.3),
                              ),
                            ),
                            child: Text(
                              'Server Lockdown is on. Sign-in, passwordless, sync, updates, and every server feature are blocked until you turn it off in Settings. Continue offline to keep using your local vault.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                color: inputLabelColor,
                                height: 1.4,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        Text(
                          _syncValueMessage,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: inputLabelColor,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _isLoading ? null : _continueOffline,
                          icon: const Icon(Icons.lock_outline_rounded),
                          label: const Text('Continue offline'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 46),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed:
                              _isLoading ? null : _startPasswordlessLogin,
                          icon: const Icon(Icons.phonelink_lock_rounded),
                          label: const Text(
                            'Use passwordless from primary phone',
                          ),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 46),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _isLoading ? null : _recoverPrimaryDevice,
                          child: Text(
                            'Lost primary phone? Recover this phone',
                            style: TextStyle(color: accent),
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],


                      if (_isLogin)
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _showForgotPassword = true;
                              _showResetPassword = false;
                            });
                          },
                          child: Text(
                            'Forgot Password?',
                            style: TextStyle(color: accent),
                          ),
                        ),


                      TextButton(
                        onPressed: () {
                          setState(() {
                            _isLogin = !_isLogin;
                            _passwordController.clear();
                            _confirmPasswordController.clear();
                            _pendingLoginEmail = null;
                            _passwordStrength = 0.0;
                            _passwordStrengthText = '';
                            _passwordSuggestions = [];
                          });
                        },
                        child: Text(
                          _isLogin ? 'No account? Register' : 'Back to Login',
                        ),
                      ),
                    ] else ...[

                      Text(
                        _useRecoveryCodeFor2FA
                            ? 'Use one of your recovery codes if you cannot access email right now'
                            : 'A verification code has been sent to your email',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                      SizedBox(height: 30),
                      TextFormField(
                        controller: _otpCodeController,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 24,
                          letterSpacing: 4,
                          color: inputTextColor,
                        ),
                        keyboardType: _useRecoveryCodeFor2FA
                            ? TextInputType.text
                            : TextInputType.number,
                        maxLength: _useRecoveryCodeFor2FA ? 10 : 6,
                        decoration: InputDecoration(
                          labelText: _useRecoveryCodeFor2FA
                              ? 'Enter 10-character recovery code'
                              : 'Enter 6-digit code',
                          labelStyle: TextStyle(color: inputLabelColor),
                          filled: true,
                          fillColor: inputCardColor,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: inputBorderColor),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: inputBorderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: accent, width: 1.4),
                          ),
                          counterText: '',
                        ),
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(
                            _useRecoveryCodeFor2FA ? 10 : 6,
                          ),
                          if (_useRecoveryCodeFor2FA)
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[A-Za-z0-9]'),
                            )
                          else
                            FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () {
                            setState(() {
                              _useRecoveryCodeFor2FA = !_useRecoveryCodeFor2FA;
                              _otpCodeController.clear();
                            });
                          },
                          child: Text(
                            _useRecoveryCodeFor2FA
                                ? 'Use email code instead'
                                : 'Use recovery code instead',
                          ),
                        ),
                      ),
                      SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _verify2FA,
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: _isLoading
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                _useRecoveryCodeFor2FA
                                    ? 'Verify Recovery Code'
                                    : 'Verify',
                                style: TextStyle(fontSize: 18),
                              ),
                      ),
                      const SizedBox(height: 12),
                      if (!_useRecoveryCodeFor2FA)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton(
                              onPressed:
                                  _resendCooldown == 0 ? _resend2FACode : null,
                              child: Text(
                                _resendCooldown > 0
                                    ? 'Resend code (${_resendCooldown}s)'
                                    : 'Resend code',
                                style: TextStyle(
                                  color: _resendCooldown > 0
                                      ? Colors.grey
                                      : accent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      if (!_useRecoveryCodeFor2FA) ...[
                        const SizedBox(height: 6),
                        OutlinedButton.icon(
                          onPressed: _isLoading
                              ? null
                              : () => _startPasswordlessLogin(
                                    passwordForSync: _passwordController.text,
                                  ),
                          icon: const Icon(Icons.phonelink_lock_rounded),
                          label: const Text(
                            'Use passwordless approval instead',
                          ),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 46),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ],
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _show2FA = false;
                            _useRecoveryCodeFor2FA = false;
                            _pendingLoginEmail = null;
                            _otpCodeController.clear();
                          });
                        },
                        child: Text('Back to login'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _submitLogin() async {
    if (_serverLockdownEnabled) {
      _showError(
        ServerLockdownService().blockedMessageFor(
          _isLogin
              ? 'sign in or request email verification codes'
              : 'register or create an online account',
        ),
      );
      return;
    }

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty) {
      _showError('Please enter email');
      return;
    }
    if (!email.contains('@') || !email.contains('.')) {
      _showError('Please enter a valid email address');
      return;
    }
    if (password.isEmpty) {
      _showError('Please enter password');
      return;
    }
    if (!_isLogin) {
      if (_passwordController.text != _confirmPasswordController.text) {
        _showError('Passwords do not match');
        return;
      }
      if (_passwordStrength < 0.5) {
        _showError('Please use a stronger password');
        return;
      }
    }
    setState(() {
      _isLoading = true;
    });
    if (_isLogin) {
      final sent = await _syncService.send2FACode(email, password);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      if (sent) {
        _pendingLoginEmail = email;
        _startResendTimer();
        setState(() {
          _show2FA = true;
        });
        _showSuccess('Verification code sent to your email.');
      } else {
        _showError(
          _syncService.lastErrorMessage ??
              'Unable to send the verification code. Check your email, password, or internet connection.',
        );
      }
    } else {
      bool success = await _syncService.register(email, password);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      if (success) {
        _showSuccess('Registration successful! Please login.');
        setState(() {
          _isLogin = true;
          _passwordController.clear();
          _confirmPasswordController.clear();
        });
      } else {
        _showError(
          _syncService.lastErrorMessage ??
              'Registration failed - email may already exist',
        );
      }
    }
  }

  void _sendResetCode() async {
    if (_serverLockdownEnabled) {
      _showError(
        ServerLockdownService().blockedMessageFor(
          'request password reset codes',
        ),
      );
      return;
    }
    if (_resetEmailController.text.isEmpty) {
      _showError('Please enter your email address');
      return;
    }
    setState(() {
      _isLoading = true;
    });
    final sent = await _syncService.sendPasswordResetCode(
      _resetEmailController.text,
    );
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
    if (sent) {
      _resetEmail = _resetEmailController.text;
      setState(() {
        _showResetPassword = true;
        _useRecoveryCodeForReset = false;
      });
      _showSuccess('Reset code sent to your email!');
    } else {
      _showError('No account found with this email address');
    }
  }

  Future<void> _completeAuthenticatedSession() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final secureStorage = SecureStorageService();
    final email =
        await secureStorage.read(SecureStorageService.userEmailKey) ?? '';
    final currentUsername =
        await secureStorage.read(SecureStorageService.currentUserKey) ?? '';
    final userId =
        await secureStorage.read(SecureStorageService.userIdKey) ?? '';

    await authProvider.setUserData(currentUsername, email, userId);
    if (!mounted) return;

    unawaited(
      PushMessagingService().syncCurrentPushTokenIfPossible(force: true),
    );

    if (widget.returnToPreviousOnOffline && Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
      return;
    }

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => HomeScreen()),
      (route) => false,
    );
  }

  bool _passwordlessResultHasAuthenticatedSession(Map<String, dynamic> result) {
    final access = result['access']?.toString() ?? '';
    final refresh = result['refresh']?.toString() ?? '';
    return result['success'] == true && access.isNotEmpty && refresh.isNotEmpty;
  }

  Future<void> _completePasswordlessSession(
    Map<String, dynamic> result, {
    String? effectivePassword,
  }) async {
    final needsSyncUnlock = result['requires_password_for_sync'] == true &&
        (effectivePassword == null || effectivePassword.isEmpty);
    var syncUnlockedNow = false;
    if (needsSyncUnlock) {
      syncUnlockedNow = await _promptToUnlockSyncAfterPasswordless();
      if (!mounted) return;
    }

    _showSuccess(
      syncUnlockedNow
          ? 'Passwordless sign-in approved and sync unlocked on this device.'
          : (() {
              final syncMessage =
                  result['sync_unlock_message']?.toString().trim() ?? '';
              if (syncMessage.isNotEmpty) {
                return syncMessage;
              }
              final message = result['message']?.toString().trim() ?? '';
              if (message.isNotEmpty) {
                return message;
              }
              return 'Passwordless sign-in approved.';
            })(),
    );
    await _completeAuthenticatedSession();
  }

  Future<_PasswordlessLoginOutcome> _startPasswordlessLogin({
    String? passwordForSync,
    bool showFallbackMessage = true,
  }) async {
    if (_serverLockdownEnabled) {
      _showError(
        ServerLockdownService().blockedMessageFor('use passwordless sign-in'),
      );
      return _PasswordlessLoginOutcome.failed;
    }

    final email = (_pendingLoginEmail ?? _emailController.text).trim();
    final effectivePassword = passwordForSync ??
        (_passwordController.text.isEmpty ? null : _passwordController.text);
    if (email.isEmpty) {
      _showError('Enter your email first');
      return _PasswordlessLoginOutcome.failed;
    }

    final startResult = await _syncService.startPasswordlessLogin(
      email,
      password: effectivePassword,
    );
    if (!mounted) {
      return _PasswordlessLoginOutcome.failed;
    }

    if (startResult == null) {
      if (showFallbackMessage && mounted) {
        final fallbackMessage = _syncService.lastErrorMessage;
        if (fallbackMessage != null && fallbackMessage.trim().isNotEmpty) {
          _showError(fallbackMessage);
        }
      }
      return _PasswordlessLoginOutcome.failed;
    }

    if (_passwordlessResultHasAuthenticatedSession(startResult)) {
      await _completePasswordlessSession(
        startResult,
        effectivePassword: effectivePassword,
      );
      return _PasswordlessLoginOutcome.approved;
    }

    if (startResult['fallback_to_password'] == true) {
      if (showFallbackMessage) {
        final fallbackMessage =
            startResult['error']?.toString() ?? _syncService.lastErrorMessage;
        if (fallbackMessage != null && fallbackMessage.trim().isNotEmpty) {
          _showError(fallbackMessage);
        }
      }
      return _PasswordlessLoginOutcome.fallbackToPassword;
    }

    final requestId = startResult['request_id']?.toString() ?? '';
    if (requestId.isEmpty) {
      final fallbackMessage =
          startResult['error']?.toString() ?? _syncService.lastErrorMessage;
      if (fallbackMessage != null && fallbackMessage.trim().isNotEmpty) {
        _showError(fallbackMessage);
      }
      return _PasswordlessLoginOutcome.failed;
    }

    final result = await Navigator.push<Map<String, dynamic>?>(
      context,
      MaterialPageRoute(
        builder: (_) => PasswordlessLoginScreen(
          email: email,
          passwordForSync: effectivePassword,
          initialResult: startResult,
        ),
      ),
    );
    if (!mounted) {
      return _PasswordlessLoginOutcome.failed;
    }
    if (result == null) {
      return _PasswordlessLoginOutcome.cancelled;
    }
    if (_passwordlessResultHasAuthenticatedSession(result)) {
      await _completePasswordlessSession(
        result,
        effectivePassword: effectivePassword,
      );
      return _PasswordlessLoginOutcome.approved;
    }

    if (showFallbackMessage) {
      final fallbackMessage =
          result['error']?.toString() ?? _syncService.lastErrorMessage;
      if (fallbackMessage != null && fallbackMessage.trim().isNotEmpty) {
        _showError(fallbackMessage);
      }
    }
    return _PasswordlessLoginOutcome.failed;
  }

  Future<bool> _promptToUnlockSyncAfterPasswordless() async {
    final passwordController = TextEditingController();
    var isSubmitting = false;
    String? errorText;
    var didUnlock = false;
    var obscurePassword = true;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => PopScope(
          canPop: false,
          child: AlertDialog(
            scrollable: true,
            title: const Text('Unlock Sync On This Device'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Passwordless sign-in was approved, but this device could '
                    'not restore the sync unlock key from that approval. '
                    'Enter your account password here to restore the '
                    'encryption key and unlock synced OTPs, passwords, and '
                    'secure text on this device.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    enabled: !isSubmitting,
                    decoration: InputDecoration(
                      labelText: 'Account password',
                      border: const OutlineInputBorder(),
                      errorText: errorText,
                      suffixIcon: IconButton(
                        tooltip:
                            obscurePassword ? 'Show password' : 'Hide password',
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                        ),
                        onPressed: () => setDialogState(
                          () => obscurePassword = !obscurePassword,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed:
                    isSubmitting ? null : () => Navigator.pop(dialogContext),
                child: const Text('Continue without sync'),
              ),
              FilledButton(
                onPressed: isSubmitting
                    ? null
                    : () async {
                        final password = passwordController.text;
                        if (password.isEmpty) {
                          setDialogState(() {
                            errorText = 'Enter your password to unlock sync.';
                          });
                          return;
                        }

                        setDialogState(() {
                          isSubmitting = true;
                          errorText = null;
                        });

                        final unlockSucceeded = await _syncService
                            .unlockSyncOnCurrentDevice(password);
                        if (!dialogContext.mounted) return;

                        if (unlockSucceeded) {
                          setDialogState(() {
                            isSubmitting = false;
                          });
                          didUnlock = true;
                          Navigator.pop(dialogContext);
                          return;
                        }

                        setDialogState(() {
                          isSubmitting = false;
                          errorText = _syncService.lastErrorMessage ??
                              'Could not unlock sync on this device.';
                        });
                      },
                child: isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Unlock sync'),
              ),
            ],
          ),
        ),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 250));
    passwordController.dispose();
    return didUnlock;
  }

  Future<void> _recoverPrimaryDevice() async {
    if (_serverLockdownEnabled) {
      _showError(
        ServerLockdownService().blockedMessageFor(
          'recover or move the primary device',
        ),
      );
      return;
    }

    final success = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const RecoverPrimaryDeviceScreen()),
    );
    if (!mounted || success != true) return;

    _showSuccess('This phone is now your primary device.');
    await _completeAuthenticatedSession();
  }

  Future<void> _continueOffline() async {
    await _syncService.logout(notifyServer: false);
    if (!mounted) return;
    await Provider.of<AuthProvider>(context, listen: false).continueOffline();
    if (!mounted) return;

    if (widget.returnToPreviousOnOffline && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }

  void _resetPassword() async {
    if (_resetOtpCodeController.text.isEmpty) {
      _showError(
        _useRecoveryCodeForReset
            ? 'Please enter recovery code'
            : 'Please enter verification code',
      );
      return;
    }
    if (_useRecoveryCodeForReset &&
        _resetOtpCodeController.text.trim().length != 10) {
      _showError('Please enter a valid 10-character recovery code');
      return;
    }
    if (!_useRecoveryCodeForReset && _resetOtpCodeController.text.length != 6) {
      _showError('Please enter a valid 6-digit code');
      return;
    }
    if (_resetNewPasswordController.text.isEmpty) {
      _showError('Please enter new password');
      return;
    }
    if (_resetNewPasswordController.text.length < 8) {
      _showError('Password must be at least 8 characters');
      return;
    }
    if (_resetNewPasswordController.text !=
        _resetConfirmPasswordController.text) {
      _showError('Passwords do not match');
      return;
    }
    if (_resetPasswordStrength < 0.5) {
      _showError('Please use a stronger password');
      return;
    }
    setState(() {
      _isLoading = true;
    });
    final success = _useRecoveryCodeForReset
        ? await _syncService.resetPasswordWithRecoveryCode(
            _resetEmail!,
            _resetOtpCodeController.text,
            _resetNewPasswordController.text,
          )
        : await _syncService.resetPassword(
            _resetEmail!,
            _resetOtpCodeController.text,
            _resetNewPasswordController.text,
          );
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
    if (success) {
      if (_useRecoveryCodeForReset) {
        _showSuccess(
          'Recovery code accepted. Your password was changed and you are now signed in.',
        );
        await _completeAuthenticatedSession();
        return;
      }

      _showSuccess(
        'Password reset successfully! Please login with your new password.',
      );
      setState(() {
        _showResetPassword = false;
        _showForgotPassword = false;
        _useRecoveryCodeForReset = false;
        _resetOtpCodeController.clear();
        _resetNewPasswordController.clear();
        _resetConfirmPasswordController.clear();
      });
    } else {
      _showError(_syncService.lastErrorMessage ?? 'Invalid verification code');
    }
  }

  void _verify2FA() async {
    final email = (_pendingLoginEmail ?? _emailController.text).trim();
    final code = _otpCodeController.text.trim();

    if (_otpCodeController.text.isEmpty) {
      _showError(
        _useRecoveryCodeFor2FA
            ? 'Please enter recovery code'
            : 'Please enter verification code',
      );
      return;
    }
    if (_useRecoveryCodeFor2FA && code.length != 10) {
      _showError('Please enter a valid 10-character recovery code');
      return;
    }
    if (!_useRecoveryCodeFor2FA && code.length != 6) {
      _showError('Please enter a valid 6-digit code');
      return;
    }
    setState(() {
      _isLoading = true;
    });
    final isValid = _useRecoveryCodeFor2FA
        ? await _syncService.verifyLoginWithRecoveryCode(
            email,
            _passwordController.text,
            code,
          )
        : await _syncService.verify2FACode(email, code);
    if (!mounted) return;
    if (!isValid) {
      setState(() {
        _isLoading = false;
      });
      _showError(_syncService.lastErrorMessage ?? 'Invalid verification code');
      return;
    }

    final success = await _syncService.login(email, _passwordController.text);
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
    if (success) {
      await _completeAuthenticatedSession();
    } else {
      _showError(_syncService.lastErrorMessage ?? 'Login failed');
    }
  }

  void _showError(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: _snackDuration(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showSuccess(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: _snackDuration(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Duration _snackDuration(String message) {
    return Duration(seconds: message.length >= 80 ? 5 : 3);
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _resetResendTimer?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _otpCodeController.dispose();
    _resetEmailController.dispose();
    _resetNewPasswordController.dispose();
    _resetConfirmPasswordController.dispose();
    _resetOtpCodeController.dispose();
    _passwordController.removeListener(_checkPasswordStrength);
    _resetNewPasswordController.removeListener(_checkResetPasswordStrength);
    super.dispose();
  }
}
