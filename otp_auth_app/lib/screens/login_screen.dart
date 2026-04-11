import 'package:flutter/material.dart';
import '../services/sync_service.dart';
import '../providers/auth_provider.dart';
import 'home_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';



class LoginScreen extends StatefulWidget {
  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _otpCodeController = TextEditingController();
  
  final SyncService _syncService = SyncService();
  
  bool _isLogin = true;
  bool _isLoading = false;
  bool _show2FA = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  String? _tempUsername;
  double _passwordLength = 16;
  
  // Password strength variables
  double _passwordStrength = 0.0;
  String _passwordStrengthText = '';
  Color _passwordStrengthColor = Colors.grey;
  List<String> _passwordSuggestions = [];
  
  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_checkPasswordStrength);
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
    
    // Length check
    if (password.length >= 12) {
      score += 25;
    } else if (password.length >= 8) {
      score += 15;
    } else {
      suggestions.add('Use at least 8 characters (12+ recommended)');
    }
    
    // Contains number
    if (password.contains(RegExp(r'[0-9]'))) {
      score += 25;
    } else {
      suggestions.add('Add a number');
    }
    
    // Contains uppercase
    if (password.contains(RegExp(r'[A-Z]'))) {
      score += 25;
    } else {
      suggestions.add('Add an uppercase letter');
    }
    
    // Contains special character
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
  
  String _generateStrongPassword(int length) {
    const uppercase = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const lowercase = 'abcdefghijkmnopqrstuvwxyz';
    const numbers = '23456789';
    const symbols = r'!@#$%^&*()_+-=[]{}|;:,.<>?';
    
    String password = '';
    final random = DateTime.now().millisecondsSinceEpoch;
    
    // Ensure at least one of each type
    password += uppercase[random % uppercase.length];
    password += lowercase[(random + 1) % lowercase.length];
    password += numbers[(random + 2) % numbers.length];
    password += symbols[(random + 3) % symbols.length];
    
    final allChars = uppercase + lowercase + numbers + symbols;
    
    // Fill the rest randomly
    for (int i = password.length; i < length; i++) {
      final randomIndex = (random + i) % allChars.length;
      password += allChars[randomIndex];
    }
    
    // Shuffle the password for better randomness
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
      _checkPasswordStrength();
    });
    _showSuccess('Strong password generated! (${length} characters)');
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF667eea), Color(0xFF764ba2)],
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
                    Icon(Icons.security, size: 80, color: Color(0xFF667eea)),
                    SizedBox(height: 20),
                    Text(
                      _show2FA ? 'Enter 2FA Code' : (_isLogin ? 'Welcome Back' : 'Create Account'),
                      style: TextStyle(
                        fontSize: 28, 
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 30),
                    
                    if (!_show2FA) ...[
                      // Username field
                      TextFormField(
                        controller: _usernameController,
                        decoration: InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      SizedBox(height: 16),
                      
                      // Email field (only for registration)
                      if (!_isLogin) ...[
                        TextFormField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: InputDecoration(
                            labelText: 'Email',
                            prefixIcon: Icon(Icons.email),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        SizedBox(height: 16),
                      ],
                      
                      // Password field with visibility toggle
                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword ? Icons.visibility_off : Icons.visibility,
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
                      
                      // Password strength indicator (only for registration)
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
                                    valueColor: AlwaysStoppedAnimation<Color>(_passwordStrengthColor),
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
                                    ..._passwordSuggestions.map((suggestion) => Padding(
                                      padding: EdgeInsets.only(left: 8, bottom: 2),
                                      child: Row(
                                        children: [
                                          Icon(Icons.tips_and_updates, size: 12, color: Colors.amber.shade700),
                                          SizedBox(width: 4),
                                          Text(
                                            suggestion,
                                            style: TextStyle(fontSize: 11, color: Colors.amber.shade800),
                                          ),
                                        ],
                                      ),
                                    )),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                      
                      // Password suggestion and length controls (only for registration)
                      if (!_isLogin) ...[
                        SizedBox(height: 8),
                        // Password length slider
                        Row(
                          children: [
                            Icon(Icons.format_size, size: 18, color: Color(0xFF667eea)),
                            SizedBox(width: 8),
                            Text(
                              'Length: ${_passwordLength.toInt()}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF667eea),
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                value: _passwordLength,
                                min: 8,
                                max: 20,
                                divisions: 12,
                                activeColor: Color(0xFF667eea),
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
                        // Suggest password button
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _suggestStrongPassword,
                            icon: Icon(Icons.auto_awesome, size: 16, color: Color(0xFF667eea)),
                            label: Text(
                              'Suggest strong password',
                              style: TextStyle(fontSize: 12, color: Color(0xFF667eea)),
                            ),
                          ),
                        ),
                      ],
                      
                      // Confirm password field (only for registration)
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
                                _obscureConfirmPassword ? Icons.visibility_off : Icons.visibility,
                                color: Colors.grey,
                              ),
                              onPressed: () {
                                setState(() {
                                  _obscureConfirmPassword = !_obscureConfirmPassword;
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
                      
                      // Submit button
                      ElevatedButton(
                        onPressed: _isLoading ? null : _submitLogin,
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
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      
                      SizedBox(height: 16),
                      
                      // Toggle login/register
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _isLogin = !_isLogin;
                            _passwordController.clear();
                            _confirmPasswordController.clear();
                            _passwordStrength = 0.0;
                            _passwordStrengthText = '';
                            _passwordSuggestions = [];
                          });
                        },
                        child: Text(
                          _isLogin 
                            ? 'Create new account' 
                            : 'Already have an account? Login',
                        ),
                      ),
                    ] else ...[
                      // 2FA Verification Screen
                      Text(
                        'A verification code has been sent to your email',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                      SizedBox(height: 30),
                      TextFormField(
                        controller: _otpCodeController,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 24, letterSpacing: 4),
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Enter 6-digit code',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _verify2FA,
                        child: _isLoading
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text('Verify', style: TextStyle(fontSize: 18)),
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _show2FA = false;
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
    if (_usernameController.text.isEmpty) {
      _showError('Please enter username');
      return;
    }
    
    if (_passwordController.text.isEmpty) {
      _showError('Please enter password');
      return;
    }
    
    if (!_isLogin) {
      if (_emailController.text.isEmpty) {
        _showError('Please enter email');
        return;
      }
      
      if (!_emailController.text.contains('@') || !_emailController.text.contains('.')) {
        _showError('Please enter a valid email address');
        return;
      }
      
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
      final sent = await _syncService.send2FACode(
        _usernameController.text,
        _passwordController.text,
      );
      
      setState(() {
        _isLoading = false;
      });
      
      if (sent) {
        _tempUsername = _usernameController.text;
        setState(() {
          _show2FA = true;
        });
        _showSuccess('2FA code sent to your email!');
      } else {
        _showError('Invalid username or password');
      }
    } else {
      bool success = await _syncService.register(
        _usernameController.text.trim(),
        _emailController.text.trim(),
        _passwordController.text,
      );
      
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
        _showError('Registration failed - Username may already exist');
      }
    }
  }
  
  void _verify2FA() async {
    if (_otpCodeController.text.isEmpty) {
      _showError('Please enter verification code');
      return;
    }
    
    if (_otpCodeController.text.length != 6) {
      _showError('Please enter a valid 6-digit code');
      return;
    }
    
    setState(() {
      _isLoading = true;
    });
    
    final isValid = await _syncService.verify2FACode(
      _tempUsername ?? _usernameController.text,
      _otpCodeController.text,
    );
    
    if (!isValid) {
      setState(() {
        _isLoading = false;
      });
      _showError('Invalid verification code');
      return;
    }
    
    bool success = await _syncService.login(
      _tempUsername ?? _usernameController.text,
      _passwordController.text,
    );
    
    setState(() {
      _isLoading = false;
    });
    
    if (success) {
      // Get user data from sync service
      final prefs = await SharedPreferences.getInstance();
      final email = prefs.getString('user_email') ?? '';
      final username = prefs.getString('current_user') ?? '';
      final userId = prefs.getString('user_id') ?? '';
      
      await Provider.of<AuthProvider>(context, listen: false).setUserData(
        username, 
        email, 
        userId
      );
      
      Navigator.pushReplacement(
        context, 
        MaterialPageRoute(builder: (_) => HomeScreen()),
      );
    } else {
      _showError('Login failed');
    }
  }
  
  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  
  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  
  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _otpCodeController.dispose();
    _passwordController.removeListener(_checkPasswordStrength);
    super.dispose();
  }
}