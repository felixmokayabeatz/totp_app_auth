import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:file_selector_windows/file_selector_windows.dart';

import '../models/password_entry.dart';
import '../services/app_lock_service.dart';
import '../services/password_import_service.dart';
import '../services/secure_storage_service.dart';
import '../services/sync_service.dart';
import 'secure_self_text_screen.dart';

class PasswordsScreen extends StatefulWidget {
  const PasswordsScreen({super.key});

  @override
  State<PasswordsScreen> createState() => _PasswordsScreenState();
}

class _PasswordsScreenState extends State<PasswordsScreen> {
  static const MethodChannel _filePickerChannel =
      MethodChannel('com.beatzlock.otp/file_picker');
  final SyncService _syncService = SyncService();
  final AppLockService _appLockService = AppLockService();
  final SecureStorageService _secureStorage = SecureStorageService();

  Box<PasswordEntry>? _passwordBox;
  bool _isLoading = true;
  bool _isSyncing = false;
  bool _isImporting = false;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _bgColor => Theme.of(context).scaffoldBackgroundColor;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white54 : Colors.grey.shade600;

  @override
  void initState() {
    super.initState();
    _loadVault();
  }

  Future<void> _loadVault() async {
    try {
      if (await _syncService.isLoggedIn() && await _syncService.isSyncEnabled()) {
        await _syncService.downloadAndMergePasswordEntries();
      }

      final box = await _syncService.getPasswordBox();
      if (!mounted) return;
      setState(() {
        _passwordBox = box;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load your secure passwords: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<String> _currentUserId() async {
    return await _secureStorage.read(SecureStorageService.currentUserKey) ??
        await _secureStorage.read(SecureStorageService.localVaultUserKey) ??
        'default_user';
  }

  Future<void> _refreshFromCloud() async {
    setState(() => _isSyncing = true);
    try {
      await _syncService.downloadAndMergePasswordEntries();
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  Future<void> _syncNow() async {
    setState(() => _isSyncing = true);
    final success = await _syncService.syncPasswordEntries();
    if (!mounted) return;
    setState(() => _isSyncing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Secure items synced.'
              : (_syncService.lastErrorMessage ?? 'Password sync failed.'),
        ),
        backgroundColor: success ? const Color(0xFF10B981) : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _importPasswords() async {
    final proceed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: _cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.upload_file_rounded, color: _accent),
                title: const Text('Import CSV or JSON'),
                subtitle: const Text(
                  'Choose a password export file from Proton Pass, browsers, or other managers. Paste import is disabled.',
                ),
                onTap: () => Navigator.pop(sheetContext, true),
              ),
            ],
          ),
        ),
      ),
    );

    if (proceed == true) {
      await _importPasswordsFromFile();
    }
  }

  Future<void> _importPasswordsFromFile() async {
    setState(() => _isImporting = true);
    try {
      final importFile = await _pickImportFile();
      if (!mounted || importFile == null) {
        if (mounted) setState(() => _isImporting = false);
        return;
      }

      final lower = importFile.fileName.toLowerCase();
      if (!lower.endsWith('.csv') && !lower.endsWith('.json')) {
        if (!mounted) return;
        setState(() => _isImporting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Choose a .csv or .json password export file.'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      await _finishPasswordImport(
        importFile.contents,
        fileName: importFile.fileName,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isImporting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not import that password export file: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<_PickedImportFile?> _pickImportFile() async {
    if (Platform.isWindows) {
      final file = await FileSelectorWindows().openFile(
        confirmButtonText: 'Import passwords',
      );
      if (file == null) {
        return null;
      }

      return _PickedImportFile(
        fileName: file.name,
        contents: await file.readAsString(),
      );
    }

    if (Platform.isAndroid) {
      final payload = await _filePickerChannel.invokeMethod<dynamic>(
        'pickPasswordImportFile',
      );
      if (payload == null) {
        return null;
      }

      final fileMap = Map<String, dynamic>.from(payload as Map);
      final fileName =
          fileMap['fileName']?.toString().trim().isNotEmpty == true
              ? fileMap['fileName'].toString().trim()
              : 'password-import';
      final rawBytes = fileMap['bytes'];
      if (rawBytes is! Uint8List && rawBytes is! List) {
        throw Exception('The selected file could not be read.');
      }

      final bytes = rawBytes is Uint8List
          ? rawBytes
          : Uint8List.fromList(List<int>.from(rawBytes as List));
      return _PickedImportFile(
        fileName: fileName,
        contents: utf8.decode(bytes, allowMalformed: true),
      );
    }

    throw Exception('Password file import is not available on this device yet.');
  }

  Future<void> _finishPasswordImport(
    String contents, {
    required String fileName,
  }) async {
    final importedEntries =
        PasswordImportService().parse(contents, fileName: fileName);
    final result = await _saveImportedPasswordEntries(importedEntries);
    if (!mounted) return;
    setState(() => _isImporting = false);
    final success = !result.toLowerCase().startsWith('could not');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result),
        backgroundColor: success ? const Color(0xFF10B981) : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<String> _saveImportedPasswordEntries(
      List<PasswordImportEntry> entries) async {
    if (entries.isEmpty) {
      return 'No supported password items were found in that export.';
    }

    final box = _passwordBox ?? await _syncService.getPasswordBox();
    final userId = await _currentUserId();
    var importedCount = 0;
    var skippedCount = 0;

    for (final imported in entries) {
      final importedUsername = _importedUsername(imported);
      final duplicate = box.values.any((entry) {
        final sameTitle = entry.title.toLowerCase() == imported.title.toLowerCase();
        final sameUsername =
            entry.username.toLowerCase() == importedUsername.toLowerCase();
        final sameContext =
            (entry.serverIP ?? '').toLowerCase() == (imported.url ?? '').toLowerCase();
        return sameTitle && sameUsername && sameContext;
      });
      if (duplicate) {
        skippedCount++;
        continue;
      }

      final entry = PasswordEntry(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: imported.title,
        username: importedUsername,
        password: imported.password ?? '',
        note: _buildImportedEncryptedNote(imported),
        serverIP: imported.url,
        createdAt: imported.createdAt ?? DateTime.now(),
        userId: userId,
      );
      await box.put(entry.id, entry);
      importedCount++;
    }

    if (importedCount > 0 &&
        await _syncService.isLoggedIn() &&
        await _syncService.isSyncEnabled()) {
      await _syncService.syncPasswordEntries();
    }

    if (importedCount == 0) {
      return skippedCount > 0
          ? 'Everything in that export was already in your vault.'
          : 'No supported password items were found in that export.';
    }

    if (skippedCount == 0) {
      return 'Imported $importedCount secure item${importedCount == 1 ? '' : 's'}.';
    }

    return 'Imported $importedCount secure item${importedCount == 1 ? '' : 's'} and skipped $skippedCount duplicate${skippedCount == 1 ? '' : 's'}.';
  }

  String _importedUsername(PasswordImportEntry entry) {
    final username = entry.username?.trim() ?? '';
    if (username.isNotEmpty) {
      return username;
    }
    return entry.email?.trim() ?? '';
  }

  String? _buildImportedEncryptedNote(PasswordImportEntry entry) {
    final sections = <String>[];
    final rawNote = entry.note?.trim() ?? '';
    if (rawNote.isNotEmpty) {
      sections.add(rawNote);
    }

    final metadata = <String>[];
    final normalizedUsername = _importedUsername(entry).trim().toLowerCase();
    final email = entry.email?.trim() ?? '';
    if (email.isNotEmpty && email.toLowerCase() != normalizedUsername) {
      metadata.add('Email: $email');
    }
    if ((entry.totp?.trim() ?? '').isNotEmpty) {
      metadata.add('TOTP: ${entry.totp!.trim()}');
    }
    if ((entry.vault?.trim() ?? '').isNotEmpty) {
      metadata.add('Vault: ${entry.vault!.trim()}');
    }
    if ((entry.type?.trim() ?? '').isNotEmpty) {
      metadata.add('Type: ${entry.type!.trim()}');
    }
    if (entry.createdAt != null) {
      metadata.add('Created: ${entry.createdAt!.toIso8601String()}');
    }
    if (entry.modifiedAt != null) {
      metadata.add('Modified: ${entry.modifiedAt!.toIso8601String()}');
    }

    if (metadata.isNotEmpty) {
      if (sections.isNotEmpty) {
        sections.add('');
      }
      sections.add('Imported metadata');
      sections.addAll(metadata);
    }

    if (sections.isEmpty) {
      return null;
    }
    return sections.join('\n');
  }

  String _entryTypeLabel(PasswordEntry entry, String userId) {
    final hasPassword = entry.getPassword(userId).trim().isNotEmpty;
    final hasNote = (entry.getNote(userId) ?? '').trim().isNotEmpty;
    if (hasPassword && hasNote) return 'Password + note';
    if (hasNote) return 'Secure note';
    return 'Password';
  }

  Future<void> _showEntryDialog({PasswordEntry? existing}) async {
    final titleController = TextEditingController(text: existing?.title ?? '');
    final usernameController =
        TextEditingController(text: existing?.username ?? '');
    final passwordController = TextEditingController();
    final noteController = TextEditingController();
    final serverController =
        TextEditingController(text: existing?.serverIP ?? '');
    final formKey = GlobalKey<FormState>();
    var isSaving = false;
    final userId = await _currentUserId();

    if (existing != null) {
      passwordController.text = existing.getPassword(userId);
      noteController.text = existing.getNote(userId) ?? '';
    }

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: _cardColor,
          title: Text(
            existing == null ? 'Save secure item' : 'Edit secure item',
            style: TextStyle(color: _textPrimary),
          ),
          content: SizedBox(
            width: 420,
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Save a password, private note, or both. It stays in your BeatzLock account vault and syncs only through your encrypted account data.',
                      style:
                          TextStyle(color: _textSecondary, fontSize: 13, height: 1.4),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: titleController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Title',
                        hintText: 'Example: Server root password or private note',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if ((value ?? '').trim().isEmpty) {
                          return 'Enter a title';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: usernameController,
                      decoration: const InputDecoration(
                        labelText: 'Username or email',
                        hintText: 'Optional',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: passwordController,
                      minLines: 3,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: 'Password or secret text',
                        hintText: 'Optional if you only want to save a secure note',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: noteController,
                      minLines: 4,
                      maxLines: 8,
                      decoration: const InputDecoration(
                        labelText: 'Private note',
                        hintText: 'Text yourself anything sensitive here',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        final hasPassword =
                            passwordController.text.trim().isNotEmpty;
                        final hasNote = (value ?? '').trim().isNotEmpty;
                        if (!hasPassword && !hasNote) {
                          return 'Enter a password, a note, or both';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: serverController,
                      decoration: const InputDecoration(
                        labelText: 'Website or context',
                        hintText: 'Optional app, site, or reminder',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed:
                  isSaving ? null : () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: isSaving
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) {
                        return;
                      }

                      setDialogState(() => isSaving = true);
                      final box = _passwordBox ?? await _syncService.getPasswordBox();
                      final entry = PasswordEntry(
                        id: existing?.id ??
                            DateTime.now().millisecondsSinceEpoch.toString(),
                        title: titleController.text.trim(),
                        username: usernameController.text.trim(),
                        password: passwordController.text.trim(),
                        note: noteController.text.trim(),
                        serverIP: serverController.text.trim().isEmpty
                            ? null
                            : serverController.text.trim(),
                        createdAt: existing?.createdAt ?? DateTime.now(),
                        userId: userId,
                      );
                      await box.put(entry.id, entry);

                      if (await _syncService.isLoggedIn() &&
                          await _syncService.isSyncEnabled()) {
                        await _syncService.syncPasswordEntries();
                      }

                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext);
                      }
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(existing == null
                              ? 'Secure item saved.'
                              : 'Secure item updated.'),
                          backgroundColor: const Color(0xFF10B981),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
              ),
              child: Text(isSaving ? 'Saving...' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyPassword(PasswordEntry entry) async {
    final unlocked = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !unlocked) return;

    final userId = await _currentUserId();
    final password = entry.getPassword(userId);
    if (password.trim().isEmpty) {
      final note = entry.getNote(userId) ?? '';
      if (note.trim().isEmpty) return;
      await Clipboard.setData(ClipboardData(text: note));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Secure note copied.'),
          backgroundColor: Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    await Clipboard.setData(ClipboardData(text: password));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Password copied.'),
        backgroundColor: Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _copyUsername(PasswordEntry entry) async {
    if (entry.username.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: entry.username));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Username copied.'),
        backgroundColor: Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _deleteEntry(PasswordEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: _cardColor,
        title: Text('Delete secure item',
            style: TextStyle(color: _textPrimary)),
        content: Text(
          'Delete "${entry.title}" from your secure vault?',
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

    final box = _passwordBox ?? await _syncService.getPasswordBox();
    await box.delete(entry.id);
    await _syncService.markPasswordEntryDeleted(entry.id);
    if (await _syncService.isLoggedIn() && await _syncService.isSyncEnabled()) {
      await _syncService.syncPasswordEntries();
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Secure item deleted.'),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _copyNote(PasswordEntry entry) async {
    final unlocked = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !unlocked) return;
    final userId = await _currentUserId();
    final note = entry.getNote(userId) ?? '';
    if (note.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: note));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Secure note copied.'),
        backgroundColor: Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _showPasswordSheet(PasswordEntry entry) async {
    final unlocked = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !unlocked) return;
    final userId = await _currentUserId();
    final password = entry.getPassword(userId);
    final note = entry.getNote(userId) ?? '';
    final hasPassword = password.trim().isNotEmpty;
    final hasNote = note.trim().isNotEmpty;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.title,
              style: TextStyle(
                color: _textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (entry.username.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                entry.username,
                style: TextStyle(color: _textSecondary),
              ),
            ],
            if ((entry.serverIP ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                entry.serverIP!,
                style: TextStyle(color: _textSecondary, fontSize: 12),
              ),
            ],
            if (hasPassword) ...[
              const SizedBox(height: 18),
              Text(
                'Password',
                style: TextStyle(
                  color: _textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                password,
                style: TextStyle(
                  color: _textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ],
            if (hasNote) ...[
              const SizedBox(height: 18),
              Text(
                'Private note',
                style: TextStyle(
                  color: _textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                note,
                style: TextStyle(
                  color: _textPrimary,
                  fontSize: 15,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                if (hasPassword)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: password));
                        if (sheetContext.mounted) {
                          Navigator.pop(sheetContext);
                        }
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Password copied.'),
                            backgroundColor: Color(0xFF10B981),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Copy password'),
                    ),
                  ),
                if (hasPassword && hasNote) const SizedBox(width: 10),
                if (hasNote)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: note));
                        if (sheetContext.mounted) {
                          Navigator.pop(sheetContext);
                        }
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Secure note copied.'),
                            backgroundColor: Color(0xFF10B981),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      icon: const Icon(Icons.notes_rounded),
                      label: Text(hasPassword ? 'Copy note' : 'Copy'),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _showEntryDialog(existing: entry);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.edit_rounded),
                label: const Text('Edit'),
              ),
            ),
          ],
        ),
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
            Icon(Icons.password_rounded, size: 52, color: _accent),
            const SizedBox(height: 16),
            Text(
              'No secure items yet',
              style: TextStyle(
                color: _textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Start by saving a password, a secure note, or both. Everything in this vault stays tied to your signed-in BeatzLock account.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _textSecondary, height: 1.45),
            ),
            const SizedBox(height: 18),
            ElevatedButton.icon(
              onPressed: () => _showEntryDialog(),
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Save first item'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntryCard(PasswordEntry entry) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: _isDark ? 0.16 : 0.05),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        style: TextStyle(
                          color: _textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      FutureBuilder<String>(
                        future: _currentUserId(),
                        builder: (context, snapshot) {
                          final id = snapshot.data;
                          if (id == null || id.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              _entryTypeLabel(entry, id),
                              style: TextStyle(
                                color: _accent,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          );
                        },
                      ),
                      if (entry.username.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          entry.username,
                          style: TextStyle(color: _textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') {
                      _showEntryDialog(existing: entry);
                    } else if (value == 'delete') {
                      _deleteEntry(entry);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            if ((entry.serverIP ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                entry.serverIP!,
                style: TextStyle(color: _textSecondary, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: _isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.grey.shade50,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                'Tap reveal to unlock and view the saved password or private note.',
                style: TextStyle(
                  color: _textSecondary,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (entry.username.trim().isNotEmpty)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _copyUsername(entry),
                      icon: const Icon(Icons.alternate_email_rounded),
                      label: const Text('Copy user'),
                    ),
                  ),
                if (entry.username.trim().isNotEmpty) const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _showPasswordSheet(entry),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.lock_open_rounded),
                    label: const Text('Reveal'),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: 'Quick copy',
                  onPressed: () => _copyPassword(entry),
                  icon: const Icon(Icons.copy_rounded),
                ),
                IconButton(
                  tooltip: 'Copy note',
                  onPressed: () => _copyNote(entry),
                  icon: const Icon(Icons.notes_rounded),
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
    final box = _passwordBox;

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: const Text(
          'Passwords & Notes',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Secure self text',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const SecureSelfTextScreen(),
                ),
              );
            },
            icon: const Icon(Icons.chat_bubble_rounded),
          ),
          IconButton(
            tooltip: 'Import passwords',
            onPressed: _isImporting ? null : _importPasswords,
            icon: _isImporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.upload_file_rounded),
          ),
          IconButton(
            tooltip: 'Sync now',
            onPressed: _isSyncing ? null : _syncNow,
            icon: _isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.sync_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showEntryDialog(),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : box == null
              ? Center(
                  child: Text(
                    'Password vault unavailable.',
                    style: TextStyle(color: _textSecondary),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _refreshFromCloud,
                  child: ValueListenableBuilder(
                    valueListenable: box.listenable(),
                    builder: (context, Box<PasswordEntry> passwordBox, _) {
                      final entries = passwordBox.values.toList()
                        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

                      if (entries.isEmpty) {
                        return ListView(children: [_buildEmptyState()]);
                      }

                      return ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                        children: [
                          Container(
                            margin: const EdgeInsets.only(bottom: 14),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: _cardColor,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Text(
                              'These entries are for your own account only. Reveal and copy actions ask for unlock again to keep this area tighter than the normal OTP list.',
                              style: TextStyle(
                                color: _textSecondary,
                                height: 1.45,
                              ),
                            ),
                          ),
                          for (final entry in entries) _buildEntryCard(entry),
                        ],
                      );
                    },
                  ),
                ),
    );
  }
}

class _PickedImportFile {
  const _PickedImportFile({
    required this.fileName,
    required this.contents,
  });

  final String fileName;
  final String contents;
}
