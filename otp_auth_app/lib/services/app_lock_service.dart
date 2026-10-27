import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'biometric_service.dart';









enum AppUnlockMethod {

  systemLock,


  appPin,
}


class UnlockMethodResolution {
  const UnlockMethodResolution({required this.method, required this.previous});


  final AppUnlockMethod method;



  final AppUnlockMethod? previous;



  bool get changed => previous != null && previous != method;
}

class AppLockService {
  final BiometricService _biometricService = BiometricService();

  static const String _appLockEnabledKey = 'app_lock_enabled';
  static const String _lastActiveTimeKey = 'last_active_time';
  static const String _lockTimeoutKey = 'lock_timeout_minutes';
  static const String _lockIntroShownKey = 'app_lock_intro_shown';
  static const String _lastKnownMethodKey = 'app_unlock_method_v1';

  static const int _defaultTimeout = 0;



  static final ValueNotifier<AppUnlockMethod?> methodChanges =
      ValueNotifier<AppUnlockMethod?>(null);


  Future<AppUnlockMethod> unlockMethod() async {
    return await _biometricService.canUseSystemAuthentication()
        ? AppUnlockMethod.systemLock
        : AppUnlockMethod.appPin;
  }








  Future<UnlockMethodResolution> reconcileUnlockMethod() async {
    final method = await unlockMethod();
    final prefs = await SharedPreferences.getInstance();
    final storedName = prefs.getString(_lastKnownMethodKey);

    AppUnlockMethod? previous;
    for (final candidate in AppUnlockMethod.values) {
      if (candidate.name == storedName) {
        previous = candidate;
        break;
      }
    }

    if (previous != method) {


      if (method == AppUnlockMethod.systemLock) {
        await _biometricService.deleteAppPin();
      }
      await prefs.setString(_lastKnownMethodKey, method.name);
    }

    methodChanges.value = method;
    return UnlockMethodResolution(method: method, previous: previous);
  }




  void invalidateUnlockMethodCache() {
    _biometricService.invalidateSystemAuthCache();
  }



  Future<bool> usesAppPin() async =>
      await unlockMethod() == AppUnlockMethod.appPin;

  Future<bool> isAppLockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_appLockEnabledKey) ?? true;
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







  Future<AppUnlockMethod> ensureMandatoryLock(BuildContext context) async {
    final resolution = await reconcileUnlockMethod();
    if (!context.mounted) return resolution.method;

    if (resolution.changed) {
      await _showMethodChangedNotice(context, resolution);
    } else {
      await _showMandatoryLockIntroIfNeeded(context, resolution.method);
    }
    if (!context.mounted) return resolution.method;


    if (resolution.method != AppUnlockMethod.appPin) return resolution.method;

    final hasPin = await _biometricService.hasAppPin();
    if (!hasPin && context.mounted) {
      await _showForceSetAppPinDialog(context);
    }
    return resolution.method;
  }








  Future<bool> authenticateToUnlock(BuildContext context) async {
    if (await _biometricService.canUseSystemAuthentication()) {
      final outcome = await _biometricService.authenticateWithSystem();
      switch (outcome) {
        case SystemAuthOutcome.success:
          return true;
        case SystemAuthOutcome.canceled:

          return false;
        case SystemAuthOutcome.unavailable:

          break;
      }
    }

    if (!context.mounted) return false;
    return authenticateWithPinOnly(context);
  }




  Future<bool> authenticateWithPinOnly(BuildContext context) async {
    if (await _biometricService.canUseSystemAuthentication()) {
      if (!context.mounted) return false;
      return authenticateToUnlock(context);
    }
    if (!context.mounted) return false;

    final hasPin = await _biometricService.hasAppPin();
    if (!context.mounted) return false;
    if (!hasPin) {



      return _showForceSetAppPinDialog(context);
    }

    return _biometricService.authenticateWithAppPin(context);
  }

  Future<void> _showMandatoryLockIntroIfNeeded(
    BuildContext context,
    AppUnlockMethod method,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_lockIntroShownKey) == true || !context.mounted) {
      return;
    }

    final usesSystemLock = method == AppUnlockMethod.systemLock;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('BeatzLock uses secure unlock'),
        content: Text(
          usesSystemLock
              ? 'Every time you open BeatzLock, this device unlocks it the same '
                  'way you unlock the device itself -- your PIN, pattern, '
                  'fingerprint or face. That is the only way in, so there is no '
                  'separate BeatzLock PIN to remember.'
              : 'This device has no screen lock BeatzLock can use, so you will '
                  'create a BeatzLock PIN instead. You will enter it every time '
                  'you open the app.',
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





  Future<void> _showMethodChangedNotice(
    BuildContext context,
    UnlockMethodResolution resolution,
  ) async {
    final toSystemLock = resolution.method == AppUnlockMethod.systemLock;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          toSystemLock ? Icons.fingerprint_rounded : Icons.pin_rounded,
          size: 32,
        ),
        title: Text(
          toSystemLock
              ? 'BeatzLock now uses your device unlock'
              : 'Your device screen lock is gone',
        ),
        content: Text(
          toSystemLock
              ? 'This device can now unlock itself, so BeatzLock opens the same '
                  'way you open the device -- your PIN, pattern, fingerprint or '
                  'face. Your old BeatzLock PIN has been deleted, because it is '
                  'no longer needed and you would not be able to change it from '
                  'here.'
              : 'Without a screen lock, this device cannot unlock BeatzLock for '
                  'you any more. Set a BeatzLock PIN now to keep your codes '
                  'protected -- you will enter it every time you open the app.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(toSystemLock ? 'Got it' : 'Set a PIN'),
          ),
        ],
      ),
    );
  }

  Future<bool> _showForceSetAppPinDialog(BuildContext context) async {
    return _showPinEntryDialog(
      context: context,
      title: 'Set your BeatzLock PIN',
      blurb:
          'This device has no screen lock BeatzLock can use, so a BeatzLock PIN '
          'protects your codes instead. You will enter it every time you open '
          'the app.',
      firstFieldHint: 'Enter 4-6 digit PIN',
      autofocusFirstField: true,
      cancelLabel: 'Not now',
    );
  }

  Future<bool> setupAppPinFromSettings(BuildContext context) async {

    if (await _biometricService.canUseSystemAuthentication()) {
      return false;
    }
    if (!context.mounted) return false;

    final hasExistingPin = await _biometricService.hasAppPin();
    if (!context.mounted) return false;

    if (hasExistingPin) {
      final authenticated = await authenticateToUnlock(context);
      if (!context.mounted || !authenticated) {
        return false;
      }
    }

    return _showPinEntryDialog(
      context: context,
      title: hasExistingPin ? 'Change BeatzLock PIN' : 'Set BeatzLock PIN',
      blurb: hasExistingPin
          ? 'Create a new 4-6 digit PIN for app access.'
          : 'Create a 4-6 digit PIN for app access.',
      firstFieldHint: 'New PIN',
      autofocusFirstField: !hasExistingPin,
      cancelLabel: 'Cancel',
    );
  }



  Future<bool> _showPinEntryDialog({
    required BuildContext context,
    required String title,
    required String blurb,
    required String firstFieldHint,
    required bool autofocusFirstField,
    required String cancelLabel,
  }) async {
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    String? pinErrorText;
    String? confirmErrorText;
    var obscurePin = true;
    var isSaving = false;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> save() async {
            if (isSaving) return;
            final pin = pinController.text.trim();
            final confirm = confirmController.text.trim();

            setDialogState(() {
              pinErrorText =
                  pin.length < 4 ? 'PIN must be at least 4 digits.' : null;
              confirmErrorText = pin != confirm ? 'PINs do not match.' : null;
            });

            if (pin.length < 4 || pin != confirm) return;

            setDialogState(() => isSaving = true);
            await _biometricService.setAppPin(pin);
            if (dialogContext.mounted) {
              Navigator.pop(dialogContext, true);
            }
          }

          Widget pinField({
            required TextEditingController controller,
            required String hint,
            required String? errorText,
            required bool autofocus,
            bool showToggle = false,
            VoidCallback? onSubmitted,
          }) {
            return TextField(
              controller: controller,
              obscureText: obscurePin,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: autofocus,
              enabled: !isSaving,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: (_) => onSubmitted?.call(),
              decoration: InputDecoration(
                hintText: hint,
                errorText: errorText,
                counterText: '',
                suffixIcon: showToggle
                    ? IconButton(
                        tooltip: obscurePin ? 'Show PIN' : 'Hide PIN',
                        icon: Icon(
                          obscurePin
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                        ),
                        onPressed: () =>
                            setDialogState(() => obscurePin = !obscurePin),
                      )
                    : null,
              ),
            );
          }

          return AlertDialog(
            scrollable: true,
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(blurb),
                const SizedBox(height: 16),
                pinField(
                  controller: pinController,
                  hint: firstFieldHint,
                  errorText: pinErrorText,
                  autofocus: autofocusFirstField,
                  showToggle: true,
                ),
                const SizedBox(height: 12),
                pinField(
                  controller: confirmController,
                  hint: 'Confirm PIN',
                  errorText: confirmErrorText,
                  autofocus: false,
                  onSubmitted: save,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed:
                    isSaving ? null : () => Navigator.pop(dialogContext, false),
                child: Text(cancelLabel),
              ),
              FilledButton(
                onPressed: isSaving ? null : save,
                child: const Text('Save PIN'),
              ),
            ],
          );
        },
      ),
    );

    pinController.dispose();
    confirmController.dispose();
    return result ?? false;
  }
}
