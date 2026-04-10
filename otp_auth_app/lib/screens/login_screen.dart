import 'package:flutter/material.dart';
import '../services/sync_service.dart';
import 'home_screen.dart';

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
  String? _tempUsername; // Store username for 2FA verification
  
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
                      
                      // Password field
                      TextFormField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      
                      // Confirm password (only for registration)
                      if (!_isLogin) ...[
                        SizedBox(height: 16),
                        TextFormField(
                          controller: _confirmPasswordController,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: 'Confirm Password',
                            prefixIcon: Icon(Icons.lock_outline),
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
    
    if (_passwordController.text != _confirmPasswordController.text) {
      _showError('Passwords do not match');
      return;
    }
  }
  
  setState(() {
    _isLoading = true;
  });
  
  if (_isLogin) {
    // Send 2FA code with password verification
    final sent = await _syncService.send2FACode(
      _usernameController.text,
      _passwordController.text,  // PASS THE PASSWORD!
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
    // Register directly
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
  
  setState(() {
    _isLoading = true;
  });
  
  // Verify the 2FA code
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
  
  // Login after 2FA verification - this saves the token
  bool success = await _syncService.login(
    _tempUsername ?? _usernameController.text,
    _passwordController.text,
  );
  
  setState(() {
    _isLoading = false;
  });
  
  if (success) {
    // Token is now saved and will be used for sync
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
      ),
    );
  }
  
  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 3),
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
    super.dispose();
  }
}