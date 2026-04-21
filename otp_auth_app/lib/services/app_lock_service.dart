import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'biometric_service.dart';

class AppLockService {
  final BiometricService _biometricService = BiometricService();
  static const String _appLockEnabledKey = 'app_lock_enabled';
  static const String _lastActiveTimeKey = 'last_active_time';
  static const String _lockTimeoutKey = 'lock_timeout_minutes';

  // Change default timeout from 5 seconds to 5 minutes
  static const int _defaultTimeout = 5; // 5 minutes

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

    print('DEBUG: Last active: $lastActiveTime');
    print('DEBUG: Now: ${DateTime.now()}');
    print('DEBUG: Difference: ${difference.inMinutes} minutes');
    print('DEBUG: Timeout: $timeoutMinutes minutes');
    print('DEBUG: Should lock: ${difference.inMinutes >= timeoutMinutes}');

    // Only lock after the timeout period (in MINUTES)
    // Add a small buffer (1 second) to prevent immediate locking
    return difference.inMinutes >= timeoutMinutes && difference.inSeconds > 1;
  }

  // Main authentication method - platform specific
  Future<bool> authenticateToUnlock(BuildContext context) async {
    if (_biometricService.isDesktop()) {
      // DESKTOP: Use App PIN only
      final hasPin = await _biometricService.hasAppPin();

      if (!hasPin) {
        // First time - force user to set up PIN
        final pinSet = await _showForceSetAppPinDialog(context);
        if (!pinSet) {
          // User must set PIN to continue
          return false;
        }
      }

      // Authenticate with App PIN
      return await _biometricService.authenticateWithAppPin(context);
    } else {
      // MOBILE: Use device system authentication (PIN/Pattern/Fingerprint)
      return await _biometricService.authenticateWithDeviceSystem(context);
    }
  }

  // Force user to set up PIN on first use (Desktop only)
  Future<bool> _showForceSetAppPinDialog(BuildContext context) async {
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    final completer = Completer<bool>();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Set Up App PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'For security, please set up a PIN to lock BeatzLock.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: pinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
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
            },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    );

    return completer.future;
  }

  // Setup PIN from Settings (Desktop only)
  // Add this method to AppLockService class
  Future<bool> setupAppPinFromSettings(BuildContext context) async {
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    final completer = Completer<bool>();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Set App PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Create a PIN to lock BeatzLock',
                style: TextStyle(fontSize: 14)),
            const SizedBox(height: 16),
            TextField(
              controller: pinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
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
            child: const Text('Cancel'),
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
            },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    );

    return completer.future;
  }
}
