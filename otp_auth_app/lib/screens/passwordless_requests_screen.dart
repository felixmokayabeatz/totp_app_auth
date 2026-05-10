import 'dart:async';

import 'package:flutter/material.dart';

import '../models/device_session_info.dart';
import '../services/app_lock_service.dart';
import '../services/sync_service.dart';

class PasswordlessRequestsScreen extends StatefulWidget {
  const PasswordlessRequestsScreen({super.key});

  @override
  State<PasswordlessRequestsScreen> createState() =>
      _PasswordlessRequestsScreenState();
}

class _PasswordlessRequestsScreenState
    extends State<PasswordlessRequestsScreen> {
  final SyncService _syncService = SyncService();
  final AppLockService _appLockService = AppLockService();
  Timer? _refreshTimer;

  bool _isLoading = true;
  bool _isActing = false;
  bool _canManageLogs = false;
  List<Map<String, dynamic>> _requests = const [];
  final Map<String, String> _selectedCodes = {};

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white54 : Colors.grey.shade600;
  int get _removableLogCount => _requests.where((item) => !_isPending(item)).length;

  @override
  void initState() {
    super.initState();
    _refreshPage(includeAccessState: true);
    _refreshTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _loadRequests(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshPage({bool includeAccessState = false}) async {
    if (includeAccessState) {
      await _loadAccessState();
    }
    await _loadRequests();
  }

  Future<void> _loadAccessState() async {
    final sessions = await _syncService.getActiveDeviceSessions();
    if (!mounted) return;

    DeviceSessionInfo? currentSession;
    for (final session in sessions) {
      if (session.isCurrent) {
        currentSession = session;
        break;
      }
    }

    setState(() {
      _canManageLogs = currentSession?.isPrimary == true &&
          currentSession?.deviceKind == 'mobile';
    });
  }

  Future<void> _loadRequests() async {
    final requests = await _syncService.getPasswordlessRequests();
    if (!mounted) return;
    setState(() {
      _requests = requests;
      final requestIds = requests
          .map((item) => item['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      _selectedCodes
          .removeWhere((requestId, _) => !requestIds.contains(requestId));
      for (final item in requests) {
        final requestId = item['id']?.toString() ?? '';
        if (requestId.isEmpty) continue;

        final choices = ((item['verification_choices'] as List?) ?? const [])
            .map((choice) => choice.toString())
            .where((choice) => choice.trim().isNotEmpty)
            .toSet();
        final selectedCode = _selectedCodes[requestId];
        if (selectedCode != null && !choices.contains(selectedCode)) {
          _selectedCodes.remove(requestId);
        }
      }
      _isLoading = false;
    });
  }

  bool _isPending(Map<String, dynamic> item) =>
      (item['status']?.toString() ?? 'pending').toLowerCase() == 'pending';

  String _prettyStatus(Map<String, dynamic> item) {
    switch ((item['status']?.toString() ?? 'pending').toLowerCase()) {
      case 'approved':
        return 'Approved';
      case 'completed':
        return 'Completed';
      case 'denied':
        return 'Denied';
      case 'expired':
        return 'Expired';
      default:
        return 'Pending';
    }
  }

  DateTime? _parseTimestamp(dynamic rawValue) {
    if (rawValue == null) return null;
    return DateTime.tryParse(rawValue.toString());
  }

  DateTime? _statusTimestamp(Map<String, dynamic> item) {
    final status = (item['status']?.toString() ?? 'pending').toLowerCase();
    switch (status) {
      case 'approved':
        return _parseTimestamp(item['approved_at']) ??
            _parseTimestamp(item['updated_at']);
      case 'completed':
        return _parseTimestamp(item['completed_at']) ??
            _parseTimestamp(item['approved_at']) ??
            _parseTimestamp(item['updated_at']);
      case 'denied':
      case 'expired':
        return _parseTimestamp(item['updated_at']);
      default:
        return _parseTimestamp(item['created_at']);
    }
  }

  String _formatTimestamp(DateTime? value) {
    if (value == null) return 'Unavailable';
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }

  Future<void> _handleRequest(
    Map<String, dynamic> item, {
    required bool approve,
    String? selectedCode,
  }) async {
    final unlocked = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !unlocked) return;

    setState(() => _isActing = true);
    final requestId = item['id']?.toString() ?? '';
    final success = approve
        ? await _syncService.approvePasswordlessRequest(
            requestId,
            selectedCode: selectedCode ?? '',
          )
        : await _syncService.denyPasswordlessRequest(requestId);
    if (!mounted) return;
    setState(() => _isActing = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? (approve
                  ? 'Sign-in request approved.'
                  : 'Sign-in request denied.')
              : (_syncService.lastErrorMessage ??
                  'Could not update this sign-in request.'),
        ),
        backgroundColor: success ? const Color(0xFF10B981) : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );

    if (success) {
      _selectedCodes.remove(requestId);
      await _refreshPage();
    }
  }

  Future<void> _deleteLog(Map<String, dynamic> item) async {
    final requestId = item['id']?.toString() ?? '';
    final label =
        item['requester_device_label']?.toString() ?? 'Unknown device';
    if (requestId.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Delete Sign-in Log', style: TextStyle(color: _textPrimary)),
        content: Text(
          'Delete the encrypted sign-in approval log for $label?',
          style: TextStyle(color: _textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final unlocked = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !unlocked) return;

    setState(() => _isActing = true);
    final success = await _syncService.deletePasswordlessRequestLog(requestId);
    if (!mounted) return;
    setState(() => _isActing = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Encrypted sign-in log deleted.'
              : (_syncService.lastErrorMessage ??
                  'Could not delete this sign-in log.'),
        ),
        backgroundColor: success ? const Color(0xFF10B981) : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );

    if (success) {
      await _refreshPage();
    }
  }

  Future<void> _clearLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Clear Sign-in Logs', style: TextStyle(color: _textPrimary)),
        content: Text(
          'Clear all encrypted sign-in approval logs while keeping any still-pending requests?',
          style: TextStyle(color: _textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Clear Logs'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final unlocked = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !unlocked) return;

    setState(() => _isActing = true);
    final clearedCount = await _syncService.clearPasswordlessRequestLogs();
    if (!mounted) return;
    setState(() => _isActing = false);

    final success = clearedCount != null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Cleared $clearedCount encrypted sign-in log${clearedCount == 1 ? '' : 's'}.'
              : (_syncService.lastErrorMessage ??
                  'Could not clear the sign-in logs.'),
        ),
        backgroundColor: success ? const Color(0xFF10B981) : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );

    if (success) {
      await _refreshPage();
    }
  }

  Widget _buildChoiceButton(
    String choice, {
    required bool selected,
    required VoidCallback? onPressed,
  }) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: selected
            ? _accent
            : _accent.withValues(alpha: _isDark ? 0.14 : 0.09),
        foregroundColor: selected ? Colors.white : _textPrimary,
        elevation: selected ? 1 : 0,
        side: BorderSide(
          color: selected ? _accent : _accent.withValues(alpha: 0.28),
          width: selected ? 2 : 1.4,
        ),
        minimumSize: const Size.fromHeight(88),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
      child: Text(
        choice,
        style: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.6,
          color: selected ? Colors.white : _textPrimary,
        ),
      ),
    );
  }

  Widget _buildChoiceRow(
    List<String> choices, {
    required String? selectedCode,
    required String requestId,
  }) {
    return Row(
      children: [
        for (var index = 0; index < choices.length; index++) ...[
          Expanded(
            child: _buildChoiceButton(
              choices[index],
              selected: selectedCode == choices[index],
              onPressed: _isActing
                  ? null
                  : () => setState(() {
                        _selectedCodes[requestId] = choices[index];
                      }),
            ),
          ),
          if (index != choices.length - 1) const SizedBox(width: 10),
        ],
      ],
    );
  }

  Widget _buildRequestCard(Map<String, dynamic> item) {
    final status = (item['status']?.toString() ?? 'pending').toLowerCase();
    final isPending = status == 'pending';
    final requestId = item['id']?.toString() ?? '';
    final label =
        item['requester_device_label']?.toString() ?? 'Unknown device';
    final kind = item['requester_device_kind']?.toString() ?? 'unknown';
    final kindLabel = kind.isEmpty
        ? 'Unknown'
        : '${kind[0].toUpperCase()}${kind.substring(1)}';
    final selectedCode = _selectedCodes[requestId];
    final choices = ((item['verification_choices'] as List?) ?? const [])
        .map((choice) => choice.toString())
        .where((choice) => choice.trim().isNotEmpty)
        .toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: _textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Type: $kindLabel',
                      style: TextStyle(color: _textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _prettyStatus(item),
                    style: TextStyle(
                      color: isPending ? _accent : _textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!isPending && _canManageLogs)
                    IconButton(
                      onPressed: _isActing ? null : () => _deleteLog(item),
                      tooltip: 'Delete encrypted log',
                      icon: const Icon(Icons.delete_outline_rounded),
                      color: Colors.red.shade400,
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: _isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.grey.shade50,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isPending
                          ? Icons.phonelink_lock_rounded
                          : Icons.lock_clock_rounded,
                      color: _accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isPending
                            ? 'Choose the exact 3-digit code shown on $label.'
                            : 'Encrypted sign-in log',
                        style: TextStyle(
                          color: _textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Requested: ${_formatTimestamp(_parseTimestamp(item['created_at']))}',
                  style: TextStyle(color: _textSecondary, fontSize: 12),
                ),
                if (!isPending)
                  Text(
                    '${_prettyStatus(item)}: ${_formatTimestamp(_statusTimestamp(item))}',
                    style: TextStyle(color: _textSecondary, fontSize: 12),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (isPending)
            Column(
              children: [
                if (choices.isNotEmpty)
                  _buildChoiceRow(
                    choices,
                    selectedCode: selectedCode,
                    requestId: requestId,
                  ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isActing || selectedCode == null
                        ? null
                        : () => _handleRequest(
                              item,
                              approve: true,
                              selectedCode: selectedCode,
                            ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.check_circle_rounded),
                    label: const Text(
                      'Accept',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _isActing
                        ? null
                        : () => _handleRequest(item, approve: false),
                    child: const Text('Deny'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildAccessHint() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _isDark ? Colors.white10 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _canManageLogs ? Icons.lock_rounded : Icons.visibility_rounded,
            color: _accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _canManageLogs
                  ? 'These sign-in approval logs stay encrypted. This primary phone can delete individual history items or clear old logs.'
                  : 'These sign-in approval logs stay encrypted. You can review them here, but only the current primary phone can delete or clear them.',
              style: TextStyle(
                color: _textSecondary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Sign-in Approvals',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        actions: [
          if (_canManageLogs)
            IconButton(
              onPressed: _isActing || _removableLogCount == 0 ? null : _clearLogs,
              tooltip: 'Clear encrypted logs',
              icon: const Icon(Icons.delete_sweep_rounded),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _refreshPage(includeAccessState: true),
              child: _requests.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _buildAccessHint(),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              Icon(Icons.phonelink_lock_rounded,
                                  size: 52, color: _accent),
                              const SizedBox(height: 16),
                              Text(
                                'No sign-in approvals yet',
                                style: TextStyle(
                                  color: _textPrimary,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'When another device asks to sign in passwordlessly, pending requests and encrypted approval history will appear here.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: _textSecondary,
                                  height: 1.45,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _buildAccessHint(),
                        for (final item in _requests) _buildRequestCard(item),
                      ],
                    ),
            ),
    );
  }
}
