import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

class BiometricService {
  final LocalAuthentication _localAuth = LocalAuthentication();
  static const String _biometricEnabledKey = 'biometric_enabled';

  Future<void> init() async {}

  Future<bool> isBiometricAvailable() async {
    try {
      // Windows always returns true for isDeviceSupported, but may not have biometrics
      final isDeviceSupported = await _localAuth.isDeviceSupported();

      if (Platform.isWindows) {
        // On Windows, we can always use PIN/Password even without biometrics
        return true;
      }

      final isAvailable = await _localAuth.canCheckBiometrics;
      return isAvailable && isDeviceSupported;
    } catch (e) {
      print('Biometric check error: $e');
      return Platform.isWindows; // Windows can always use PIN/Password
    }
  }

  Future<String> getBiometricName() async {
    if (Platform.isWindows) {
      return 'Windows Hello';
    }

    final types = await _localAuth.getAvailableBiometrics();
    if (types.contains(BiometricType.face)) {
      return 'Face ID';
    } else if (types.contains(BiometricType.fingerprint)) {
      return 'Fingerprint';
    }
    return 'Biometric';
  }

  // For Windows - authenticate without biometricOnly parameter
  Future<bool> authenticateWithBiometrics({required String reason}) async {
    try {
      if (Platform.isWindows) {
        // Windows: Don't use biometricOnly parameter
        return await _localAuth.authenticate(
          localizedReason: reason,
          options: const AuthenticationOptions(
            stickyAuth: true,
            // biometricOnly is NOT supported on Windows - remove it
          ),
        );
      } else {
        // Android/iOS: Use biometricOnly
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

  // This method allows PIN/Password fallback (works on all platforms)
  Future<bool> authenticateWithDevicePIN({required String reason}) async {
    try {
      // For all platforms, authenticate without biometricOnly
      return await _localAuth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          // biometricOnly: false - not needed, just omit the parameter
        ),
      );
    } catch (e) {
      print('Device PIN auth error: $e');
      return false;
    }
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
