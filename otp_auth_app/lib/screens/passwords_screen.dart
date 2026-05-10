import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:file_selector_windows/file_selector_windows.dart';

import '../models/password_entry.dart';
import '../services/app_lock_service.dart';
import '../services/password_import_service.dart';
import '../services/secure_storage_service.dart';
import '../services/sync_service.dart';
import '../widgets/account_logo_badge.dart';
import 'secure_self_text_screen.dart';

class PasswordsScreen extends StatefulWidget {
  const PasswordsScreen({
    super.key,
    this.openImportOnStart = false,
  });

  final bool openImportOnStart;

  @override
  State<PasswordsScreen> createState() => _PasswordsScreenState();
}

class _PasswordsScreenState extends State<PasswordsScreen> {
  final SyncService _syncService = SyncService();
  final AppLockService _appLockService = AppLockService();
  final SecureStorageService _secureStorage = SecureStorageService();
  final TextEditingController _searchController = TextEditingController();

  Box<PasswordEntry>? _passwordBox;
  bool _isLoading = true;
  bool _isSyncing = false;
  bool _isImporting = false;
  bool _isSelectionMode = false;
  String _searchQuery = '';
  final Set<String> _selectedEntryIds = <String>{};

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _bgColor => Theme.of(context).scaffoldBackgroundColor;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white54 : Colors.grey.shade600;
  bool get _canImportPasswords => Platform.isWindows;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (!mounted) return;
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
    _loadVault();
    if (widget.openImportOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _importPasswords();
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadVault() async {
    try {
      if (await _syncService.isLoggedIn() &&
          await _syncService.isSyncEnabled()) {
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
    if (!_canImportPasswords) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password import is desktop-only right now.'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

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
                  'Choose a password export file from Proton Pass, browsers, or other managers.',
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

    throw Exception(
        'Password file import is not available on this device yet.');
  }

  Future<void> _finishPasswordImport(
    String contents, {
    required String fileName,
  }) async {
    final importedEntries =
        PasswordImportService().parse(contents, fileName: fileName);
    if (importedEntries.isEmpty) {
      if (!mounted) return;
      setState(() => _isImporting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('No supported password items were found in that export.'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final confirmed = await _confirmImportBeforeSaving(
      fileName: fileName,
      entryCount: importedEntries.length,
    );
    if (!mounted || confirmed != true) {
      if (mounted) {
        setState(() => _isImporting = false);
      }
      return;
    }

    final result = await _saveImportedPasswordEntries(
      importedEntries,
      sourceLabel: fileName,
    );
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

  Future<bool?> _confirmImportBeforeSaving({
    required String fileName,
    required int entryCount,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        backgroundColor: _cardColor,
        title: Text(
          'Confirm import',
          style: TextStyle(color: _textPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Import $entryCount secure item${entryCount == 1 ? '' : 's'} from this file?',
              style: TextStyle(
                color: _textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: _isDark ? 0.14 : 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _accent.withValues(alpha: 0.16),
                ),
              ),
              child: Text(
                fileName,
                style: TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Imported items will be saved into your encrypted vault. Duplicates can still be skipped.',
              style: TextStyle(
                color: _textSecondary,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Import now'),
          ),
        ],
      ),
    );
  }

  Future<String> _saveImportedPasswordEntries(
    List<PasswordImportEntry> entries, {
    String? sourceLabel,
  }) async {
    if (entries.isEmpty) {
      return 'No supported password items were found in that export.';
    }

    final box = _passwordBox ?? await _syncService.getPasswordBox();
    final userId = await _currentUserId();
    var importedCount = 0;

    for (var index = 0; index < entries.length; index++) {
      final imported = entries[index];
      final importedUsername = _importedUsername(imported);
      final entry = PasswordEntry(
        id: '${DateTime.now().microsecondsSinceEpoch}_${index}_${imported.title.hashCode.abs()}',
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

    if (importedCount > 0 && await _syncService.isLoggedIn()) {
      try {
        await _syncService.logPasswordsImportedNotification(
          importedCount: importedCount,
          sourceLabel: sourceLabel,
        );
      } catch (_) {}
    }

    if (importedCount == 0) {
      return 'No supported password items were found in that export.';
    }

    return 'Imported $importedCount secure item${importedCount == 1 ? '' : 's'}.';
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

  String _contextLabel(PasswordEntry entry) {
    final raw = (entry.serverIP ?? '').trim();
    if (raw.isEmpty) return 'Private vault';
    try {
      final parsed = Uri.parse(raw);
      if (parsed.host.trim().isNotEmpty) {
        return parsed.host.replaceFirst(RegExp(r'^www\.'), '');
      }
    } catch (_) {}

    final first = raw.split(',').first.trim();
    return first.isEmpty ? 'Private vault' : first;
  }

  String _entryInitial(PasswordEntry entry) {
    final source = entry.title.trim().isNotEmpty
        ? entry.title.trim()
        : _contextLabel(entry);
    return source.substring(0, 1).toUpperCase();
  }

  String _formatAdded(DateTime dateTime) {
    final local = dateTime.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    final year = local.year.toString();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$day/$month/$year $hour:$minute';
  }

  List<PasswordEntry> _sortedEntries(Iterable<PasswordEntry> values) {
    final entries = values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return entries;
  }

  List<PasswordEntry> _filteredEntriesFrom(List<PasswordEntry> entries) {
    return entries.where((entry) {
      if (_searchQuery.isEmpty) return true;
      final context = _contextLabel(entry).toLowerCase();
      return entry.title.toLowerCase().contains(_searchQuery) ||
          entry.username.toLowerCase().contains(_searchQuery) ||
          context.contains(_searchQuery);
    }).toList();
  }

  void _toggleSelectionMode([bool? enabled]) {
    if (!mounted) return;
    setState(() {
      _isSelectionMode = enabled ?? !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedEntryIds.clear();
      }
    });
  }

  void _toggleEntrySelection(String entryId) {
    if (!mounted) return;
    setState(() {
      _isSelectionMode = true;
      if (_selectedEntryIds.contains(entryId)) {
        _selectedEntryIds.remove(entryId);
      } else {
        _selectedEntryIds.add(entryId);
      }
      if (_selectedEntryIds.isEmpty) {
        _isSelectionMode = false;
      }
    });
  }

  void _toggleSelectAllVisible(List<PasswordEntry> entries) {
    if (!mounted) return;
    final visibleIds = entries.map((entry) => entry.id).toSet();
    setState(() {
      _isSelectionMode = true;
      final allVisibleSelected = visibleIds.isNotEmpty &&
          visibleIds.every((entryId) => _selectedEntryIds.contains(entryId));
      if (allVisibleSelected) {
        _selectedEntryIds.removeAll(visibleIds);
      } else {
        _selectedEntryIds.addAll(visibleIds);
      }
      if (_selectedEntryIds.isEmpty) {
        _isSelectionMode = false;
      }
    });
  }

  Future<void> _deleteEntries(
    List<PasswordEntry> entries, {
    required bool deleteAll,
  }) async {
    if (entries.isEmpty) return;

    var acknowledged = false;
    var confirmationText = '';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final requiresPhrase = deleteAll;
          final validPhrase = confirmationText.trim().toUpperCase() == 'DELETE ALL';
          final canDelete = acknowledged && (!requiresPhrase || validPhrase);

          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            backgroundColor: _cardColor,
            title: Text(
              deleteAll ? 'Delete all secure items' : 'Delete selected items',
              style: TextStyle(color: _textPrimary),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  deleteAll
                      ? 'This will remove all ${entries.length} secure item${entries.length == 1 ? '' : 's'} from this vault and sync that deletion to your other devices.'
                      : 'This will remove ${entries.length} selected secure item${entries.length == 1 ? '' : 's'} from this vault and sync that deletion to your other devices.',
                  style: TextStyle(
                    color: _textSecondary,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 14),
                CheckboxListTile(
                  value: acknowledged,
                  contentPadding: EdgeInsets.zero,
                  activeColor: _accent,
                  title: Text(
                    'I understand this cannot be undone from the app.',
                    style: TextStyle(
                      color: _textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (value) {
                    setDialogState(() => acknowledged = value ?? false);
                  },
                ),
                if (deleteAll) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Type DELETE ALL to confirm.',
                    style: TextStyle(
                      color: _textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    onChanged: (value) {
                      setDialogState(() => confirmationText = value);
                    },
                    decoration: const InputDecoration(
                      hintText: 'DELETE ALL',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed:
                    canDelete ? () => Navigator.pop(dialogContext, true) : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child:
                    Text(deleteAll ? 'Delete everything' : 'Delete selected'),
              ),
            ],
          );
        },
      ),
    );

    if (confirmed != true) return;

    final box = _passwordBox ?? await _syncService.getPasswordBox();
    final ids = entries.map((entry) => entry.id).toList(growable: false);
    await box.deleteAll(ids);
    for (final id in ids) {
      await _syncService.markPasswordEntryDeleted(id);
    }
    if (await _syncService.isLoggedIn() && await _syncService.isSyncEnabled()) {
      await _syncService.syncPasswordEntries();
    }

    if (!mounted) return;
    setState(() {
      _selectedEntryIds.removeAll(ids);
      if (_selectedEntryIds.isEmpty) {
        _isSelectionMode = false;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          deleteAll
              ? 'All secure items deleted.'
              : '${ids.length} secure item${ids.length == 1 ? '' : 's'} deleted.',
        ),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildInfoChip({
    required IconData icon,
    required String label,
    Color? color,
  }) {
    final resolvedColor = color ?? _accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: resolvedColor.withValues(alpha: _isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: resolvedColor.withValues(alpha: 0.22),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: resolvedColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: resolvedColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
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
                      style: TextStyle(
                          color: _textSecondary, fontSize: 13, height: 1.4),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: titleController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Title',
                        hintText:
                            'Example: Server root password or private note',
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
                        hintText:
                            'Optional if you only want to save a secure note',
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
              onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
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
                      final box =
                          _passwordBox ?? await _syncService.getPasswordBox();
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
        title:
            Text('Delete secure item', style: TextStyle(color: _textPrimary)),
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
    if (!mounted) return;
    final password = entry.getPassword(userId);
    final note = entry.getNote(userId) ?? '';
    final hasPassword = password.trim().isNotEmpty;
    final hasNote = note.trim().isNotEmpty;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        final mediaQuery = MediaQuery.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              28 + mediaQuery.viewInsets.bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: mediaQuery.size.height * 0.82,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
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
                              style: TextStyle(
                                  color: _textSecondary, fontSize: 12),
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
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      if (hasPassword)
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: password),
                              );
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
                              await Clipboard.setData(
                                  ClipboardData(text: note));
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
          ),
        );
      },
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

  Widget _buildEntryCard(
    PasswordEntry entry, {
    required bool selectionMode,
    required bool isSelected,
  }) {
    final contextLabel = _contextLabel(entry);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _cardColor,
            _isDark
                ? const Color(0xFF161629)
                : Color.lerp(_cardColor, _accent, 0.035)!,
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isSelected
              ? _accent.withValues(alpha: 0.85)
              : _isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : _accent.withValues(alpha: 0.08),
          width: isSelected ? 1.6 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: _isDark ? 0.18 : 0.06),
            blurRadius: 26,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onLongPress: () => _toggleEntrySelection(entry.id),
          onTap: selectionMode ? () => _toggleEntrySelection(entry.id) : null,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (selectionMode) ...[
                      Padding(
                        padding: const EdgeInsets.only(right: 12, top: 10),
                        child: Checkbox(
                          value: isSelected,
                          activeColor: _accent,
                          onChanged: (_) => _toggleEntrySelection(entry.id),
                        ),
                      ),
                    ],
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: _accent.withValues(alpha: _isDark ? 0.18 : 0.10),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Center(
                        child: AccountLogoBadge(
                          service: entry.title,
                          issuer: entry.serverIP,
                          size: 50,
                          iconSize: 24,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.title,
                            style: TextStyle(
                              color: _textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            contextLabel,
                            style: TextStyle(
                              color: _textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Added ${_formatAdded(entry.createdAt)}',
                            style: TextStyle(
                              color: _textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (entry.username.trim().isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              entry.username,
                              style: TextStyle(
                                color: _textPrimary.withValues(alpha: 0.92),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (selectionMode)
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? _accent.withValues(alpha: _isDark ? 0.22 : 0.14)
                              : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isSelected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: isSelected ? _accent : _textSecondary,
                          size: 22,
                        ),
                      )
                    else
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
                const SizedBox(height: 16),
                FutureBuilder<String>(
                  future: _currentUserId(),
                  builder: (context, snapshot) {
                    final id = snapshot.data;
                    if (id == null || id.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    final hasPassword = entry.getPassword(id).trim().isNotEmpty;
                    final hasNote = (entry.getNote(id) ?? '').trim().isNotEmpty;
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildInfoChip(
                          icon: Icons.shield_rounded,
                          label: _entryTypeLabel(entry, id),
                        ),
                        if (hasPassword)
                          _buildInfoChip(
                            icon: Icons.key_rounded,
                            label: 'Saved password',
                            color: const Color(0xFF0F766E),
                          ),
                        if (hasNote)
                          _buildInfoChip(
                            icon: Icons.notes_rounded,
                            label: 'Encrypted note',
                            color: const Color(0xFFC2410C),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: _isDark
                          ? [
                              _accent.withValues(alpha: 0.16),
                              Colors.white.withValues(alpha: 0.04),
                            ]
                          : [
                              _accent.withValues(alpha: 0.10),
                              _accent.withValues(alpha: 0.03),
                            ],
                    ),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: _accent.withValues(alpha: 0.15),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color:
                              _accent.withValues(alpha: _isDark ? 0.20 : 0.14),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.lock_open_rounded,
                          color: _accent,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          selectionMode
                              ? 'Tap cards to pick several items, then use the top bar to delete them safely.'
                              : 'Reveal to unlock the saved password or encrypted note for ${_entryInitial(entry)}.',
                          style: TextStyle(
                            color: _textSecondary,
                            height: 1.35,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (entry.username.trim().isNotEmpty)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              selectionMode ? null : () => _copyUsername(entry),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            side: BorderSide(
                              color: _accent.withValues(alpha: 0.22),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          icon: const Icon(Icons.alternate_email_rounded),
                          label: const Text('Copy user'),
                        ),
                      ),
                    if (entry.username.trim().isNotEmpty)
                      const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: selectionMode
                            ? null
                            : () => _showPasswordSheet(entry),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        icon: const Icon(Icons.visibility_rounded),
                        label: Text(selectionMode ? 'Selected' : 'Reveal'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed:
                            selectionMode ? null : () => _copyPassword(entry),
                        style: TextButton.styleFrom(
                          foregroundColor: _textPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.copy_rounded),
                        label: const Text('Quick copy'),
                      ),
                    ),
                    Expanded(
                      child: TextButton.icon(
                        onPressed:
                            selectionMode ? null : () => _copyNote(entry),
                        style: TextButton.styleFrom(
                          foregroundColor: _textPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.notes_rounded),
                        label: const Text('Copy note'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final box = _passwordBox;
    final sortedEntries =
        box == null ? <PasswordEntry>[] : _sortedEntries(box.values);
    final filteredEntries = _filteredEntriesFrom(sortedEntries);
    final allVisibleSelected = filteredEntries.isNotEmpty &&
        filteredEntries.every((entry) => _selectedEntryIds.contains(entry.id));

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: Text(
          _isSelectionMode
              ? '${_selectedEntryIds.length} selected'
              : 'Passwords & Notes (${sortedEntries.length})',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        actions: [
          if (_isSelectionMode) ...[
            IconButton(
              tooltip: allVisibleSelected
                  ? 'Clear visible selection'
                  : 'Select all visible',
              onPressed: filteredEntries.isEmpty
                  ? null
                  : () => _toggleSelectAllVisible(filteredEntries),
              icon: Icon(
                allVisibleSelected
                    ? Icons.deselect_rounded
                    : Icons.select_all_rounded,
              ),
            ),
            IconButton(
              tooltip: 'Delete selected',
              onPressed: _selectedEntryIds.isEmpty
                  ? null
                  : () => _deleteEntries(
                        sortedEntries
                            .where(
                              (entry) => _selectedEntryIds.contains(entry.id),
                            )
                            .toList(),
                        deleteAll: false,
                      ),
              icon: const Icon(Icons.delete_sweep_rounded),
            ),
            IconButton(
              tooltip: 'Close selection',
              onPressed: () => _toggleSelectionMode(false),
              icon: const Icon(Icons.close_rounded),
            ),
          ] else ...[
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
            PopupMenuButton<String>(
              tooltip: 'Vault actions',
              onSelected: (value) {
                if (value == 'select' && filteredEntries.isNotEmpty) {
                  _toggleSelectionMode(true);
                } else if (value == 'delete_all' && sortedEntries.isNotEmpty) {
                  _deleteEntries(sortedEntries, deleteAll: true);
                }
              },
              itemBuilder: (context) => [
                if (filteredEntries.isNotEmpty)
                  const PopupMenuItem(
                    value: 'select',
                    child: Text('Select multiple'),
                  ),
                if (sortedEntries.isNotEmpty)
                  const PopupMenuItem(
                    value: 'delete_all',
                    child: Text('Delete all'),
                  ),
              ],
            ),
            if (_canImportPasswords)
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
        ],
      ),
      floatingActionButton: _isSelectionMode
          ? null
          : FloatingActionButton.extended(
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
                      final entries = _sortedEntries(passwordBox.values);

                      if (entries.isEmpty) {
                        return ListView(children: [_buildEmptyState()]);
                      }

                      final filteredEntries = _filteredEntriesFrom(entries);

                      return ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                        children: [
                          Container(
                            margin: const EdgeInsets.only(bottom: 14),
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: _isDark
                                    ? const [
                                        Color(0xFF23233A),
                                        Color(0xFF171726),
                                      ]
                                    : [
                                        Colors.white,
                                        _accent.withValues(alpha: 0.05),
                                      ],
                              ),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: _accent.withValues(alpha: 0.10),
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: _accent.withValues(
                                        alpha: _isDark ? 0.20 : 0.12),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Icon(
                                    Icons.password_rounded,
                                    color: _accent,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Private vault',
                                        style: TextStyle(
                                          color: _textPrimary,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          _buildInfoChip(
                                            icon: Icons.inventory_2_rounded,
                                            label:
                                                '${entries.length} total entr${entries.length == 1 ? 'y' : 'ies'}',
                                          ),
                                          if (_searchQuery.isNotEmpty)
                                            _buildInfoChip(
                                              icon: Icons.filter_alt_rounded,
                                              label:
                                                  '${filteredEntries.length} shown',
                                              color: const Color(0xFF2563EB),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        _canImportPasswords
                                            ? 'Reveal and copy actions still ask for unlock again. Desktop can import CSV and JSON exports into this encrypted vault.'
                                            : 'Reveal and copy actions still ask for unlock again. Password import is desktop-only for now while the phone flow stays disabled.',
                                        style: TextStyle(
                                          color: _textSecondary,
                                          height: 1.45,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (!_canImportPasswords)
                            Container(
                              margin: const EdgeInsets.only(bottom: 14),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Colors.orange
                                    .withValues(alpha: _isDark ? 0.16 : 0.10),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: Colors.orange.withValues(alpha: 0.18),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.desktop_windows_rounded,
                                    color: Colors.orange,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'CSV and JSON password import is available on desktop only right now.',
                                      style: TextStyle(
                                        color: _textPrimary,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          TextField(
                            controller: _searchController,
                            decoration: InputDecoration(
                              hintText: 'Search passwords, usernames, or sites',
                              prefixIcon: const Icon(Icons.search_rounded),
                              suffixIcon: _searchQuery.isEmpty
                                  ? null
                                  : IconButton(
                                      onPressed: () =>
                                          _searchController.clear(),
                                      icon: const Icon(Icons.close_rounded),
                                    ),
                              filled: true,
                              fillColor: _cardColor,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide(
                                  color: _accent.withValues(alpha: 0.10),
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide(
                                  color: _accent.withValues(alpha: 0.10),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide(
                                  color: _accent,
                                  width: 1.4,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (filteredEntries.isEmpty)
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: _cardColor,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Text(
                                'No password entries match "$_searchQuery".',
                                style: TextStyle(
                                  color: _textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          for (final entry in filteredEntries)
                            _buildEntryCard(
                              entry,
                              selectionMode: _isSelectionMode,
                              isSelected: _selectedEntryIds.contains(entry.id),
                            ),
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
