import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/app_lock_service.dart';
import 'services/auth_provider.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';

class AppWrapper extends StatefulWidget {
  const AppWrapper({super.key});

  @override
  State<AppWrapper> createState() => _AppWrapperState();
}

class _AppWrapperState extends State<AppWrapper> with WidgetsBindingObserver {
  final AppLockService _appLockService = AppLockService();
  bool _isLocked = false;
  bool _isChecking = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialLock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // App went to background
      _appLockService.recordAppActivity();
    } else if (state == AppLifecycleState.resumed) {
      // App came to foreground
      _checkAndLock();
    }
  }

  Future<void> _checkInitialLock() async {
    final isLoggedIn =
        await Provider.of<AuthProvider>(context, listen: false).isLoggedIn();
    if (isLoggedIn) {
      final needsUnlock = await _appLockService.needsUnlock();
      if (needsUnlock) {
        setState(() {
          _isLocked = true;
          _isChecking = false;
        });
      } else {
        setState(() => _isChecking = false);
      }
    } else {
      setState(() => _isChecking = false);
    }
  }

  Future<void> _checkAndLock() async {
    final isLoggedIn =
        await Provider.of<AuthProvider>(context, listen: false).isLoggedIn();
    if (!isLoggedIn) return;

    final needsUnlock = await _appLockService.needsUnlock();
    if (needsUnlock && !_isLocked) {
      setState(() => _isLocked = true);
      await _showUnlockScreen();
    }
  }

  Future<void> _showUnlockScreen() async {
    final authenticated = await _appLockService.authenticateToUnlock(context);
    if (authenticated) {
      setState(() => _isLocked = false);
    } else {
      // Failed authentication - logout
      await Provider.of<AuthProvider>(context, listen: false).logout();
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => LoginScreen()),
          (route) => false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final authProvider = Provider.of<AuthProvider>(context);

    if (!authProvider.isLoggedIn) {
      return LoginScreen();
    }

    if (_isLocked) {
      return Scaffold(
        backgroundColor: Color(0xFF667eea),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 80, color: Colors.white),
              SizedBox(height: 20),
              Text(
                'BeatzLock is locked',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 10),
              Text(
                'Authenticate to continue',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              SizedBox(height: 30),
              ElevatedButton.icon(
                onPressed: _showUnlockScreen,
                icon: Icon(Icons.fingerprint),
                label: Text('Unlock'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Color(0xFF667eea),
                  padding: EdgeInsets.symmetric(horizontal: 40, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return HomeScreen();
  }
}
