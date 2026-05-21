import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'approval_notification_service.dart';
import 'sync_service.dart';

const String _passwordlessOpenApprovalsAction = 'open_passwordless_approvals';

bool _isPasswordlessApprovalMessage(RemoteMessage message) {
  final action = message.data['action']?.toString().trim() ?? '';
  final event = message.data['event']?.toString().trim() ?? '';
  return action == _passwordlessOpenApprovalsAction ||
      event == 'passwordless_request';
}

@pragma('vm:entry-point')
Future<void> firebasePasswordlessBackgroundMessageHandler(
  RemoteMessage message,
) async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!Platform.isAndroid) {
    return;
  }

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (error) {
    debugPrint('Firebase background init failed: $error');
  }

  if (!_isPasswordlessApprovalMessage(message)) {
    return;
  }

  if (message.notification != null) {
    return;
  }

  final approvalNotifications = ApprovalNotificationService();
  await approvalNotifications.initialize();
  await approvalNotifications.showPasswordlessApprovalNotification(
    requestId: message.data['request_id']?.toString().trim() ?? '',
    requesterDeviceLabel:
        message.data['requester_device_label']?.toString() ?? 'another device',
  );
}

class PushMessagingService {
  PushMessagingService._internal();

  static final PushMessagingService _instance =
      PushMessagingService._internal();
  static const String _registeredTokenKey = 'registered_fcm_push_token';
  static const String _registeredUserKey = 'registered_fcm_push_user';

  factory PushMessagingService() => _instance;

  FirebaseMessaging? _messaging;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  StreamSubscription<RemoteMessage>? _messageOpenedSubscription;
  StreamSubscription<String>? _tokenRefreshSubscription;
  Future<void>? _initializationFuture;

  FirebaseMessaging get _messagingInstance =>
      _messaging ??= FirebaseMessaging.instance;

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
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
    } catch (error) {
      debugPrint('Firebase init failed: $error');
      return;
    }

    FirebaseMessaging.onBackgroundMessage(
      firebasePasswordlessBackgroundMessageHandler,
    );
    await ApprovalNotificationService().initialize();
    await _messagingInstance.setAutoInitEnabled(true);
    await _messagingInstance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    _messageSubscription ??= FirebaseMessaging.onMessage.listen(
      _handleForegroundMessage,
    );
    _messageOpenedSubscription ??= FirebaseMessaging.onMessageOpenedApp.listen(
      _handleOpenedMessage,
    );
    _tokenRefreshSubscription ??= _messagingInstance.onTokenRefresh.listen((_) {
      unawaited(syncCurrentPushTokenIfPossible(force: true));
    });

    final initialMessage = await _messagingInstance.getInitialMessage();
    if (initialMessage != null) {
      _handleOpenedMessage(initialMessage);
    }
  }

  Future<void> syncCurrentPushTokenIfPossible({bool force = false}) async {
    if (!Platform.isAndroid) {
      return;
    }

    await initialize();

    final syncService = SyncService();
    if (!await syncService.isLoggedIn()) {
      await _clearLocalRegistrationCache();
      return;
    }

    final token = await _messagingInstance.getToken();
    final trimmedToken = token?.trim() ?? '';
    if (trimmedToken.isEmpty) {
      return;
    }

    final currentUser = (await syncService.getCurrentUser())?.trim() ?? '';
    final prefs = await SharedPreferences.getInstance();
    if (!force &&
        prefs.getString(_registeredTokenKey) == trimmedToken &&
        prefs.getString(_registeredUserKey) == currentUser) {
      return;
    }

    final registered = await syncService.registerPushToken(
      token: trimmedToken,
      platform: 'android',
      reportError: false,
    );
    if (!registered) {
      return;
    }

    await prefs.setString(_registeredTokenKey, trimmedToken);
    await prefs.setString(_registeredUserKey, currentUser);
  }

  Future<void> _clearLocalRegistrationCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_registeredTokenKey);
    await prefs.remove(_registeredUserKey);
  }

  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    if (!_isPasswordlessApprovalMessage(message)) {
      return;
    }

    await ApprovalNotificationService().showPasswordlessApprovalNotification(
      requestId: message.data['request_id']?.toString().trim() ?? '',
      requesterDeviceLabel:
          message.data['requester_device_label']?.toString() ??
              'another device',
    );
  }

  void _handleOpenedMessage(RemoteMessage message) {
    if (!_isPasswordlessApprovalMessage(message)) {
      return;
    }

    ApprovalNotificationService().markPendingPasswordlessOpenIntent();
  }
}
