import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'biometric_service.dart';

class AppLockService {
  final BiometricService _biometricService = BiometricService();

  static const String _appLockEnabledKey = 'app_lock_enabled';
  static const String _lastActiveTimeKey = 'last_active_time';
  static const String _lockTimeoutKey = 'lock_timeout_minutes';
  static const String _lockIntroShownKey = 'app_lock_intro_shown';

  static const int _defaultTimeout = 0;

  Future<bool> isAppLockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_appLockEnabledKey) ?? true;
    if (!enabled) {
      return false;
    }
    return enabled;
  }

  Future<void> setAppLockEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_appLockEnabledKey, enabled);
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
    if (!context.mounted) return;
    await _showMandatoryLockIntroIfNeeded(context);
    if (!context.mounted) return;

    final canUseSystemAuth = await _biometricService
        .canUseSystemAuthentication();
    if (!canUseSystemAuth) {
      final hasPin = await _biometricService.hasAppPin();
      if (!hasPin && context.mounted) {
        await _showForceSetAppPinDialog(context);
      }
    }
  }

  Future<bool> authenticateToUnlock(BuildContext context) async {
    final canUseSystemAuth = await _biometricService
        .canUseSystemAuthentication();
    if (!context.mounted) return false;

    if (canUseSystemAuth) {
      final authenticated = await _biometricService
          .authenticateWithDeviceSystem(context);
      if (!context.mounted) return false;
      if (authenticated) {
        return true;
      }

      return authenticateWithPinOnly(context);
    }

    return authenticateWithPinOnly(context);
  }

  Future<bool> authenticateWithPinOnly(BuildContext context) async {
    final hasPin = await _biometricService.hasAppPin();
    if (!context.mounted) return false;
    if (!hasPin) {
      final pinSet = await _showForceSetAppPinDialog(context);
      if (!context.mounted) return false;
      if (!pinSet) {
        return false;
      }
    }

    return _biometricService.authenticateWithAppPin(context);
  }

  Future<void> _showMandatoryLockIntroIfNeeded(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_lockIntroShownKey) == true || !context.mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('BeatzLock uses secure unlock'),
        content: const Text(
          'When you open the app, use your device PIN, fingerprint, face unlock, or your BeatzLock PIN to unlock your saved codes.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Continue'),
          ),
        ],
      ),
    );

    await prefs.setBool(_lockIntroShownKey, true);
  }

  Future<bool> _showForceSetAppPinDialog(BuildContext context) async {
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    String? pinErrorText;
    String? confirmErrorText;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
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
                decoration: InputDecoration(
                  hintText: 'Enter 4-6 digit PIN',
                  errorText: pinErrorText,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  hintText: 'Confirm PIN',
                  errorText: confirmErrorText,
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () async {
                final pin = pinController.text.trim();
                final confirm = confirmController.text.trim();

                setDialogState(() {
                  pinErrorText = pin.length < 4
                      ? 'PIN must be at least 4 digits.'
                      : null;
                  confirmErrorText = pin != confirm
                      ? 'PINs do not match.'
                      : null;
                });

                if (pin.length < 4 || pin != confirm) {
                  return;
                }

                await _biometricService.setAppPin(pin);
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext, true);
                }
              },
              child: const Text('Save PIN'),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  Future<bool> setupAppPinFromSettings(BuildContext context) async {
    final hasExistingPin = await _biometricService.hasAppPin();
    if (!context.mounted) return false;

    final currentController = TextEditingController();
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    String? currentErrorText;
    String? pinErrorText;
    String? confirmErrorText;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            hasExistingPin ? 'Change BeatzLock PIN' : 'Set BeatzLock PIN',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                hasExistingPin
                    ? 'Confirm your current PIN, then create a new 4-6 digit PIN.'
                    : 'Create a 4-6 digit PIN for app access.',
              ),
              const SizedBox(height: 16),
              if (hasExistingPin) ...[
                TextField(
                  controller: currentController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Current PIN',
                    errorText: currentErrorText,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofocus: !hasExistingPin,
                decoration: InputDecoration(
                  hintText: 'New PIN',
                  errorText: pinErrorText,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  hintText: 'Confirm PIN',
                  errorText: confirmErrorText,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final currentPin = currentController.text.trim();
                final pin = pinController.text.trim();
                final confirm = confirmController.text.trim();
                final currentPinValid =
                    !hasExistingPin ||
                    await _biometricService.verifyAppPin(currentPin);

                setDialogState(() {
                  currentErrorText = currentPinValid
                      ? null
                      : 'Current PIN is incorrect.';
                  pinErrorText = pin.length < 4
                      ? 'PIN must be at least 4 digits.'
                      : null;
                  confirmErrorText = pin != confirm
                      ? 'PINs do not match.'
                      : null;
                });

                if (!currentPinValid || pin.length < 4 || pin != confirm) {
                  return;
                }

                await _biometricService.setAppPin(pin);
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext, true);
                }
              },
              child: const Text('Save PIN'),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }
}
