import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:timezone/timezone.dart';

import '../details.dart';

export 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
export 'package:timezone/timezone.dart';

abstract class WindowsNotificationsBase
    extends FlutterLocalNotificationsPlatform {
  Future<bool> initialize({
    required WindowsInitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
  });

  void dispose();

  Future<void> showRawXml({
    required int id,
    required String xml,
    Map<String, String> bindings = const <String, String>{},
  });

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    String? payload,
    WindowsNotificationDetails? notificationDetails,
  });

  Future<void> zonedSchedule({
    required int id,
    String? title,
    String? body,
    required TZDateTime scheduledDate,
    WindowsNotificationDetails? notificationDetails,
    String? payload,
  });

  Future<void> zonedScheduleRawXml({
    required int id,
    required String xml,
    required TZDateTime scheduledDate,
  });

  Future<NotificationUpdateResult> updateProgressBar({
    required int notificationId,
    required WindowsProgressBar progressBar,
  }) => updateBindings(id: notificationId, bindings: progressBar.data);

  Future<NotificationUpdateResult> updateBindings({
    required int id,
    required Map<String, String> bindings,
  });

  bool isValidXml(String xml);
}
