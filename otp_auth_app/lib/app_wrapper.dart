// app_wrapper.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/app_lock_service.dart';
import 'providers/auth_provider.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

class AppLockWrapper extends StatefulWidget {
  final Widget child;

  const AppLockWrapper({super.key, required this.child});

  @override
  State<AppLockWrapper> createState() => _AppLockWrapperState();
}

class _AppLockWrapperState extends State<AppLockWrapper>
    with WidgetsBindingObserver {
  final AppLockService _appLockService = AppLockService();
  bool _isLocked = false;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Delay the lock check to ensure context is available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkInitialLock();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkInitialLock() async {
    final isLoggedIn =
        await Provider.of<AuthProvider>(context, listen: false).isLoggedIn();
    if (isLoggedIn) {
      final isEnabled = await _appLockService.isAppLockEnabled();
      if (isEnabled) {
        setState(() => _isLocked = true);
        _isInitialized = true;
        // Don't show dialog immediately, wait for first frame
        Future.delayed(Duration.zero, () => _showUnlockDialog());
      } else {
        setState(() => _isInitialized = true);
      }
    } else {
      setState(() => _isInitialized = true);
    }
  }

  Future<void> _showUnlockDialog() async {
    if (!mounted) return;

    final authenticated = await _appLockService.authenticateToUnlock(context);
    if (authenticated && mounted) {
      setState(() => _isLocked = false);
    } else if (mounted) {
      // Failed authentication - logout
      await Provider.of<AuthProvider>(context, listen: false).logout();
      setState(() => _isLocked = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _appLockService.recordAppActivity();
    } else if (state == AppLifecycleState.resumed) {
      _checkAndLock();
    }
  }

  Future<void> _checkAndLock() async {
    final isLoggedIn =
        await Provider.of<AuthProvider>(context, listen: false).isLoggedIn();
    if (!isLoggedIn) return;

    final needsUnlock = await _appLockService.needsUnlock();
    if (needsUnlock && !_isLocked && mounted) {
      setState(() => _isLocked = true);
      await _showUnlockDialog();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_isLocked) {
      return Scaffold(
        backgroundColor: const Color(0xFF667eea),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_outline, size: 80, color: Colors.white),
              const SizedBox(height: 20),
              const Text('BeatzLock is locked',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              const Text('Authenticate to continue',
                  style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 30),
              ElevatedButton.icon(
                onPressed: () async {
                  final authenticated =
                      await _appLockService.authenticateToUnlock(context);
                  if (authenticated && mounted) {
                    setState(() => _isLocked = false);
                  }
                },
                icon: const Icon(Icons.fingerprint),
                label: const Text('Unlock'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF667eea),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return widget.child;
  }
}
