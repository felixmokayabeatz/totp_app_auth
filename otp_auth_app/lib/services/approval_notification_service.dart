import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApprovalNotificationService {
  ApprovalNotificationService._internal();

  static final ApprovalNotificationService _instance =
      ApprovalNotificationService._internal();
  static const String _passwordlessChannelId = 'passwordless_approvals';
  static const String _passwordlessChannelName = 'Passwordless approvals';
  static const String _passwordlessChannelDescription =
      'Sign-in approval alerts for passwordless requests.';
  static const int _passwordlessApprovalNotificationId = 42101;
  static const String _openPasswordlessApprovalsAction =
      'open_passwordless_approvals';
  static const String _lastShownPasswordlessRequestKey =
      'last_passwordless_notification_request_id';

  factory ApprovalNotificationService() => _instance;

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final ValueNotifier<int> passwordlessOpenSignal = ValueNotifier<int>(0);
  final ValueNotifier<int> passwordlessRequestSignal = ValueNotifier<int>(0);

  Future<void>? _initializationFuture;
  bool _launchDetailsChecked = false;
  bool _hasPendingPasswordlessOpenIntent = false;
  bool _notificationPermissionChecked = false;
  bool _notificationPermissionGranted = false;

  bool get hasPendingPasswordlessOpenIntent =>
      _hasPendingPasswordlessOpenIntent;

  Future<void> initialize() async {
    if (!Platform.isAndroid) {
      return;
    }

    final existingInitialization = _initializationFuture;
    if (existingInitialization != null) {
      await existingInitialization;
      return;
    }

    final initialization = _initializeInternal();
    _initializationFuture = initialization;
    await initialization;
  }

  Future<void> _initializeInternal() async {
    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );

    await _notifications.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );

    final androidImplementation =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImplementation?.createNotificationChannel(
      const AndroidNotificationChannel(
        _passwordlessChannelId,
        _passwordlessChannelName,
        description: _passwordlessChannelDescription,
        importance: Importance.high,
      ),
    );

    await _refreshLaunchDetailsIfNeeded();
  }

  Future<void> refreshPendingActionFromPlatform() async {
    if (!Platform.isAndroid) {
      return;
    }

    await initialize();
    await _refreshLaunchDetailsIfNeeded();
  }

  Future<void> _refreshLaunchDetailsIfNeeded() async {
    if (_launchDetailsChecked) {
      return;
    }

    final launchDetails =
        await _notifications.getNotificationAppLaunchDetails();
    _launchDetailsChecked = true;

    if (launchDetails?.didNotificationLaunchApp != true) {
      return;
    }

    _captureNotificationPayload(launchDetails?.notificationResponse?.payload);
  }

  void _handleNotificationResponse(NotificationResponse response) {
    _captureNotificationPayload(response.payload);
  }

  void _captureNotificationPayload(String? payload) {
    if (payload != _openPasswordlessApprovalsAction) {
      return;
    }

    _hasPendingPasswordlessOpenIntent = true;
    passwordlessOpenSignal.value = passwordlessOpenSignal.value + 1;
  }

  bool takePendingPasswordlessOpenIntent() {
    final hadPendingIntent = _hasPendingPasswordlessOpenIntent;
    _hasPendingPasswordlessOpenIntent = false;
    return hadPendingIntent;
  }

  void markPendingPasswordlessOpenIntent() {
    _captureNotificationPayload(_openPasswordlessApprovalsAction);
  }

  void notifyPasswordlessRequestArrivedInApp() {
    passwordlessRequestSignal.value = passwordlessRequestSignal.value + 1;
  }

  Future<bool> _ensureNotificationPermission() async {
    if (!Platform.isAndroid) {
      return false;
    }

    await initialize();
    if (_notificationPermissionChecked) {
      return _notificationPermissionGranted;
    }

    final androidImplementation =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    try {
      final granted =
          await androidImplementation?.requestNotificationsPermission();
      _notificationPermissionGranted = granted ?? true;
    } catch (_) {
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
    if (!Platform.isAndroid) {
      return;
    }

    final trimmedRequestId = requestId.trim();
    if (trimmedRequestId.isEmpty) {
      return;
    }

    final canNotify = await _ensureNotificationPermission();
    if (!canNotify) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final lastShownRequestId =
        prefs.getString(_lastShownPasswordlessRequestKey) ?? '';
    if (lastShownRequestId == trimmedRequestId) {
      return;
    }

    final label = requesterDeviceLabel.trim().isEmpty
        ? 'another device'
        : requesterDeviceLabel.trim();

    await _notifications.show(
      id: _passwordlessApprovalNotificationId,
      title: 'Approve sign-in in BeatzLock',
      body: '$label is asking to sign in. Tap to open BeatzLock.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _passwordlessChannelId,
          _passwordlessChannelName,
          channelDescription: _passwordlessChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          visibility: NotificationVisibility.private,
          onlyAlertOnce: true,
        ),
      ),
      payload: _openPasswordlessApprovalsAction,
    );

    await prefs.setString(_lastShownPasswordlessRequestKey, trimmedRequestId);
  }

  Future<void> clearPasswordlessApprovalNotification() async {
    if (!Platform.isAndroid) {
      return;
    }

    await initialize();
    await _notifications.cancel(id: _passwordlessApprovalNotificationId);

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastShownPasswordlessRequestKey);
  }
}
