class WindowsInitializationSettings {
  const WindowsInitializationSettings({
    this.appName = 'BeatzLock Authenticator',
    this.appUserModelId = 'BeatzLock.Authenticator',
    this.guid = '00000000-0000-0000-0000-000000000000',
    this.iconPath,
  });

  final String appName;
  final String appUserModelId;
  final String guid;
  final String? iconPath;
}

class WindowsProgressBar {
  const WindowsProgressBar({
    this.data = const <String, String>{},
  });

  final Map<String, String> data;
}

class WindowsNotificationDetails {
  const WindowsNotificationDetails({
    this.bindings = const <String, String>{},
    this.progressBars = const <WindowsProgressBar>[],
  });

  final Map<String, String> bindings;
  final List<WindowsProgressBar> progressBars;
}

enum NotificationUpdateResult {
  success,
  error,
  notFound,
}
