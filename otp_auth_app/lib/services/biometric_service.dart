import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'secure_storage_service.dart';

class BiometricService {
  final LocalAuthentication _localAuth = LocalAuthentication();
  static const String _appPinKey = 'app_pin_hash';
  static const String _appPinEnabledKey = 'app_pin_enabled';
  static const String _hashedPinVersion = 'pinv1';
  final SecureStorageService _secureStorage = SecureStorageService();

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
    final pin = await _secureStorage.read(_appPinKey);
    return pin != null && pin.isNotEmpty;
  }

  Future<void> setAppPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await _secureStorage.write(_appPinKey, _hashPin(pin));
    await prefs.setBool(_appPinEnabledKey, true);
  }

  Future<bool> verifyAppPin(String pin) async {
    final storedPin = await _secureStorage.read(_appPinKey);
    if (storedPin == null || storedPin.isEmpty) return false;

    if (storedPin.startsWith('$_hashedPinVersion:')) {
      return _verifyHashedPin(pin, storedPin);
    }

    final isLegacyMatch = storedPin == pin;
    if (isLegacyMatch) {
      await setAppPin(pin);
    }
    return isLegacyMatch;
  }

  Future<void> deleteAppPin() async {
    final prefs = await SharedPreferences.getInstance();
    await _secureStorage.delete(_appPinKey);
    await prefs.setBool(_appPinEnabledKey, false);
  }

  String _hashPin(String pin) {
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final digest = sha256.convert([...salt, ...utf8.encode(pin)]).bytes;
    return '$_hashedPinVersion:${base64Encode(salt)}:${base64Encode(digest)}';
  }

  bool _verifyHashedPin(String pin, String storedValue) {
    final parts = storedValue.split(':');
    if (parts.length != 3 || parts[0] != _hashedPinVersion) {
      return false;
    }

    final salt = base64Decode(parts[1]);
    final expectedDigest = base64Decode(parts[2]);
    final actualDigest = sha256.convert([...salt, ...utf8.encode(pin)]).bytes;

    return _constantTimeEquals(expectedDigest, actualDigest);
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
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
