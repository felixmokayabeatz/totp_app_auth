import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

class BiometricService {
  final LocalAuthentication _localAuth = LocalAuthentication();
  static const String _appPinKey = 'app_pin_hash';
  static const String _appPinEnabledKey = 'app_pin_enabled';

  Future<void> init() async {}

  // Check if device has system authentication (for mobile)
  Future<bool> isDeviceAuthenticationAvailable() async {
    try {
      return await _localAuth.isDeviceSupported();
    } catch (e) {
      return false;
    }
  }

  // For mobile - use system PIN/Pattern/Fingerprint
  Future<bool> authenticateWithDeviceSystem(BuildContext context) async {
    try {
      return await _localAuth.authenticate(
        localizedReason: 'Unlock BeatzLock',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false, // Allow PIN/Pattern/Password
        ),
      );
    } on PlatformException catch (e) {
      debugPrint('Device auth platform error: ${e.code} ${e.message}');
      return false;
    } catch (e) {
      debugPrint('Device auth error: $e');
      return false;
    }
  }

  Future<bool> canUseSystemAuthentication() async {
    if (isMobile() || isWindowsDesktop()) {
      return await isDeviceAuthenticationAvailable();
    }
    return false;
  }

  // ========== APP PIN (for Desktop) ==========

  Future<bool> isAppPinEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_appPinEnabledKey) ?? false;
  }

  Future<void> setAppPinEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_appPinEnabledKey, enabled);
  }

  Future<bool> hasAppPin() async {
    final prefs = await SharedPreferences.getInstance();
    final pin = prefs.getString(_appPinKey);
    return pin != null && pin.isNotEmpty;
  }

  Future<void> setAppPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appPinKey, pin);
    await prefs.setBool(_appPinEnabledKey, true);
  }

  Future<bool> verifyAppPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final storedPin = prefs.getString(_appPinKey);
    return storedPin == pin;
  }

  Future<void> deleteAppPin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_appPinKey);
    await prefs.setBool(_appPinEnabledKey, false);
  }

  // For Desktop - authenticate with App PIN
  // For Desktop - authenticate with App PIN
  Future<bool> authenticateWithAppPin(BuildContext context) async {
    if (!context.mounted) return false;

    final pinController = TextEditingController();
    String? errorText;

    final resolved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Enter PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Enter your 4-6 digit PIN',
                  border: const OutlineInputBorder(),
                  errorText: errorText,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final isValid = await verifyAppPin(pinController.text.trim());
                if (isValid) {
                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext, true);
                  }
                  return;
                }

                setDialogState(() {
                  errorText = 'Invalid PIN';
                });
              },
              child: const Text('Unlock'),
            ),
          ],
        ),
      ),
    );
    return resolved ?? false;
  }

  // Check if we're on desktop
  bool isDesktop() {
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  bool isWindowsDesktop() {
    return Platform.isWindows;
  }

  // Check if we're on mobile
  bool isMobile() {
    return Platform.isAndroid || Platform.isIOS;
  }
}
