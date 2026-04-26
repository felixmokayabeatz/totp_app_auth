import 'package:flutter/material.dart';

import '../models/device_session_info.dart';
import '../services/sync_service.dart';

class DeviceSessionsScreen extends StatefulWidget {
  const DeviceSessionsScreen({super.key});

  @override
  State<DeviceSessionsScreen> createState() => _DeviceSessionsScreenState();
}

class _DeviceSessionsScreenState extends State<DeviceSessionsScreen> {
  final SyncService _syncService = SyncService();

  bool _isLoading = true;
  bool _isRevokingAll = false;
  String? _primaryUpdateSessionId;
  String? _errorMessage;
  List<DeviceSessionInfo> _sessions = const [];

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => const Color(0xFF4F46E5);
  Color get _bgColor =>
      _isDark ? const Color(0xFF0F0F1A) : const Color(0xFFF0F2FF);
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white54 : Colors.grey.shade600;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final sessions = await _syncService.getActiveDeviceSessions();
    if (!mounted) return;

    setState(() {
      _sessions = sessions;
      _errorMessage = sessions.isEmpty ? _syncService.lastErrorMessage : null;
      _isLoading = false;
    });
  }

  String _formatDate(DateTime dateTime) {
    final local = dateTime.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }

  String _deviceReference(String deviceId) {
    if (deviceId.isEmpty) return 'Unavailable';
    if (deviceId.length <= 8) return deviceId.toUpperCase();
    return deviceId.substring(deviceId.length - 8).toUpperCase();
  }

  Future<void> _revokeSession(DeviceSessionInfo session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Sign Out Device', style: TextStyle(color: _textPrimary)),
        content: Text(
          'Sign out ${session.deviceLabel} from your BeatzLock account?',
          style: TextStyle(color: _textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final success = await _syncService.revokeDeviceSession(session.id);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? '${session.deviceLabel} was signed out.'
              : (_syncService.lastErrorMessage ??
                  'Could not sign out this device.'),
        ),
        backgroundColor: success ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );

    if (success) {
      await _loadSessions();
    }
  }

  Future<void> _revokeAllOthers() async {
    final otherCount = _sessions
        .where((session) => !session.isCurrent && !session.isPrimary)
        .length;
    if (otherCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('There are no removable other devices right now.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title:
            Text('Sign Out Other Devices', style: TextStyle(color: _textPrimary)),
        content: Text(
          'This will sign out other devices but keep your current device and the primary device active.',
          style: TextStyle(color: _textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Sign Out Others'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isRevokingAll = true);
    final revokedCount = await _syncService.revokeOtherDeviceSessions();
    if (!mounted) return;
    setState(() => _isRevokingAll = false);

    final success = revokedCount != null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Signed out $revokedCount other device${revokedCount == 1 ? '' : 's'}.'
              : (_syncService.lastErrorMessage ??
                  'Could not sign out the other devices.'),
        ),
        backgroundColor: success ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );

    if (success) {
      await _loadSessions();
    }
  }

  Future<void> _setPrimaryDevice(DeviceSessionInfo session) async {
    setState(() => _primaryUpdateSessionId = session.id);
    final success = await _syncService.setPrimaryDeviceSession(session.id);
    if (!mounted) return;

    setState(() => _primaryUpdateSessionId = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? '${session.deviceLabel} is now your primary device.'
              : (_syncService.lastErrorMessage ??
                  'Could not set the primary device.'),
        ),
        backgroundColor: success ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );

    if (success) {
      await _loadSessions();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: const Text(
          'Active Devices',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
        backgroundColor: _isDark ? const Color(0xFF1A1A2E) : _accent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: RefreshIndicator(
        color: _accent,
        onRefresh: _loadSessions,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _summaryCard(),
            const SizedBox(height: 18),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.only(top: 60),
                child: Center(
                  child: CircularProgressIndicator(
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Color(0xFF4F46E5)),
                  ),
                ),
              )
            else if (_sessions.isEmpty)
              _emptyState()
            else ..._sessions.map(_sessionCard),
          ],
        ),
      ),
    );
  }

  Widget _summaryCard() {
    final otherCount = _sessions
        .where((session) => !session.isCurrent && !session.isPrimary)
        .length;
    final primarySession = _sessions.cast<DeviceSessionInfo?>().firstWhere(
          (session) => session?.isPrimary == true,
          orElse: () => null,
        );

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(_isDark ? 0.18 : 0.05),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Live signed-in devices',
            style: TextStyle(
              color: _textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Review where your account is currently active and remove any device you do not trust.',
            style: TextStyle(color: _textSecondary, fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 10),
          Text(
            'Devices on the same Wi-Fi can share one public IP, so BeatzLock uses the device name and device reference instead.',
            style: TextStyle(color: _textSecondary, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 10),
          Text(
            primarySession == null
                ? 'Choose one primary device below. It will stay signed in when you use Sign Out All Other Devices.'
                : 'Primary device: ${primarySession.deviceLabel}',
            style: TextStyle(
              color: primarySession == null
                  ? _textSecondary
                  : const Color(0xFF2563EB),
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isRevokingAll ? null : _revokeAllOthers,
              icon: _isRevokingAll
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.logout_rounded),
              label: Text(
                otherCount > 0
                    ? 'Sign Out All Other Devices'
                    : 'No Other Devices Active',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: otherCount > 0 ? Colors.red : Colors.grey,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(Icons.devices_outlined, color: _accent, size: 42),
          const SizedBox(height: 14),
          Text(
            _errorMessage ?? 'No active devices found.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sessionCard(DeviceSessionInfo session) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(_isDark ? 0.18 : 0.05),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _accent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.devices_rounded, color: _accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.deviceLabel,
                      style: TextStyle(
                        color: _textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      session.isCurrent ? 'Current device' : 'Other device',
                      style: TextStyle(
                        color: session.isCurrent
                            ? const Color(0xFF10B981)
                            : _textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (session.isPrimary)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2563EB).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Primary',
                    style: TextStyle(
                      color: Color(0xFF2563EB),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (session.isPrimary && session.isCurrent) const SizedBox(width: 8),
              if (session.isCurrent)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'This one',
                    style: TextStyle(
                      color: Color(0xFF10B981),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Signed in: ${_formatDate(session.createdAt)}',
            style: TextStyle(color: _textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          Text(
            'Last seen: ${_formatDate(session.lastSeenAt)}',
            style: TextStyle(color: _textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          Text(
            'Device ref: ${_deviceReference(session.deviceId)}',
            style: TextStyle(color: _textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.end,
            children: [
              if (!session.isPrimary)
                OutlinedButton.icon(
                  onPressed: _primaryUpdateSessionId == session.id
                      ? null
                      : () => _setPrimaryDevice(session),
                  icon: _primaryUpdateSessionId == session.id
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.star_rounded, size: 18),
                  label: const Text('Make Primary'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF2563EB),
                    side: BorderSide(
                      color: const Color(0xFF2563EB).withOpacity(0.35),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              if (!session.isCurrent)
                OutlinedButton.icon(
                  onPressed: () => _revokeSession(session),
                  icon: const Icon(Icons.logout_rounded, size: 18),
                  label: const Text('Sign Out'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: BorderSide(color: Colors.red.withOpacity(0.3)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
