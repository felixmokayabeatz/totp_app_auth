import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ApprovalNotificationService {
  ApprovalNotificationService._internal();

  static final ApprovalNotificationService _instance =
      ApprovalNotificationService._internal();
  static const MethodChannel _channel =
      MethodChannel('com.beatzlock.otp/notifications');
  static const String _openPasswordlessApprovalsAction =
      'open_passwordless_approvals';

  factory ApprovalNotificationService() => _instance;

  final ValueNotifier<int> passwordlessOpenSignal = ValueNotifier<int>(0);

  bool _hasPendingPasswordlessOpenIntent = false;
  bool _notificationPermissionChecked = false;
  bool _notificationPermissionGranted = false;

  bool get hasPendingPasswordlessOpenIntent =>
      _hasPendingPasswordlessOpenIntent;

  Future<void> refreshPendingActionFromPlatform() async {
    if (!Platform.isAndroid) return;

    try {
      final action =
          await _channel.invokeMethod<String>('consumePendingNotificationAction');
      if (action == _openPasswordlessApprovalsAction) {
        _hasPendingPasswordlessOpenIntent = true;
        passwordlessOpenSignal.value = passwordlessOpenSignal.value + 1;
      }
    } on PlatformException {
      // Ignore notification tap refresh failures and keep the normal in-app flow.
    }
  }

  bool takePendingPasswordlessOpenIntent() {
    final hadPendingIntent = _hasPendingPasswordlessOpenIntent;
    _hasPendingPasswordlessOpenIntent = false;
    return hadPendingIntent;
  }

  Future<bool> _ensureNotificationPermission() async {
    if (!Platform.isAndroid) {
      return false;
    }
    if (_notificationPermissionChecked) {
      return _notificationPermissionGranted;
    }

    try {
      final granted =
          await _channel.invokeMethod<bool>('requestNotificationPermission');
      _notificationPermissionGranted = granted ?? false;
    } on PlatformException {
      _notificationPermissionGranted = false;
    } finally {
      _notificationPermissionChecked = true;
    }

    return _notificationPermissionGranted;
  }

  Future<void> showPasswordlessApprovalNotification({
    required String requestId,
    required String requesterDeviceLabel,
  }) async {
    if (!Platform.isAndroid) return;

    final canNotify = await _ensureNotificationPermission();
    if (!canNotify) return;

    final label = requesterDeviceLabel.trim().isEmpty
        ? 'another device'
        : requesterDeviceLabel.trim();
    try {
      await _channel.invokeMethod<void>(
        'showPasswordlessApprovalNotification',
        {
          'requestId': requestId,
          'requesterDeviceLabel': label,
        },
      );
    } on PlatformException {
      // Keep passwordless approvals working even if Android notifications fail.
    }
  }

  Future<void> clearPasswordlessApprovalNotification() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod<void>('clearPasswordlessApprovalNotification');
    } on PlatformException {
      // Ignore best-effort cleanup failures.
    }
  }
}
