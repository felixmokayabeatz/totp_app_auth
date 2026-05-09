import 'package:flutter/material.dart';

import '../models/app_notification_item.dart';
import '../services/sync_service.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final SyncService _syncService = SyncService();

  bool _isLoading = true;
  bool _isMarkingAllRead = false;
  bool _isClearingNotifications = false;
  String? _errorMessage;
  List<AppNotificationItem> _notifications = const [];

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _bgColor =>
      _isDark ? const Color(0xFF0F0F1A) : const Color(0xFFF0F2FF);
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white54 : Colors.grey.shade600;
  int get _unreadCount => _notifications.where((item) => !item.isRead).length;

  static const Map<String, String> _notificationTypeLabels = {
    'all': 'All types',
    'sign_in': 'Sign-ins',
    'password_changed': 'Password changes',
    'recovery_code_used': 'Recovery-code use',
    'recovery_codes_generated': 'Recovery-code PDFs',
    'account_added': 'Account additions',
    'app_pin_changed': 'App PIN changes',
    'passwordless_request': 'Passwordless approvals',
    'app_review_reply': 'Review replies',
    'active_devices_daily': 'Active-device summaries',
  };

  static const Map<String, String> _ageFilterLabels = {
    'all': 'Any age',
    '7': 'Older than 7 days',
    '30': 'Older than 30 days',
    '90': 'Older than 90 days',
  };

  @override
  void initState() {
    super.initState();
    _loadNotifications();
  }

  Future<void> _loadNotifications() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    final notifications = await _syncService.getNotifications();
    if (!mounted) return;

    setState(() {
      _notifications = notifications;
      _errorMessage =
          notifications.isEmpty ? _syncService.lastErrorMessage : null;
      _isLoading = false;
    });
  }

  String _formatDayHeader(DateTime dateTime) {
    final local = dateTime.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(local.year, local.month, local.day);

    if (target == today) return 'Today';
    if (target == today.subtract(const Duration(days: 1))) return 'Yesterday';

    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }

  String _formatTime(DateTime dateTime) {
    final local = dateTime.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  IconData _iconForType(String notificationType) {
    switch (notificationType) {
      case 'sign_in':
        return Icons.login_rounded;
      case 'password_changed':
        return Icons.lock_reset_rounded;
      case 'recovery_code_used':
        return Icons.key_rounded;
      case 'recovery_codes_generated':
        return Icons.picture_as_pdf_rounded;
      case 'account_added':
        return Icons.add_circle_outline_rounded;
      case 'app_pin_changed':
        return Icons.pin_rounded;
      case 'passwordless_request':
        return Icons.phonelink_lock_rounded;
      case 'app_review_reply':
        return Icons.rate_review_rounded;
      default:
        return Icons.notifications_none_rounded;
    }
  }

  Future<void> _openNotification(AppNotificationItem item) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => NotificationDetailScreen(notification: item),
      ),
    );
    await _loadNotifications();
  }

  Future<void> _markAllRead() async {
    if (_isMarkingAllRead || _unreadCount == 0) return;

    setState(() => _isMarkingAllRead = true);
    final markedCount = await _syncService.markAllNotificationsRead();
    if (!mounted) return;

    setState(() => _isMarkingAllRead = false);

    final success = markedCount != null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Marked $markedCount notification${markedCount == 1 ? '' : 's'} as read.'
              : (_syncService.lastErrorMessage ??
                  'Could not mark notifications as read.'),
        ),
        backgroundColor: success ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );

    if (success) {
      await _loadNotifications();
    }
  }

  Future<void> _showClearNotificationsDialog() async {
    if (_isClearingNotifications || _notifications.isEmpty) return;

    var selectedType = 'all';
    var selectedAge = 'all';
    var keepUnread = true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: _cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Text(
                'Clear notifications',
                style: TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: selectedType,
                    decoration: const InputDecoration(
                      labelText: 'Type',
                      border: OutlineInputBorder(),
                    ),
                    items: _notificationTypeLabels.entries
                        .map(
                          (entry) => DropdownMenuItem<String>(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() => selectedType = value);
                    },
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: selectedAge,
                    decoration: const InputDecoration(
                      labelText: 'Age',
                      border: OutlineInputBorder(),
                    ),
                    items: _ageFilterLabels.entries
                        .map(
                          (entry) => DropdownMenuItem<String>(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() => selectedAge = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: keepUnread,
                    contentPadding: EdgeInsets.zero,
                    activeColor: _accent,
                    title: Text(
                      'Keep unread notifications',
                      style: TextStyle(
                        color: _textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onChanged: (value) {
                      setDialogState(() => keepUnread = value ?? true);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Clear'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isClearingNotifications = true);
    final deletedCount = await _syncService.clearNotifications(
      notificationType: selectedType,
      olderThanDays: selectedAge == 'all' ? null : int.tryParse(selectedAge),
      keepUnread: keepUnread,
    );
    if (!mounted) return;

    setState(() => _isClearingNotifications = false);

    final success = deletedCount != null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Cleared $deletedCount notification${deletedCount == 1 ? '' : 's'}.'
              : (_syncService.lastErrorMessage ??
                  'Could not clear notifications.'),
        ),
        backgroundColor: success ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );

    if (success) {
      await _loadNotifications();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: const Text(
          'Notifications',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_notifications.isNotEmpty)
            IconButton(
              tooltip: 'Clear notifications',
              onPressed: _isClearingNotifications
                  ? null
                  : _showClearNotificationsDialog,
              icon: _isClearingNotifications
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.delete_sweep_rounded),
            ),
          if (_unreadCount > 0)
            TextButton(
              onPressed: _isMarkingAllRead ? null : _markAllRead,
              child: _isMarkingAllRead
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Mark all read',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
        ],
      ),
      body: RefreshIndicator(
        color: _accent,
        onRefresh: _loadNotifications,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(_accent),
        ),
      );
    }

    if (_errorMessage != null && _notifications.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 80),
          Icon(
            Icons.error_outline_rounded,
            size: 46,
            color: _isDark ? Colors.white70 : _accent,
          ),
          const SizedBox(height: 14),
          Text(
            _errorMessage!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Pull down to try again.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _textSecondary),
          ),
        ],
      );
    }

    if (_notifications.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 80),
          Container(
            width: 82,
            height: 82,
            decoration: BoxDecoration(
              color: _cardColor,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(
              Icons.notifications_none_rounded,
              size: 40,
              color: _accent,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'No notifications yet',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Recent sign-ins, password changes, recovery-code activity, and account additions will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _textSecondary, height: 1.45),
          ),
        ],
      );
    }

    DateTime? lastDate;
    final widgets = <Widget>[];

    for (final item in _notifications) {
      final currentDate = DateTime(
        item.createdAt.toLocal().year,
        item.createdAt.toLocal().month,
        item.createdAt.toLocal().day,
      );

      if (lastDate == null || currentDate != lastDate) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
            child: Text(
              _formatDayHeader(item.createdAt),
              style: TextStyle(
                color: _textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
        );
        lastDate = currentDate;
      }

      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: InkWell(
            onTap: () => _openNotification(item),
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _cardColor,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color:
                        Colors.black.withValues(alpha: _isDark ? 0.18 : 0.05),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _accent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      _iconForType(item.notificationType),
                      color: _accent,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                item.title,
                                style: TextStyle(
                                  color: _textPrimary,
                                  fontSize: 14,
                                  fontWeight: item.isRead
                                      ? FontWeight.w600
                                      : FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatTime(item.createdAt),
                              style: TextStyle(
                                color: _textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.preview.isNotEmpty ? item.preview : item.message,
                          style: TextStyle(
                            color: _textSecondary,
                            fontSize: 12.5,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    children: [
                      if (!item.isRead)
                        Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: Color(0xFF10B981),
                            shape: BoxShape.circle,
                          ),
                        )
                      else
                        const SizedBox(height: 10),
                      const SizedBox(height: 8),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: _isDark ? Colors.white24 : Colors.grey.shade300,
                        size: 18,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    widgets.add(const SizedBox(height: 24));

    return ListView(children: widgets);
  }
}

class NotificationDetailScreen extends StatefulWidget {
  final AppNotificationItem notification;

  const NotificationDetailScreen({
    super.key,
    required this.notification,
  });

  @override
  State<NotificationDetailScreen> createState() =>
      _NotificationDetailScreenState();
}

class _NotificationDetailScreenState extends State<NotificationDetailScreen> {
  final SyncService _syncService = SyncService();

  AppNotificationItem? _notification;
  bool _isLoading = true;
  String? _errorMessage;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _bgColor =>
      _isDark ? const Color(0xFF0F0F1A) : const Color(0xFFF0F2FF);
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white54 : Colors.grey.shade600;

  @override
  void initState() {
    super.initState();
    _notification = widget.notification;
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    final detail =
        await _syncService.getNotificationDetail(widget.notification.id);
    if (!mounted) return;

    setState(() {
      _notification = detail ?? widget.notification;
      _errorMessage = detail == null ? _syncService.lastErrorMessage : null;
      _isLoading = false;
    });
  }

  String _formatFullDateTime(DateTime dateTime) {
    final local = dateTime.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final notification = _notification ?? widget.notification;

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: const Text(
          'Notification',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _cardColor,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: _isDark ? 0.18 : 0.05),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notification.title,
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.schedule_rounded, color: _accent, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      _formatFullDateTime(notification.createdAt),
                      style: TextStyle(
                        color: _textSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  notification.details.isNotEmpty
                      ? notification.details
                      : notification.message,
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 14,
                    height: 1.55,
                  ),
                ),
                if (_isLoading) ...[
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Loading latest details...',
                        style: TextStyle(color: _textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ],
                if (_errorMessage != null) ...[
                  const SizedBox(height: 18),
                  Text(
                    _errorMessage!,
                    style: const TextStyle(
                      color: Colors.orange,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
