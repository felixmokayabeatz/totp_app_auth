import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/secure_message.dart';
import '../services/sync_service.dart';

class SecureSelfTextScreen extends StatefulWidget {
  const SecureSelfTextScreen({super.key, this.initialMessageId});

  final String? initialMessageId;

  @override
  State<SecureSelfTextScreen> createState() => _SecureSelfTextScreenState();
}

class _SecureSelfTextScreenState extends State<SecureSelfTextScreen> {
  static const String _retentionPreferenceKey =
      'secure_self_text_retention_minutes';
  static const List<_SecureMessageRetentionOption> _retentionOptions = [
    _SecureMessageRetentionOption(10, '10 minutes'),
    _SecureMessageRetentionOption(30, '30 minutes'),
    _SecureMessageRetentionOption(60, '1 hour'),
    _SecureMessageRetentionOption(6 * 60, '6 hours'),
    _SecureMessageRetentionOption(12 * 60, '12 hours'),
    _SecureMessageRetentionOption(24 * 60, '24 hours'),
    _SecureMessageRetentionOption(3 * 24 * 60, '3 days'),
    _SecureMessageRetentionOption(7 * 24 * 60, '7 days'),
    _SecureMessageRetentionOption(30 * 24 * 60, '1 month'),
    _SecureMessageRetentionOption(
      SecureMessage.foreverRetentionMinutes,
      'Keep forever',
    ),
  ];

  final SyncService _syncService = SyncService();
  final TextEditingController _composerController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _messageKeys = {};

  Box<SecureMessage>? _messageBox;
  Timer? _pollTimer;
  bool _isLoading = true;
  bool _isSending = false;
  String? _vaultIdentity;
  int _selectedRetentionMinutes = SecureMessage.defaultRetentionMinutes;
  String? _highlightedMessageId;
  bool _initialMessageRevealScheduled = false;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _cardColor => Theme.of(context).colorScheme.surface;
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
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    try {
      final selectedRetentionMinutes = await _loadRetentionPreference();
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
        _selectedRetentionMinutes = selectedRetentionMinutes;
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

  Future<int> _loadRetentionPreference() async {
    final prefs = await SharedPreferences.getInstance();
    return SecureMessage.normalizeRetentionMinutes(
      prefs.getInt(_retentionPreferenceKey),
    );
  }

  Future<void> _setRetentionPreference(int retentionMinutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_retentionPreferenceKey, retentionMinutes);
    if (!mounted) return;
    setState(() {
      _selectedRetentionMinutes = retentionMinutes;
    });
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

  String _retentionLabel(int retentionMinutes) {
    if (retentionMinutes == SecureMessage.foreverRetentionMinutes) {
      return 'Forever';
    }

    for (final option in _retentionOptions) {
      if (option.minutes == retentionMinutes) {
        return option.label;
      }
    }

    if (retentionMinutes % (24 * 60) == 0) {
      final days = retentionMinutes ~/ (24 * 60);
      return '$days day${days == 1 ? '' : 's'}';
    }
    if (retentionMinutes % 60 == 0) {
      final hours = retentionMinutes ~/ 60;
      return '$hours hour${hours == 1 ? '' : 's'}';
    }
    return '$retentionMinutes minutes';
  }

  String _retentionCaption(int retentionMinutes) {
    if (retentionMinutes == SecureMessage.foreverRetentionMinutes) {
      return 'Saved until you delete it';
    }
    return 'Auto-clears after ${_retentionLabel(retentionMinutes).toLowerCase()}';
  }

  Future<void> _showRetentionPicker() async {
    final selectedValue = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        final mediaQuery = MediaQuery.of(sheetContext);
        final bottomSafeSpace = mediaQuery.viewPadding.bottom + 28;

        return Padding(
          padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
          child: SizedBox(
            height: mediaQuery.size.height * 0.72,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The bottomSheetTheme draws the grab handle now.
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Choose delete timer',
                          style: TextStyle(
                            color: _textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close_rounded),
                        color: _textSecondary,
                        onPressed: () => Navigator.pop(sheetContext),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'New secure self texts will use this timer until you change it again.',
                    style: TextStyle(color: _textSecondary, height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.only(bottom: bottomSafeSpace),
                      children: [
                        for (final option in _retentionOptions)
                          ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            tileColor:
                                option.minutes == _selectedRetentionMinutes
                                    ? _accent.withValues(alpha: 0.12)
                                    : Colors.transparent,
                            leading: Icon(
                              option.minutes ==
                                      SecureMessage.foreverRetentionMinutes
                                  ? Icons.all_inbox_rounded
                                  : Icons.timer_outlined,
                              color: _accent,
                            ),
                            title: Text(
                              option.label,
                              style: TextStyle(
                                color: _textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              option.minutes ==
                                      SecureMessage.foreverRetentionMinutes
                                  ? 'Only manual delete removes it.'
                                  : 'Deletes automatically after ${option.label.toLowerCase()}.',
                              style: TextStyle(color: _textSecondary),
                            ),
                            trailing:
                                option.minutes == _selectedRetentionMinutes
                                    ? Icon(Icons.check_circle, color: _accent)
                                    : null,
                            onTap: () =>
                                Navigator.pop(sheetContext, option.minutes),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (selectedValue == null) return;
    await _setRetentionPreference(selectedValue);
  }

  KeyEventResult _handleComposerKeyEvent(FocusNode node, KeyEvent event) {
    final isEnterKey = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnterKey || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }

    if (_isSending) {
      return KeyEventResult.handled;
    }

    unawaited(_sendMessage());
    return KeyEventResult.handled;
  }

  GlobalKey _messageKeyFor(String messageId) {
    return _messageKeys.putIfAbsent(messageId, () => GlobalKey());
  }

  void _scheduleMessageReveal(List<SecureMessage> messages) {
    final targetMessageId = widget.initialMessageId;
    if (_initialMessageRevealScheduled ||
        targetMessageId == null ||
        targetMessageId.isEmpty ||
        !messages.any((message) => message.id == targetMessageId)) {
      return;
    }

    _initialMessageRevealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = _messageKeyFor(targetMessageId).currentContext;
      if (targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.2,
      ).then((_) {
        if (!mounted) return;
        setState(() {
          _highlightedMessageId = targetMessageId;
        });
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (!mounted || _highlightedMessageId != targetMessageId) return;
          setState(() {
            _highlightedMessageId = null;
          });
        });
      });
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
        retentionMinutes: _selectedRetentionMinutes,
        userId: userId,
      );
      await box.put(message.id, message);
      _composerController.clear();

      if (await _syncService.isLoggedIn() &&
          await _syncService.isSyncEnabled()) {
        final synced = await _syncService.syncSecureMessages();
        if (synced) {
          await _syncService.logSecureSelfTextNotification(
            messageId: message.id,
            previewText: text,
            authorDeviceLabel: deviceLabel,
          );
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _syncService.lastErrorMessage ??
                    'Secure text saved locally but did not sync yet.',
              ),
              backgroundColor: Colors.orange,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
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
              'Send a secure message to yourself here. Your own devices under this account will pick it up through encrypted sync, and each message uses the delete timer you choose.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _textSecondary, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(SecureMessage message, String userId) {
    final isHighlighted = _highlightedMessageId == message.id;

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        key: _messageKeyFor(message.id),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 12),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: _accent,
          borderRadius: BorderRadius.circular(18),
          border: isHighlighted
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.85),
                  width: 2,
                )
              : null,
          boxShadow: isHighlighted
              ? [
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.18),
                    blurRadius: 20,
                    spreadRadius: 1,
                  ),
                ]
              : null,
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
            Text(
              _retentionCaption(message.retentionMinutes),
              style: const TextStyle(
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

                          _scheduleMessageReveal(messages);

                          return ListView(
                            controller: _scrollController,
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
                                  'This is your private self-text feed. Messages stay tied to your own BeatzLock account, sync only through encrypted account data, and you can set each new message to delete after 10 minutes, 24 hours, or stay until you remove it.',
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _showRetentionPicker,
                        icon: const Icon(Icons.timer_outlined),
                        label: Text(
                          'Delete: ${_retentionLabel(_selectedRetentionMinutes)}',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Focus(
                          onKeyEvent: _handleComposerKeyEvent,
                          child: TextField(
                            controller: _composerController,
                            minLines: 1,
                            maxLines: 5,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sendMessage(),
                            decoration: InputDecoration(
                              hintText: 'Type a secure message to yourself',
                              helperText: _retentionCaption(
                                _selectedRetentionMinutes,
                              ),
                              border: const OutlineInputBorder(),
                            ),
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SecureMessageRetentionOption {
  const _SecureMessageRetentionOption(this.minutes, this.label);

  final int minutes;
  final String label;
}
