class DeviceSessionInfo {
  final String id;
  final String deviceId;
  final String deviceLabel;
  final String deviceKind;
  final String ipAddress;
  final bool isActive;
  final bool isPrimary;
  final bool isCurrent;
  final bool pushReady;
  final String pushStatusText;
  final String pushPlatform;
  final DateTime? pushTokenUpdatedAt;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  const DeviceSessionInfo({
    required this.id,
    required this.deviceId,
    required this.deviceLabel,
    required this.deviceKind,
    required this.ipAddress,
    required this.isActive,
    required this.isPrimary,
    required this.isCurrent,
    required this.pushReady,
    required this.pushStatusText,
    required this.pushPlatform,
    required this.pushTokenUpdatedAt,
    required this.createdAt,
    required this.lastSeenAt,
  });

  factory DeviceSessionInfo.fromJson(Map<String, dynamic> json) {
    return DeviceSessionInfo(
      id: json['id']?.toString() ?? '',
      deviceId: json['device_id']?.toString() ?? '',
      deviceLabel: json['device_label']?.toString() ?? 'Unknown device',
      deviceKind: json['device_kind']?.toString() ?? 'unknown',
      ipAddress: json['ip_address']?.toString() ?? '',
      isActive: json['is_active'] == true,
      isPrimary: json['is_primary'] == true,
      isCurrent: json['is_current'] == true,
      pushReady: json['push_ready'] == true,
      pushStatusText: json['push_status_text']?.toString() ?? '',
      pushPlatform: json['push_platform']?.toString() ?? '',
      pushTokenUpdatedAt: DateTime.tryParse(
        json['push_token_updated_at']?.toString() ?? '',
      ),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      lastSeenAt: DateTime.tryParse(json['last_seen_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}
