import 'dart:async';

import 'package:flutter/material.dart';
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
      if (await _syncService.isLoggedIn() && await _syncService.isSyncEnabled()) {
        await _syncService.downloadAndMergeSecureMessages();
      }
      final box = await _syncService.getSecureMessageBox();
      if (!mounted) return;
      setState(() {
        _messageBox = box;
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
      if (!await _syncService.isLoggedIn() || !await _syncService.isSyncEnabled()) {
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
      final userId = await _syncService.getCurrentUser() ?? 'default_user';
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

      if (await _syncService.isLoggedIn() && await _syncService.isSyncEnabled()) {
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
              'Send a secure message to yourself here. Your own devices under this account will pick it up through encrypted sync.',
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
        padding: const EdgeInsets.all(14),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: _accent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.getText(userId),
              style: const TextStyle(
                color: Colors.white,
                height: 1.45,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if ((message.authorDeviceLabel ?? '').trim().isNotEmpty)
                  Flexible(
                    child: Text(
                      message.authorDeviceLabel!,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if ((message.authorDeviceLabel ?? '').trim().isNotEmpty)
                  const SizedBox(width: 8),
                Text(
                  _formatTime(message.createdAt),
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
                            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
                          if (messages.isEmpty) {
                            return _buildEmptyState();
                          }

                          return FutureBuilder<String?>(
                            future: _syncService.getCurrentUser(),
                            builder: (context, snapshot) {
                              final userId = snapshot.data ?? 'default_user';
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
                                      'This is your private self-text feed. Messages stay tied to your own BeatzLock account and sync only through encrypted account data.',
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
                    color: Colors.black.withValues(alpha: _isDark ? 0.22 : 0.06),
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
