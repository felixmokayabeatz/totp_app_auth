import 'dart:async';

import 'package:flutter/material.dart';

import '../services/sync_service.dart';

class PasswordlessLoginScreen extends StatefulWidget {
  const PasswordlessLoginScreen({
    super.key,
    required this.username,
    this.passwordForSync,
  });

  final String username;
  final String? passwordForSync;

  @override
  State<PasswordlessLoginScreen> createState() => _PasswordlessLoginScreenState();
}

class _PasswordlessLoginScreenState extends State<PasswordlessLoginScreen> {
  final SyncService _syncService = SyncService();
  Timer? _pollTimer;

  bool _isStarting = true;
  bool _isPolling = false;
  String? _requestId;
  String? _code;
  String? _primaryDeviceLabel;
  String? _errorMessage;
  String _statusMessage = 'Starting passwordless sign-in...';

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white54 : Colors.grey.shade600;

  @override
  void initState() {
    super.initState();
    _startFlow();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _startFlow() async {
    final result = await _syncService.startPasswordlessLogin(
      widget.username,
      password: widget.passwordForSync,
    );
    if (!mounted) return;

    if (result == null) {
      setState(() {
        _isStarting = false;
        _errorMessage = _syncService.lastErrorMessage ??
            'Passwordless sign-in could not be started.';
      });
      return;
    }

    setState(() {
      _isStarting = false;
      _requestId = result['request_id']?.toString();
      _code = result['verification_code']?.toString();
      _primaryDeviceLabel = result['primary_device_label']?.toString();
      _statusMessage = result['message']?.toString() ??
          'Approve this sign-in from your primary phone.';
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
    );
    if (!mounted) return;
    setState(() => _isPolling = false);

    if (result == null) {
      return;
    }

    final status = result['status']?.toString() ?? 'pending';
    if (status == 'pending') {
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
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
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
                    Icon(Icons.phonelink_lock_rounded, size: 54, color: _accent),
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
                      _errorMessage ??
                          _statusMessage,
                      style: TextStyle(color: _textSecondary, height: 1.45),
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
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (_isStarting)
                      const CircularProgressIndicator()
                    else if (_code != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 18),
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
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Back to login'),
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
    );
  }
}
