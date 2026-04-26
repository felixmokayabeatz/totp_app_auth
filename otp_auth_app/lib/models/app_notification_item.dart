class AppNotificationItem {
  final String id;
  final String notificationType;
  final String title;
  final String message;
  final String details;
  final String preview;
  final bool isRead;
  final DateTime createdAt;
  final DateTime? readAt;

  const AppNotificationItem({
    required this.id,
    required this.notificationType,
    required this.title,
    required this.message,
    required this.details,
    required this.preview,
    required this.isRead,
    required this.createdAt,
    this.readAt,
  });

  factory AppNotificationItem.fromJson(Map<String, dynamic> json) {
    return AppNotificationItem(
      id: json['id'].toString(),
      notificationType: json['notification_type']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Notification',
      message: json['message']?.toString() ?? '',
      details: json['details']?.toString() ?? '',
      preview: json['preview']?.toString() ?? '',
      isRead: json['is_read'] == true,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      readAt: DateTime.tryParse(json['read_at']?.toString() ?? ''),
    );
  }
}
