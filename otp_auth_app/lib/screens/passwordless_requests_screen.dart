import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/device_session_info.dart';
import '../services/app_lock_service.dart';
import '../services/sync_service.dart';

enum _PasswordlessApprovalMode { cancel, approveOnly, unlockAndTransfer }

class PasswordlessRequestsScreen extends StatefulWidget {
  const PasswordlessRequestsScreen({
    super.key,
    this.closeOnSuccessfulApproval = false,
  });

  final bool closeOnSuccessfulApproval;

  @override
  State<PasswordlessRequestsScreen> createState() =>
      _PasswordlessRequestsScreenState();
}

class _PasswordlessRequestsScreenState
    extends State<PasswordlessRequestsScreen> {
  static const Duration _refreshInterval = Duration(seconds: 5);

  final SyncService _syncService = SyncService();
  final AppLockService _appLockService = AppLockService();
  Timer? _refreshTimer;

  bool _isLoading = true;
  bool _isActing = false;
  bool _isRefreshing = false;
  bool _canManageLogs = false;
  List<Map<String, dynamic>> _requests = const [];
  // One controller per pending request. The code is typed, not picked
  // from a list, so nothing the server sends can stand in for seeing
  // the requesting device's screen.
  final Map<String, TextEditingController> _codeControllers = {};

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _cardColor => Theme.of(context).colorScheme.surface;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white54 : Colors.grey.shade600;
  int get _removableLogCount =>
      _requests.where((item) => !_isPending(item)).length;

  @override
  void initState() {
    super.initState();
    _refreshPage(includeAccessState: true);
    _refreshTimer = Timer.periodic(
      _refreshInterval,
      (_) => unawaited(_loadRequests()),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    for (final controller in _codeControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _codeControllerFor(String requestId) {
    return _codeControllers.putIfAbsent(
      requestId,
      TextEditingController.new,
    );
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
    if (_isRefreshing) {
      return;
    }

    _isRefreshing = true;
    try {
      final requests = await _syncService.getPasswordlessRequests();
      if (!mounted) return;
      setState(() {
        _requests = requests;
        final requestIds = requests
            .map((item) => item['id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet();
        // This list re-reads itself every few seconds. Keep the controller of
        // every request still on screen, so a half-typed code survives a
        // refresh, and dispose the rest.
        final goneIds = _codeControllers.keys
            .where((requestId) => !requestIds.contains(requestId))
            .toList();
        for (final requestId in goneIds) {
          _codeControllers.remove(requestId)?.dispose();
        }
        _isLoading = false;
      });
    } finally {
      _isRefreshing = false;
    }
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

  Future<_PasswordlessApprovalMode> _prepareApprovalMode(
    Map<String, dynamic> item,
  ) async {
    if (await _syncService.hasAvailableEncryptionKey()) {
      return _PasswordlessApprovalMode.unlockAndTransfer;
    }

    final requesterLabel =
        item['requester_device_label']?.toString().trim() ?? '';
    final targetDeviceLabel =
        requesterLabel.isNotEmpty ? requesterLabel : 'the other device';
    final syncEnabled = await _syncService.isSyncEnabled();
    if (!mounted) return _PasswordlessApprovalMode.cancel;

    final passwordController = TextEditingController();
    var isSubmitting = false;
    var obscurePassword = true;
    String? errorText;
    var result = _PasswordlessApprovalMode.cancel;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: _cardColor,
            title: Text(
              'Unlock Sync For Approval',
              style: TextStyle(color: _textPrimary),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    syncEnabled
                        ? 'Cloud sync is locked on this primary phone right '
                            'now. Enter your account password here to unlock '
                            'sync on this phone and let $targetDeviceLabel '
                            'start syncing immediately after approval.'
                        : 'Cloud sync is not unlocked on this primary phone '
                            'right now. Enter your account password here if '
                            'you want to unlock sync on this phone too and '
                            'let $targetDeviceLabel start syncing '
                            'immediately after approval.',
                    style: TextStyle(color: _textSecondary, height: 1.45),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'If you skip this, the sign-in will still work, but '
                    '$targetDeviceLabel may need the account password later '
                    'to unlock encrypted sync.',
                    style: TextStyle(
                      color: _textSecondary,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    enabled: !isSubmitting,
                    decoration: InputDecoration(
                      labelText: 'Account password',
                      border: const OutlineInputBorder(),
                      errorText: errorText,
                      suffixIcon: IconButton(
                        tooltip:
                            obscurePassword ? 'Show password' : 'Hide password',
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                        ),
                        onPressed: () => setDialogState(
                          () => obscurePassword = !obscurePassword,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSubmitting
                    ? null
                    : () {
                        result = _PasswordlessApprovalMode.cancel;
                        Navigator.pop(dialogContext);
                      },
                child: const Text('Cancel'),
              ),
              OutlinedButton(
                onPressed: isSubmitting
                    ? null
                    : () {
                        result = _PasswordlessApprovalMode.approveOnly;
                        Navigator.pop(dialogContext);
                      },
                child: const Text('Approve only'),
              ),
              FilledButton(
                onPressed: isSubmitting
                    ? null
                    : () async {
                        final password = passwordController.text.trim();
                        if (password.isEmpty) {
                          setDialogState(() {
                            errorText =
                                'Enter your password to unlock sync first.';
                          });
                          return;
                        }

                        setDialogState(() {
                          isSubmitting = true;
                          errorText = null;
                        });

                        final unlocked = await _syncService
                            .unlockSyncOnCurrentDevice(password);
                        if (!dialogContext.mounted) return;

                        if (unlocked) {
                          result = _PasswordlessApprovalMode.unlockAndTransfer;
                          Navigator.pop(dialogContext);
                          return;
                        }

                        setDialogState(() {
                          isSubmitting = false;
                          errorText = _syncService.lastErrorMessage ??
                              'Could not unlock sync on this phone.';
                        });
                      },
                child: isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Unlock and approve'),
              ),
            ],
          ),
        ),
      ),
    );

    passwordController.dispose();
    return result;
  }

  Future<void> _handleRequest(
    Map<String, dynamic> item, {
    required bool approve,
    String? enteredCode,
  }) async {
    final unlocked = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !unlocked) return;

    var approvalMode = _PasswordlessApprovalMode.approveOnly;
    if (approve) {
      approvalMode = await _prepareApprovalMode(item);
      if (!mounted || approvalMode == _PasswordlessApprovalMode.cancel) {
        return;
      }
    }

    setState(() => _isActing = true);
    final requestId = item['id']?.toString() ?? '';
    final success = approve
        ? await _syncService.approvePasswordlessRequest(
            requestId,
            enteredCode: enteredCode ?? '',
            unlockTransferKey: item['unlock_transfer_key']?.toString(),
            attemptSyncUnlockTransfer:
                approvalMode == _PasswordlessApprovalMode.unlockAndTransfer,
          )
        : await _syncService.denyPasswordlessRequest(requestId);
    if (!mounted) return;
    setState(() => _isActing = false);

    final successMessage = approve
        ? approvalMode == _PasswordlessApprovalMode.unlockAndTransfer
            ? 'Sign-in request approved and sync will unlock on that device too.'
            : 'Sign-in request approved.'
        : 'Sign-in request denied.';

    if (success && approve && widget.closeOnSuccessfulApproval && mounted) {
      Navigator.pop(context, successMessage);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? (approve
                  ? approvalMode == _PasswordlessApprovalMode.unlockAndTransfer
                      ? 'Sign-in request approved and sync will unlock on '
                          'that device too.'
                      : 'Sign-in request approved. That device may still '
                          'need the account password to unlock encrypted '
                          'sync.'
                  : successMessage)
              : (_syncService.lastErrorMessage ??
                  'Could not update this sign-in request.'),
        ),
        backgroundColor: success ? const Color(0xFF10B981) : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );

    if (success) {
      _codeControllers.remove(requestId)?.dispose();
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
        title: Text(
          'Delete Sign-in Log',
          style: TextStyle(color: _textPrimary),
        ),
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
    if (!mounted) return;

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
        title: Text(
          'Clear Sign-in Logs',
          style: TextStyle(color: _textPrimary),
        ),
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
    if (!mounted) return;

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

  Widget _buildCodeField({
    required String requestId,
    required String deviceLabel,
  }) {
    final controller = _codeControllerFor(requestId);
    return TextField(
      controller: controller,
      enabled: !_isActing,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      autocorrect: false,
      enableSuggestions: false,
      maxLength: 4,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(4),
      ],
      style: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w900,
        letterSpacing: 14,
        color: _textPrimary,
      ),
      decoration: InputDecoration(
        counterText: '',
        hintText: '0000',
        hintStyle: TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w900,
          letterSpacing: 14,
          color: _textSecondary.withValues(alpha: 0.4),
        ),
        labelText: 'Code shown on $deviceLabel',
        floatingLabelAlignment: FloatingLabelAlignment.center,
        filled: true,
        fillColor: _accent.withValues(alpha: _isDark ? 0.12 : 0.07),
        contentPadding: const EdgeInsets.symmetric(vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: _accent.withValues(alpha: 0.28)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: _accent.withValues(alpha: 0.28)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: _accent, width: 2),
        ),
      ),
      // Redraws the card so Accept enables the moment four digits are in.
      onChanged: (_) => setState(() {}),
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
    final typedCode = isPending && requestId.isNotEmpty
        ? _codeControllerFor(requestId).text.trim()
        : '';
    final codeIsComplete = typedCode.length == 4;

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
                            ? 'Type the 4-digit code shown on $label.'
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
                if (!isPending && _canManageLogs) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _isActing ? null : () => _deleteLog(item),
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Delete encrypted log'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade400,
                        side: BorderSide(color: Colors.red.shade300),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (isPending)
            Column(
              children: [
                if (requestId.isNotEmpty)
                  _buildCodeField(requestId: requestId, deviceLabel: label),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isActing || !codeIsComplete
                        ? null
                        : () => _handleRequest(
                              item,
                              approve: true,
                              enteredCode: typedCode,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _canManageLogs
                      ? 'These sign-in approval logs stay encrypted. This primary phone can delete individual history items or clear old logs.'
                      : 'These sign-in approval logs stay encrypted. You can review them here, but only the current primary phone can delete or clear them.',
                  style: TextStyle(
                    color: _textSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                if (_canManageLogs && _removableLogCount > 0) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _isActing ? null : _clearLogs,
                    icon: const Icon(Icons.delete_sweep_rounded),
                    label: const Text('Clear encrypted logs'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade400,
                      side: BorderSide(color: Colors.red.shade300),
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
                              Icon(
                                Icons.phonelink_lock_rounded,
                                size: 52,
                                color: _accent,
                              ),
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
