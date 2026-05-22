import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/secure_message.dart';
import '../services/sync_service.dart';

class SecureSelfTextScreen extends StatefulWidget {
  const SecureSelfTextScreen({super.key});

  @override
  State<SecureSelfTextScreen> createState() => _SecureSelfTextScreenState();
}

class _SecureSelfTextScreenState extends State<SecureSelfTextScreen> {
  final SyncService _syncService = SyncService();
  final TextEditingController _composerController = TextEditingController();

  Box<SecureMessage>? _messageBox;
  Timer? _pollTimer;
  bool _isLoading = true;
  bool _isSending = false;
  String? _vaultIdentity;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white54 : Colors.grey.shade600;

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _composerController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    try {
      await _syncService.purgeExpiredSecureMessages();
      if (await _syncService.isLoggedIn() &&
          await _syncService.isSyncEnabled()) {
        await _syncService.downloadAndMergeSecureMessages();
      }
      final box = await _syncService.getSecureMessageBox();
      final vaultIdentity = await _syncService.getCurrentVaultIdentity();
      if (!mounted) return;
      setState(() {
        _messageBox = box;
        _vaultIdentity = vaultIdentity;
        _isLoading = false;
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load your secure self texts: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (!mounted) return;

      final expiredCount = await _syncService.purgeExpiredSecureMessages();
      if (expiredCount > 0 &&
          await _syncService.isLoggedIn() &&
          await _syncService.isSyncEnabled()) {
        await _syncService.syncSecureMessages();
      }

      if (!await _syncService.isLoggedIn() ||
          !await _syncService.isSyncEnabled()) {
        return;
      }
      await _syncService.downloadAndMergeSecureMessages();
    });
  }

  Future<void> _sendMessage() async {
    final text = _composerController.text.trim();
    if (text.isEmpty) return;

    setState(() => _isSending = true);
    try {
      final userId = await _syncService.getCurrentVaultIdentity();
      final deviceLabel = await _syncService.getCurrentDeviceLabel();
      final box = _messageBox ?? await _syncService.getSecureMessageBox();
      final message = SecureMessage(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        text: text,
        createdAt: DateTime.now(),
        authorDeviceLabel: deviceLabel,
        userId: userId,
      );
      await box.put(message.id, message);
      _composerController.clear();

      if (await _syncService.isLoggedIn() &&
          await _syncService.isSyncEnabled()) {
        await _syncService.syncSecureMessages();
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  String _formatTime(DateTime dateTime) {
    final local = dateTime.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _formatDateTime(DateTime dateTime) {
    final local = dateTime.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    final year = local.year.toString();
    return '$day/$month/$year ${_formatTime(local)}';
  }

  Future<void> _copyMessage(SecureMessage message, String userId) async {
    await Clipboard.setData(ClipboardData(text: message.getText(userId)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Message copied.'),
        backgroundColor: Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _deleteMessage(SecureMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Delete message', style: TextStyle(color: _textPrimary)),
        content: Text(
          'Delete this secure self text?',
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

    final box = _messageBox ?? await _syncService.getSecureMessageBox();
    await box.delete(message.id);
    await _syncService.markSecureMessageDeleted(message.id);
    if (await _syncService.isLoggedIn() && await _syncService.isSyncEnabled()) {
      await _syncService.syncSecureMessages();
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Message deleted.'),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline_rounded, size: 52, color: _accent),
            const SizedBox(height: 16),
            Text(
              'No secure texts yet',
              style: TextStyle(
                color: _textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Send a secure message to yourself here. Your own devices under this account will pick it up through encrypted sync, and each message clears itself after 30 minutes.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _textSecondary, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(SecureMessage message, String userId) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 12),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: _accent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    message.getText(userId),
                    style: const TextStyle(
                      color: Colors.white,
                      height: 1.45,
                      fontSize: 14,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  color: _cardColor,
                  icon: const Icon(
                    Icons.more_horiz_rounded,
                    color: Colors.white70,
                  ),
                  onSelected: (value) async {
                    if (value == 'copy') {
                      await _copyMessage(message, userId);
                    } else if (value == 'delete') {
                      await _deleteMessage(message);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'copy', child: Text('Copy message')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Auto-clears after 30 minutes',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if ((message.authorDeviceLabel ?? '').trim().isNotEmpty)
                  Text(
                    message.authorDeviceLabel!,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                Text(
                  _formatDateTime(message.createdAt),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final box = _messageBox;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Secure Self Text',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : box == null
                    ? Center(
                        child: Text(
                          'Secure text vault unavailable.',
                          style: TextStyle(color: _textSecondary),
                        ),
                      )
                    : ValueListenableBuilder(
                        valueListenable: box.listenable(),
                        builder: (context, Box<SecureMessage> messageBox, _) {
                          final messages = messageBox.values.toList()
                            ..sort(
                                (a, b) => a.createdAt.compareTo(b.createdAt));
                          if (messages.isEmpty) {
                            return _buildEmptyState();
                          }

                          final userId = _vaultIdentity;
                          if (userId == null || userId.isEmpty) {
                            return const Center(
                                child: CircularProgressIndicator());
                          }

                          return ListView(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            children: [
                              Container(
                                margin: const EdgeInsets.only(bottom: 14),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: _cardColor,
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Text(
                                  'This is your private self-text feed. Messages stay tied to your own BeatzLock account, sync only through encrypted account data, and clear themselves after 30 minutes.',
                                  style: TextStyle(
                                    color: _textSecondary,
                                    height: 1.45,
                                  ),
                                ),
                              ),
                              for (final message in messages)
                                _buildMessageBubble(message, userId),
                            ],
                          );
                        },
                      ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              decoration: BoxDecoration(
                color: _cardColor,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: _isDark ? 0.22 : 0.06,
                    ),
                    blurRadius: 16,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composerController,
                      minLines: 1,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        hintText: 'Type a secure message to yourself',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    onPressed: _isSending ? null : _sendMessage,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(58, 54),
                    ),
                    child: _isSending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
