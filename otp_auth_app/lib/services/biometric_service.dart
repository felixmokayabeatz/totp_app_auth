import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

class BiometricService {
  final LocalAuthentication _localAuth = LocalAuthentication();
  static const String _biometricEnabledKey = 'biometric_enabled';
  static const String _appPinKey = 'app_pin_hash';

  Future<void> init() async {}

  Future<bool> isBiometricAvailable() async {
    try {
      // On Windows, authentication is ALWAYS possible via PIN/Password
      if (Platform.isWindows) {
        return true;
      }

      final isAvailable = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      return isAvailable && isDeviceSupported;
    } catch (e) {
      // If error, assume Windows can still use PIN/Password
      return Platform.isWindows;
    }
  }

  Future<String> getBiometricName() async {
    if (Platform.isWindows) {
      return 'Windows Security';
    }

    final types = await _localAuth.getAvailableBiometrics();
    if (types.contains(BiometricType.face)) {
      return 'Face ID';
    } else if (types.contains(BiometricType.fingerprint)) {
      return 'Fingerprint';
    }
    return 'Biometric';
  }

  // Try Windows Hello (biometric) - may not be available on all PCs
  Future<bool> authenticateWithBiometrics({required String reason}) async {
    try {
      if (Platform.isWindows) {
        // Try Windows Hello without biometricOnly
        return await _localAuth.authenticate(
          localizedReason: reason,
          options: const AuthenticationOptions(
            stickyAuth: true,
          ),
        );
      } else {
        return await _localAuth.authenticate(
          localizedReason: reason,
          options: const AuthenticationOptions(
            stickyAuth: true,
            biometricOnly: true,
          ),
        );
      }
    } catch (e) {
      print('Biometric auth error: $e');
      return false;
    }
  }

  // Windows PIN/Password - THIS ALWAYS WORKS on Windows
  Future<bool> authenticateWithWindowsPIN({required String reason}) async {
    try {
      return await _localAuth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          // No biometricOnly - this shows PIN/Password dialog
        ),
      );
    } catch (e) {
      print('Windows PIN auth error: $e');
      return false;
    }
  }

  // App PIN storage (local fallback)
  Future<bool> hasAppPin() async {
    final prefs = await SharedPreferences.getInstance();
    final pin = prefs.getString(_appPinKey);
    return pin != null && pin.isNotEmpty;
  }

  Future<void> setAppPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appPinKey, pin);
  }

  Future<bool> verifyAppPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final storedPin = prefs.getString(_appPinKey);
    return storedPin == pin;
  }

  Future<void> deleteAppPin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_appPinKey);
  }

  Future<void> setBiometricEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricEnabledKey, enabled);
  }

  Future<bool> isBiometricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_biometricEnabledKey) ?? false;
  }
}
