import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'biometric_service.dart';

class AppLockService {
  final BiometricService _biometricService = BiometricService();
  static const String _appLockEnabledKey = 'app_lock_enabled';
  static const String _lastActiveTimeKey = 'last_active_time';
  static const String _lockTimeoutKey = 'lock_timeout_minutes';

  static const int _defaultTimeout = 5;

  Future<bool> isAppLockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_appLockEnabledKey) ?? false;
  }

  Future<void> setAppLockEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_appLockEnabledKey, enabled);
    if (enabled) {
      await recordAppActivity();
    }
  }

  Future<int> getLockTimeout() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_lockTimeoutKey) ?? _defaultTimeout;
  }

  Future<void> setLockTimeout(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lockTimeoutKey, minutes.clamp(1, 10));
  }

  Future<void> recordAppActivity() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _lastActiveTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  Future<bool> needsUnlock() async {
    final isEnabled = await isAppLockEnabled();
    if (!isEnabled) return false;

    final prefs = await SharedPreferences.getInstance();
    final lastActive = prefs.getInt(_lastActiveTimeKey);
    if (lastActive == null) return true;

    final timeoutMinutes = await getLockTimeout();
    final lastActiveTime = DateTime.fromMillisecondsSinceEpoch(lastActive);
    final difference = DateTime.now().difference(lastActiveTime);

    return difference.inMinutes >= timeoutMinutes;
  }

  // Main authentication method with multiple fallbacks
  Future<bool> authenticateToUnlock(BuildContext context) async {
    final biometricEnabled = await _biometricService.isBiometricEnabled();
    final hasAppPin = await _biometricService.hasAppPin();

    // Try 1: Windows Hello/Biometric (if enabled)
    if (biometricEnabled) {
      final name = await _biometricService.getBiometricName();
      final authenticated = await _biometricService.authenticateWithBiometrics(
        reason: 'Unlock BeatzLock with $name',
      );
      if (authenticated) return true;
    }

    // Try 2: Windows PIN/Password (ALWAYS available on Windows)
    final pinAuthenticated = await _biometricService.authenticateWithWindowsPIN(
      reason: 'Enter your Windows PIN or password to unlock BeatzLock',
    );
    if (pinAuthenticated) return true;

    // Try 3: App PIN (if user set one)
    if (hasAppPin) {
      final appPinAuthenticated = await _showAppPinDialog(context);
      if (appPinAuthenticated) return true;
    }

    // If all fail, offer to set up App PIN
    if (context.mounted) {
      final shouldSetupPin = await _showSetupPinDialog(context);
      if (shouldSetupPin) {
        final pinSet = await _showSetAppPinDialog(context);
        if (pinSet) {
          // Try again with the new PIN
          return await authenticateToUnlock(context);
        }
      }
    }

    return false;
  }

  Future<bool> _showAppPinDialog(BuildContext context) async {
    final pinController = TextEditingController();
    final completer = Completer<bool>();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Enter App PIN'),
        content: TextField(
          controller: pinController,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(
            hintText: 'Enter your 4-6 digit PIN',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              completer.complete(false);
              Navigator.pop(context);
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final isValid =
                  await _biometricService.verifyAppPin(pinController.text);
              if (isValid) {
                completer.complete(true);
                Navigator.pop(context);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Invalid PIN'),
                      backgroundColor: Colors.red),
                );
              }
            },
            child: const Text('Unlock'),
          ),
        ],
      ),
    );

    return completer.future;
  }

  Future<bool> _showSetupPinDialog(BuildContext context) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Set Up App PIN'),
            content: const Text(
              'Windows authentication failed. Would you like to set up an App PIN as a backup?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Color(0xFF4F46E5),
                ),
                child: const Text('Set Up PIN'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _showSetAppPinDialog(BuildContext context) async {
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    final completer = Completer<bool>();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Create App PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                hintText: 'Enter 4-6 digit PIN',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmController,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                hintText: 'Confirm PIN',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              completer.complete(false);
              Navigator.pop(context);
            },
            child: const Text('Skip'),
          ),
          ElevatedButton(
            onPressed: () async {
              final pin = pinController.text;
              final confirm = confirmController.text;

              if (pin.length < 4) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('PIN must be at least 4 digits'),
                      backgroundColor: Colors.red),
                );
                return;
              }

              if (pin != confirm) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('PINs do not match'),
                      backgroundColor: Colors.red),
                );
                return;
              }

              await _biometricService.setAppPin(pin);
              completer.complete(true);
              Navigator.pop(context);

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('App PIN set successfully!'),
                    backgroundColor: Colors.green),
              );
            },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    );

    return completer.future;
  }
}
