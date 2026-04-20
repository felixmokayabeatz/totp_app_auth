import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'biometric_service.dart';

class AppLockService {
  final BiometricService _biometricService = BiometricService();
  static const String _appLockEnabledKey = 'app_lock_enabled';
  static const String _lastActiveTimeKey = 'last_active_time';

  Future<bool> isAppLockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_appLockEnabledKey) ?? false;
  }

  Future<void> setAppLockEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_appLockEnabledKey, enabled);
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

    final lastActiveTime = DateTime.fromMillisecondsSinceEpoch(lastActive);
    final difference = DateTime.now().difference(lastActiveTime);
    return difference.inSeconds > 30;
  }

  Future<bool> authenticateToUnlock(BuildContext context) async {
    final biometricEnabled = await _biometricService.isBiometricEnabled();
    final biometricAvailable = await _biometricService.isBiometricAvailable();

    if (biometricEnabled && biometricAvailable) {
      final name = await _biometricService.getBiometricName();
      return await _biometricService.authenticateWithBiometrics(
        reason: 'Unlock BeatzLock with $name',
      );
    }
    return true; // No biometric, just unlock
  }
}
