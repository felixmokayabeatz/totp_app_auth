import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'biometric_service.dart';

class AppLockService {
  final BiometricService _biometricService = BiometricService();

  static const String _appLockEnabledKey = 'app_lock_enabled';
  static const String _lastActiveTimeKey = 'last_active_time';
  static const String _lockTimeoutKey = 'lock_timeout_minutes';

  static const int _defaultTimeout = 0;

  Future<bool> isAppLockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_appLockEnabledKey) ?? true;
    if (!enabled) {
      await prefs.setBool(_appLockEnabledKey, true);
    }
    return true;
  }

  Future<void> setAppLockEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_appLockEnabledKey, true);
    await recordAppActivity();
  }

  Future<int> getLockTimeout() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_lockTimeoutKey) ?? _defaultTimeout;
  }

  Future<void> setLockTimeout(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lockTimeoutKey, minutes.clamp(0, 10));
  }

  Future<void> recordAppActivity() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _lastActiveTimeKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<bool> needsUnlock() async {
    final prefs = await SharedPreferences.getInstance();
    final lastActive = prefs.getInt(_lastActiveTimeKey);
    if (lastActive == null) {
      return true;
    }

    final timeoutMinutes = await getLockTimeout();
    if (timeoutMinutes == 0) {
      return true;
    }

    final lastActiveTime = DateTime.fromMillisecondsSinceEpoch(lastActive);
    final difference = DateTime.now().difference(lastActiveTime);
    return difference.inMinutes >= timeoutMinutes;
  }

  Future<void> ensureMandatoryLock(BuildContext context) async {
    await isAppLockEnabled();
    await setLockTimeout(_defaultTimeout);

    final canUseSystemAuth =
        await _biometricService.canUseSystemAuthentication();
    if (!canUseSystemAuth) {
      final hasPin = await _biometricService.hasAppPin();
      if (!hasPin && context.mounted) {
        await _showForceSetAppPinDialog(context);
      }
    }
  }

  Future<bool> authenticateToUnlock(BuildContext context) async {
    final canUseSystemAuth =
        await _biometricService.canUseSystemAuthentication();

    if (canUseSystemAuth) {
      final authenticated =
          await _biometricService.authenticateWithDeviceSystem(context);
      if (!authenticated && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication failed. Try again to continue.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return authenticated;
    }

    final hasPin = await _biometricService.hasAppPin();
    if (!hasPin) {
      final pinSet = await _showForceSetAppPinDialog(context);
      if (!pinSet) {
        return false;
      }
    }

    return _biometricService.authenticateWithAppPin(context);
  }

  Future<bool> _showForceSetAppPinDialog(BuildContext context) async {
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    final completer = Completer<bool>();

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Set your BeatzLock PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'This device does not have usable system security for BeatzLock, so you must create an app PIN.',
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
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () async {
              final pin = pinController.text.trim();
              final confirm = confirmController.text.trim();

              if (pin.length < 4) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('PIN must be at least 4 digits.'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

              if (pin != confirm) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('PINs do not match.'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

              await _biometricService.setAppPin(pin);
              completer.complete(true);
              Navigator.pop(dialogContext);
            },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    );

    pinController.dispose();
    confirmController.dispose();

    return completer.future;
  }

  Future<bool> setupAppPinFromSettings(BuildContext context) async {
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    final completer = Completer<bool>();

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Change BeatzLock PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Create a 4-6 digit PIN for app access.'),
            const SizedBox(height: 16),
            TextField(
              controller: pinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Enter PIN',
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
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              completer.complete(false);
              Navigator.pop(dialogContext);
            },
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final pin = pinController.text.trim();
              final confirm = confirmController.text.trim();

              if (pin.length < 4) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('PIN must be at least 4 digits.'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

              if (pin != confirm) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('PINs do not match.'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

              await _biometricService.setAppPin(pin);
              completer.complete(true);
              Navigator.pop(dialogContext);
            },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    );

    pinController.dispose();
    confirmController.dispose();

    return completer.future;
  }
}
