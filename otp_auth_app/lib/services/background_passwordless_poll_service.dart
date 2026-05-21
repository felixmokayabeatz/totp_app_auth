import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../models/device_session_info.dart';
import 'approval_notification_service.dart';
import 'secure_storage_service.dart';
import 'sync_service.dart';

@pragma('vm:entry-point')
void passwordlessApprovalBackgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();

    if (!Platform.isAndroid) {
      return true;
    }

    if (task != BackgroundPasswordlessPollService.taskName) {
      return true;
    }

    try {
      await BackgroundPasswordlessPollService().runBackgroundPoll();
    } catch (error, stackTrace) {
      debugPrint(
        'Background passwordless poll failed: $error\n$stackTrace',
      );
    }

    return true;
  });
}

class BackgroundPasswordlessPollService {
  BackgroundPasswordlessPollService._internal();

  static final BackgroundPasswordlessPollService _instance =
      BackgroundPasswordlessPollService._internal();
  static const String uniqueWorkName = 'passwordless-approval-poll';
  static const String taskName = 'passwordlessApprovalPoll';
  static const Duration _minimumFrequency = Duration(minutes: 15);
  static const Duration _initialDelay = Duration(minutes: 1);

  factory BackgroundPasswordlessPollService() => _instance;

  Future<void>? _initializationFuture;

  Future<void> initialize() async {
    if (!Platform.isAndroid) {
      return;
    }

    final existingInitialization = _initializationFuture;
    if (existingInitialization != null) {
      await existingInitialization;
      return;
    }

    final initialization = Workmanager().initialize(
      passwordlessApprovalBackgroundCallbackDispatcher,
    );
    _initializationFuture = initialization;
    await initialization;
  }

  Future<void> syncRegistration({
    required bool enabled,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }

    await initialize();

    if (!enabled) {
      await Workmanager().cancelByUniqueName(uniqueWorkName);
      await ApprovalNotificationService()
          .clearPasswordlessApprovalNotification();
      return;
    }

    await Workmanager().registerPeriodicTask(
      uniqueWorkName,
      taskName,
      frequency: _minimumFrequency,
      initialDelay: _initialDelay,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.linear,
      backoffPolicyDelay: const Duration(minutes: 1),
      tag: 'passwordless-approvals',
    );
  }

  Future<void> runBackgroundPoll() async {
    if (!Platform.isAndroid) {
      return;
    }

    await SecureStorageService().init();
    final approvalNotifications = ApprovalNotificationService();
    await approvalNotifications.initialize();

    final syncService = SyncService();
    if (!await syncService.isLoggedIn()) {
      await approvalNotifications.clearPasswordlessApprovalNotification();
      return;
    }

    final sessions = await syncService.getActiveDeviceSessions();
    final currentSession = sessions.cast<DeviceSessionInfo?>().firstWhere(
          (session) => session?.isCurrent == true,
          orElse: () => null,
        );
    final canShowPasswordlessNotification = currentSession != null &&
        currentSession.isPrimary &&
        currentSession.deviceKind == 'mobile';

    if (!canShowPasswordlessNotification) {
      await approvalNotifications.clearPasswordlessApprovalNotification();
      return;
    }

    final requests = await syncService.getPasswordlessRequests();
    Map<String, dynamic>? pendingRequest;
    for (final request in requests) {
      if ((request['status']?.toString() ?? '').toLowerCase() == 'pending') {
        pendingRequest = request;
        break;
      }
    }

    if (pendingRequest == null) {
      await approvalNotifications.clearPasswordlessApprovalNotification();
      return;
    }

    final requestId = pendingRequest['id']?.toString().trim() ?? '';
    if (requestId.isEmpty) {
      await approvalNotifications.clearPasswordlessApprovalNotification();
      return;
    }

    final requesterDeviceLabel =
        pendingRequest['requester_device_label']?.toString() ??
            'another device';
    await approvalNotifications.showPasswordlessApprovalNotification(
      requestId: requestId,
      requesterDeviceLabel: requesterDeviceLabel,
    );
  }
}
