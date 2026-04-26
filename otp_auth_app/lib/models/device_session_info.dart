class DeviceSessionInfo {
  final String id;
  final String deviceId;
  final String deviceLabel;
  final String ipAddress;
  final bool isActive;
  final bool isPrimary;
  final bool isCurrent;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  const DeviceSessionInfo({
    required this.id,
    required this.deviceId,
    required this.deviceLabel,
    required this.ipAddress,
    required this.isActive,
    required this.isPrimary,
    required this.isCurrent,
    required this.createdAt,
    required this.lastSeenAt,
  });

  factory DeviceSessionInfo.fromJson(Map<String, dynamic> json) {
    return DeviceSessionInfo(
      id: json['id']?.toString() ?? '',
      deviceId: json['device_id']?.toString() ?? '',
      deviceLabel: json['device_label']?.toString() ?? 'Unknown device',
      ipAddress: json['ip_address']?.toString() ?? '',
      isActive: json['is_active'] == true,
      isPrimary: json['is_primary'] == true,
      isCurrent: json['is_current'] == true,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      lastSeenAt: DateTime.tryParse(json['last_seen_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}
