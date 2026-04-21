import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'biometric_service.dart';

class AppLockService {
  final BiometricService _biometricService = BiometricService();
  static const String _appLockEnabledKey = 'app_lock_enabled';
  static const String _lastActiveTimeKey = 'last_active_time';
  static const String _lockTimeoutKey = 'lock_timeout_minutes';
  static const String _appPinKey = 'app_pin_hash';

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

  Future<bool> authenticateToUnlock(BuildContext context) async {
    final biometricAvailable = await _biometricService.isBiometricAvailable();
    final biometricEnabled = await _biometricService.isBiometricEnabled();

    // Try biometric first if available and enabled
    if (biometricAvailable && biometricEnabled) {
      final name = await _biometricService.getBiometricName();
      final authenticated = await _biometricService.authenticateWithBiometrics(
        reason: 'Unlock BeatzLock with $name',
      );
      if (authenticated) return true;
    }

    // Fallback to Windows PIN/Password (this works even without biometric hardware)
    // This will show Windows Security dialog with PIN/Password option
    final pinAuthenticated = await _biometricService.authenticateWithDevicePIN(
      reason: 'Enter your Windows PIN or password to unlock BeatzLock',
    );
    if (pinAuthenticated) return true;

    // Last resort: App PIN (if user set one)
    final hasPin = await hasAppPin();
    if (hasPin) {
      return await _showAppPinDialog(context);
    }

    // If nothing works, show a message and return false
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'No authentication method available. Please set up Windows Hello or enable App PIN.'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 3),
        ),
      );
    }
    return false;
  }

  Future<bool> hasAppPin() async {
    final prefs = await SharedPreferences.getInstance();
    final pin = prefs.getString(_appPinKey);
    return pin != null && pin.isNotEmpty;
  }

  Future<void> setAppPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final hashedPin = pin.hashCode.toString();
    await prefs.setString(_appPinKey, hashedPin);
  }

  Future<bool> verifyAppPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final storedPin = prefs.getString(_appPinKey);
    if (storedPin == null) return false;
    return storedPin == pin.hashCode.toString();
  }

  Future<bool> _showAppPinDialog(BuildContext context) async {
    final pinController = TextEditingController();
    final completer = Completer<bool>();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Enter PIN'),
        content: TextField(
          controller: pinController,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(
            hintText: 'Enter your app PIN',
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
              final isValid = await verifyAppPin(pinController.text);
              completer.complete(isValid);
              Navigator.pop(context);
            },
            child: const Text('Unlock'),
          ),
        ],
      ),
    );

    return completer.future;
  }
}
