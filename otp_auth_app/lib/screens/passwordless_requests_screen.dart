import 'package:flutter/material.dart';

import '../services/app_lock_service.dart';
import '../services/sync_service.dart';

class PasswordlessRequestsScreen extends StatefulWidget {
  const PasswordlessRequestsScreen({super.key});

  @override
  State<PasswordlessRequestsScreen> createState() =>
      _PasswordlessRequestsScreenState();
}

class _PasswordlessRequestsScreenState extends State<PasswordlessRequestsScreen> {
  final SyncService _syncService = SyncService();
  final AppLockService _appLockService = AppLockService();

  bool _isLoading = true;
  bool _isActing = false;
  List<Map<String, dynamic>> _requests = const [];

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white54 : Colors.grey.shade600;

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    final requests = await _syncService.getPasswordlessRequests();
    if (!mounted) return;
    setState(() {
      _requests = requests;
      _isLoading = false;
    });
  }

  String _prettyStatus(Map<String, dynamic> item) {
    final status = (item['status']?.toString() ?? 'pending').toLowerCase();
    switch (status) {
      case 'approved':
        return 'Approved';
      case 'denied':
        return 'Denied';
      case 'expired':
        return 'Expired';
      default:
        return 'Pending';
    }
  }

  Future<void> _handleRequest(Map<String, dynamic> item, bool approve) async {
    final unlocked = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !unlocked) return;

    setState(() => _isActing = true);
    final requestId = item['id']?.toString() ?? '';
    final success = approve
        ? await _syncService.approvePasswordlessRequest(requestId)
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
      await _loadRequests();
    }
  }

  Widget _buildRequestCard(Map<String, dynamic> item) {
    final status = (item['status']?.toString() ?? 'pending').toLowerCase();
    final isPending = status == 'pending';
    final code = item['verification_code']?.toString() ?? '---';
    final label = item['requester_device_label']?.toString() ?? 'Unknown device';
    final kind = item['requester_device_kind']?.toString() ?? 'unknown';

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
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                _prettyStatus(item),
                style: TextStyle(
                  color: isPending ? _accent : _textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Type: ${kind[0].toUpperCase()}${kind.substring(1)}',
            style: TextStyle(color: _textSecondary, fontSize: 12),
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
            child: Row(
              children: [
                Icon(Icons.password_rounded, color: _accent),
                const SizedBox(width: 10),
                Text(
                  code,
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (isPending)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isActing ? null : () => _handleRequest(item, false),
                    child: const Text('Deny'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isActing ? null : () => _handleRequest(item, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Approve'),
                  ),
                ),
              ],
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
              onRefresh: _loadRequests,
              child: _requests.isEmpty
                  ? ListView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(28),
                          child: Column(
                            children: [
                              Icon(Icons.phonelink_lock_rounded,
                                  size: 52, color: _accent),
                              const SizedBox(height: 16),
                              Text(
                                'No sign-in requests right now',
                                style: TextStyle(
                                  color: _textPrimary,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'When another device asks to sign in passwordlessly, approve it here from your primary phone.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: _textSecondary, height: 1.45),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        for (final item in _requests) _buildRequestCard(item),
                      ],
                    ),
            ),
    );
  }
}
