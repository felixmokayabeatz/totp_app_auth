import 'dart:async';

import 'package:flutter/material.dart';

import '../services/sync_service.dart';

class PasswordlessLoginScreen extends StatefulWidget {
  const PasswordlessLoginScreen({
    super.key,
    required this.username,
    this.passwordForSync,
    this.initialResult,
  });

  final String username;
  final String? passwordForSync;
  final Map<String, dynamic>? initialResult;

  @override
  State<PasswordlessLoginScreen> createState() =>
      _PasswordlessLoginScreenState();
}

class _PasswordlessLoginScreenState extends State<PasswordlessLoginScreen> {
  final SyncService _syncService = SyncService();
  Timer? _pollTimer;
  Timer? _countdownTimer;

  bool _isStarting = true;
  bool _isPolling = false;
  String? _requestId;
  String? _code;
  String? _unlockTransferKey;
  DateTime? _codeExpiresAt;
  String? _primaryDeviceLabel;
  String? _errorMessage;
  String _statusMessage = 'Starting passwordless sign-in...';
  String? _pushStatusMessage;
  String? _pushStatusReason;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white54 : Colors.grey.shade600;

  @override
  void initState() {
    super.initState();
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _handleCountdownTick(),
    );
    final initialResult = widget.initialResult;
    if (initialResult != null) {
      _consumeStartResult(initialResult);
      return;
    }
    _startFlow();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _restartFlow() async {
    _pollTimer?.cancel();
    if (!mounted) return;

    setState(() {
      _isStarting = true;
      _isPolling = false;
      _requestId = null;
      _code = null;
      _unlockTransferKey = null;
      _codeExpiresAt = null;
      _errorMessage = null;
      _statusMessage = 'Starting passwordless sign-in...';
      _pushStatusMessage = null;
      _pushStatusReason = null;
    });

    await _startFlow();
  }

  Future<void> _startFlow() async {
    final result = await _syncService.startPasswordlessLogin(
      widget.username,
      password: widget.passwordForSync,
    );
    _consumeStartResult(result);
  }

  void _consumeStartResult(Map<String, dynamic>? result) {
    if (!mounted) return;

    if (result == null) {
      setState(() {
        _isStarting = false;
        _errorMessage = _syncService.lastErrorMessage ??
            'Passwordless sign-in could not be started.';
      });
      return;
    }

    final access = result['access']?.toString() ?? '';
    final refresh = result['refresh']?.toString() ?? '';
    if (result['success'] == true && access.isNotEmpty && refresh.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.pop(context, result);
      });
      return;
    }

    final requestId = result['request_id']?.toString() ?? '';
    if (requestId.isEmpty) {
      setState(() {
        _isStarting = false;
        _errorMessage = result['error']?.toString() ??
            _syncService.lastErrorMessage ??
            'Passwordless sign-in could not be started.';
      });
      return;
    }

    setState(() {
      _isStarting = false;
      _requestId = requestId;
      _code = result['verification_code']?.toString();
      _unlockTransferKey = result['unlock_transfer_key']?.toString();
      _codeExpiresAt = DateTime.tryParse(
        result['code_expires_at']?.toString() ?? '',
      );
      _primaryDeviceLabel = result['primary_device_label']?.toString();
      _pushStatusMessage = result['push_status_message']?.toString();
      _pushStatusReason = result['push_status_reason']?.toString();
      _statusMessage = result['message']?.toString() ??
          'Open BeatzLock on your primary phone and approve this sign-in there.';
    });

    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _pollApproval();
    });
  }

  Future<void> _pollApproval() async {
    final requestId = _requestId;
    if (requestId == null || requestId.isEmpty || _isPolling) return;

    setState(() => _isPolling = true);
    final result = await _syncService.pollPasswordlessLogin(
      requestId,
      password: widget.passwordForSync,
      unlockTransferKey: _unlockTransferKey,
    );
    if (!mounted) return;
    setState(() => _isPolling = false);

    if (result == null) {
      return;
    }

    final status = result['status']?.toString() ?? 'pending';
    if (status == 'pending') {
      setState(() {
        _code = result['verification_code']?.toString() ?? _code;
        _codeExpiresAt =
            DateTime.tryParse(result['code_expires_at']?.toString() ?? '') ??
                _codeExpiresAt;
      });
      return;
    }

    _pollTimer?.cancel();
    if (status == 'approved' && result['success'] == true) {
      Navigator.pop(context, result);
      return;
    }

    setState(() {
      _errorMessage = result['error']?.toString() ??
          _syncService.lastErrorMessage ??
          'Passwordless sign-in could not be completed.';
    });
  }

  void _handleCountdownTick() {
    if (!mounted ||
        _isStarting ||
        _errorMessage != null ||
        _requestId == null ||
        _codeExpiresAt == null) {
      return;
    }

    final secondsRemaining = _secondsUntilRefresh();
    if (secondsRemaining <= 0 && !_isPolling) {
      unawaited(_pollApproval());
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Passwordless Sign-in',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Card(
                  color: _cardColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.phonelink_lock_rounded,
                          size: 54,
                          color: _accent,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Approve on your primary phone',
                          style: TextStyle(
                            color: _textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _errorMessage ?? _statusMessage,
                          style: TextStyle(
                            color: _errorMessage != null
                                ? Colors.red.shade400
                                : _textSecondary,
                            height: 1.45,
                            fontWeight: _errorMessage != null
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (_primaryDeviceLabel != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Primary phone: $_primaryDeviceLabel',
                            style: TextStyle(
                              color: _accent,
                              fontWeight: FontWeight.w700,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        if (_errorMessage == null) ...[
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: _accent.withValues(
                                alpha: _isDark ? 0.12 : 0.08,
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.notifications_active_rounded,
                                  color: _accent,
                                  size: 18,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    (_pushStatusMessage != null &&
                                            _pushStatusMessage!
                                                .trim()
                                                .isNotEmpty
                                        ? _pushStatusMessage!
                                        : 'Check the primary phone to approve. '
                                            'If BeatzLock is closed there, the request should '
                                            'appear in the notification bar. If it is already '
                                            'open, the approval prompt should appear right '
                                            'inside the app.'),
                                    style: TextStyle(
                                      color: _pushStatusReason == 'sent'
                                          ? _textSecondary
                                          : Colors.orange.shade300,
                                      fontSize: 12.5,
                                      height: 1.45,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        if (_isStarting)
                          const CircularProgressIndicator()
                        else if (_code != null) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 18,
                            ),
                            decoration: BoxDecoration(
                              color: _isDark
                                  ? Colors.white.withValues(alpha: 0.05)
                                  : Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  'Verification code',
                                  style: TextStyle(
                                    color: _textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _code!,
                                  style: TextStyle(
                                    color: _textPrimary,
                                    fontSize: 42,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 3,
                                  ),
                                ),
                                if (_codeExpiresAt != null) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    'Code changes in about ${_secondsUntilRefresh()}s if not approved.',
                                    style: TextStyle(
                                      color: _textSecondary,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (_isPolling)
                            const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                        const SizedBox(height: 18),
                        if (_errorMessage != null)
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            alignment: WrapAlignment.center,
                            children: [
                              OutlinedButton(
                                onPressed: _restartFlow,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: _accent,
                                  side: BorderSide(color: _accent),
                                ),
                                child: const Text('Start again'),
                              ),
                              ElevatedButton(
                                onPressed: () => Navigator.pop(context),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _accent,
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text('Back to login'),
                              ),
                            ],
                          )
                        else
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Use password instead'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  int _secondsUntilRefresh() {
    final expiresAt = _codeExpiresAt;
    if (expiresAt == null) return 60;
    final milliseconds = expiresAt.difference(DateTime.now()).inMilliseconds;
    if (milliseconds <= 0) return 0;
    return ((milliseconds + 999) / 1000).floor();
  }
}
