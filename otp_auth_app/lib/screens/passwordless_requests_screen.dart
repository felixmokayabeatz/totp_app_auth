import 'dart:async';

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
  Timer? _refreshTimer;

  bool _isLoading = true;
  bool _isActing = false;
  List<Map<String, dynamic>> _requests = const [];
  final Map<String, String> _selectedCodes = {};

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white54 : Colors.grey.shade600;

  @override
  void initState() {
    super.initState();
    _loadRequests();
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

  Future<void> _loadRequests() async {
    final requests = await _syncService.getPasswordlessRequests();
    if (!mounted) return;
    setState(() {
      _requests = requests;
      final requestIds = requests
          .map((item) => item['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      _selectedCodes.removeWhere((requestId, _) => !requestIds.contains(requestId));
      for (final item in requests) {
        final requestId = item['id']?.toString() ?? '';
        if (requestId.isEmpty) {
          continue;
        }
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
      await _loadRequests();
    }
  }

  Widget _buildChoiceButton(
    String choice, {
    required bool selected,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: 108,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: selected
              ? _accent
              : _accent.withValues(alpha: _isDark ? 0.18 : 0.08),
          foregroundColor: selected ? Colors.white : _accent,
          elevation: 0,
          side: BorderSide(
            color: selected ? _accent : _accent.withValues(alpha: 0.4),
            width: 1.6,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Text(
          choice,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.8,
          ),
        ),
      ),
    );
  }

  Widget _buildRequestCard(Map<String, dynamic> item) {
    final status = (item['status']?.toString() ?? 'pending').toLowerCase();
    final isPending = status == 'pending';
    final requestId = item['id']?.toString() ?? '';
    final label = item['requester_device_label']?.toString() ?? 'Unknown device';
    final kind = item['requester_device_kind']?.toString() ?? 'unknown';
    final code = item['verification_code']?.toString() ?? '---';
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                if (isPending && choices.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Choose the exact 3-digit code shown on $label',
                    style: TextStyle(
                      color: _textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
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
                if (choices.isNotEmpty)
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final choice in choices)
                        _buildChoiceButton(
                          choice,
                          selected: selectedCode == choice,
                          onPressed: _isActing
                              ? null
                              : () => setState(() {
                                    _selectedCodes[requestId] = choice;
                                  }),
                        ),
                    ],
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
