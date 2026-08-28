import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'biometric_service.dart';

/// Which single unlock method this device uses.
///
/// BeatzLock deliberately uses one method, never two. A device with an
/// operating system lock (phone PIN, pattern, fingerprint, face, Windows Hello)
/// uses only that; a device without one uses only the BeatzLock PIN. Backing
/// out of the system prompt returns the user to the lock screen instead of
/// opening a PIN pad, because a second unlock path would be a second door into
/// the same vault -- and usually a weaker one.
enum AppUnlockMethod {
  /// The operating system's own lock.
  systemLock,

  /// The BeatzLock PIN, for devices with no system lock available.
  appPin,
}

/// The result of re-checking which unlock method a device uses.
class UnlockMethodResolution {
  const UnlockMethodResolution({required this.method, required this.previous});

  /// What this device uses now.
  final AppUnlockMethod method;

  /// What it used last time BeatzLock looked, or null the first time -- an
  /// install has no previous method, so its first resolution is not a change.
  final AppUnlockMethod? previous;

  /// True when the device genuinely switched methods, which is the only case
  /// worth interrupting the user about.
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

  /// Broadcasts the current method so screens already on-screen follow a switch
  /// instead of showing what was true when they were opened.
  static final ValueNotifier<AppUnlockMethod?> methodChanges =
      ValueNotifier<AppUnlockMethod?>(null);

  /// The one unlock method this device uses.
  Future<AppUnlockMethod> unlockMethod() async {
    return await _biometricService.canUseSystemAuthentication()
        ? AppUnlockMethod.systemLock
        : AppUnlockMethod.appPin;
  }

  /// Re-checks the device and brings stored state in line with what it finds.
  ///
  /// Gaining a screen lock deletes the BeatzLock PIN: its only reason to exist
  /// was that the OS could not do the job, and a credential the user can no
  /// longer see or change must not be able to quietly become the way in again
  /// months later. Losing a screen lock therefore always means creating a fresh
  /// PIN rather than recalling a forgotten one -- there is no PIN recovery.
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
      // Runs on the first resolution too, which clears the orphaned PIN left
      // behind on devices that used to be offered both methods.
      if (method == AppUnlockMethod.systemLock) {
        await _biometricService.deleteAppPin();
      }
      await prefs.setString(_lastKnownMethodKey, method.name);
    }

    methodChanges.value = method;
    return UnlockMethodResolution(method: method, previous: previous);
  }

  /// Forgets the cached capability answer so the next check asks the platform
  /// again. Call this when the device may have changed underneath the app --
  /// on resume, the user may just have come back from the system settings.
  void invalidateUnlockMethodCache() {
    _biometricService.invalidateSystemAuthCache();
  }

  /// True when the BeatzLock PIN is this device's unlock method. When false the
  /// PIN is not offered anywhere -- not on the lock screen, not in Settings.
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

  /// Re-checks the device, tells the user if the way in changed, and makes sure
  /// a device that needs a BeatzLock PIN has one.
  ///
  /// Safe to call repeatedly -- on launch, and on every resume, which is when a
  /// user coming back from the system settings may just have added or removed
  /// their screen lock.
  Future<AppUnlockMethod> ensureMandatoryLock(BuildContext context) async {
    final resolution = await reconcileUnlockMethod();
    if (!context.mounted) return resolution.method;

    if (resolution.changed) {
      await _showMethodChangedNotice(context, resolution);
    } else {
      await _showMandatoryLockIntroIfNeeded(context, resolution.method);
    }
    if (!context.mounted) return resolution.method;

    // A BeatzLock PIN is only ever required on a device the OS cannot unlock.
    if (resolution.method != AppUnlockMethod.appPin) return resolution.method;

    final hasPin = await _biometricService.hasAppPin();
    if (!hasPin && context.mounted) {
      await _showForceSetAppPinDialog(context);
    }
    return resolution.method;
  }

  /// Unlocks with this device's single unlock method.
  ///
  /// On a device with a system lock this runs the OS prompt and nothing else:
  /// cancelling it returns false so the caller keeps the user on the lock
  /// screen. The BeatzLock PIN is reached only if the OS reports that it can no
  /// longer authenticate at all, at which point the device has genuinely
  /// switched methods.
  Future<bool> authenticateToUnlock(BuildContext context) async {
    if (await _biometricService.canUseSystemAuthentication()) {
      final outcome = await _biometricService.authenticateWithSystem();
      switch (outcome) {
        case SystemAuthOutcome.success:
          return true;
        case SystemAuthOutcome.canceled:
          // The user aborted. Stay locked -- do not open the PIN pad.
          return false;
        case SystemAuthOutcome.unavailable:
          // The device lost its screen lock, so this device now uses the PIN.
          break;
      }
    }

    if (!context.mounted) return false;
    return authenticateWithPinOnly(context);
  }

  /// Unlocks with the BeatzLock PIN. Only valid on a device with no system
  /// lock; on any other device it defers to [authenticateToUnlock] so the PIN
  /// can never become a bypass for the OS prompt.
  Future<bool> authenticateWithPinOnly(BuildContext context) async {
    if (await _biometricService.canUseSystemAuthentication()) {
      if (!context.mounted) return false;
      return authenticateToUnlock(context);
    }
    if (!context.mounted) return false;

    final hasPin = await _biometricService.hasAppPin();
    if (!context.mounted) return false;
    if (!hasPin) {
      // Whoever just chose the PIN is the person holding the device, so making
      // them immediately type back what they typed ten seconds ago proves
      // nothing. Cancelling the setup still leaves the app locked.
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

  /// Tells the user the way into BeatzLock just changed, and why.
  ///
  /// A security app that silently swaps its own front door is a support ticket
  /// waiting to happen, so both directions get said out loud.
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
    // On a device the OS can unlock, there is no BeatzLock PIN to change.
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

  /// The single PIN create/confirm dialog, shared by first-run setup and
  /// Settings so the two cannot drift apart.
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
