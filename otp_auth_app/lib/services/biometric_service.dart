import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'secure_storage_service.dart';










enum SystemAuthOutcome {

  success,



  canceled,



  unavailable,
}

class BiometricService {



  static final LocalAuthentication _localAuth = LocalAuthentication();
  static bool? _cachedSystemAuthAvailable;

  static const String _appPinKey = 'app_pin_hash';
  static const String _appPinEnabledKey = 'app_pin_enabled';
  static const String _hashedPinVersion = 'pinv1';
  final SecureStorageService _secureStorage = SecureStorageService();

  Future<void> init() async {

    await canUseSystemAuthentication();
  }


  Future<bool> isDeviceAuthenticationAvailable() async {
    try {
      return await _localAuth.isDeviceSupported();
    } catch (e) {
      return false;
    }
  }





  Future<bool> canUseSystemAuthentication() async {
    final cached = _cachedSystemAuthAvailable;
    if (cached != null) return cached;

    final available = (isMobile() || isWindowsDesktop())
        ? await isDeviceAuthenticationAvailable()
        : false;
    _cachedSystemAuthAvailable = available;
    return available;
  }



  void invalidateSystemAuthCache() {
    _cachedSystemAuthAvailable = null;
  }








  static const Set<LocalAuthExceptionCode> _systemAuthBrokenCodes = {
    LocalAuthExceptionCode.noCredentialsSet,
    LocalAuthExceptionCode.uiUnavailable,
    LocalAuthExceptionCode.deviceError,
    LocalAuthExceptionCode.unknownError,
  };


  Future<SystemAuthOutcome> authenticateWithSystem() async {
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Unlock BeatzLock',
        persistAcrossBackgrounding: true,
        biometricOnly: false, 
      );
      return authenticated
          ? SystemAuthOutcome.success
          : SystemAuthOutcome.canceled;
    } on LocalAuthException catch (e) {
      debugPrint(
        'Device auth local_auth error: ${e.code.name} ${e.description}',
      );
      if (_systemAuthBrokenCodes.contains(e.code)) {
        invalidateSystemAuthCache();
        return SystemAuthOutcome.unavailable;
      }
      return SystemAuthOutcome.canceled;
    } on PlatformException catch (e) {
      debugPrint('Device auth platform error: ${e.code} ${e.message}');
      invalidateSystemAuthCache();
      return SystemAuthOutcome.unavailable;
    } catch (e) {
      debugPrint('Device auth error: $e');
      return SystemAuthOutcome.canceled;
    }
  }



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
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
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


  Future<bool> authenticateWithAppPin(BuildContext context) async {
    if (!context.mounted) return false;

    final pinController = TextEditingController();
    String? errorText;
    var obscurePin = true;
    var isChecking = false;

    final resolved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> submit() async {
            if (isChecking) return;
            setDialogState(() => isChecking = true);
            final isValid = await verifyAppPin(pinController.text.trim());
            if (!dialogContext.mounted) return;
            if (isValid) {
              Navigator.pop(dialogContext, true);
              return;
            }
            setDialogState(() {
              isChecking = false;
              errorText = 'Invalid PIN';
            });
          }

          return AlertDialog(
            scrollable: true,
            title: const Text('Enter PIN'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: pinController,
                  obscureText: obscurePin,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  autofocus: true,
                  onSubmitted: (_) => submit(),
                  decoration: InputDecoration(
                    hintText: 'Enter your 4-6 digit PIN',
                    border: const OutlineInputBorder(),
                    errorText: errorText,
                    suffixIcon: IconButton(
                      tooltip: obscurePin ? 'Show PIN' : 'Hide PIN',
                      icon: Icon(
                        obscurePin
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                      ),
                      onPressed: () =>
                          setDialogState(() => obscurePin = !obscurePin),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: isChecking
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: isChecking ? null : submit,
                child: const Text('Unlock'),
              ),
            ],
          );
        },
      ),
    );

    pinController.dispose();
    return resolved ?? false;
  }


  bool isDesktop() {
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  bool isWindowsDesktop() {
    return Platform.isWindows;
  }


  bool isMobile() {
    return Platform.isAndroid || Platform.isIOS;
  }
}
