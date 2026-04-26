import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import '../models/otp_account.dart';
import '../providers/auth_provider.dart';
import '../services/otp_service.dart';
import '../services/sync_service.dart';
import '../services/profile_service.dart';
import '../services/secure_storage_service.dart';
import '../providers/theme_provider.dart';
import 'add_account_screen.dart';
import 'settings_screen.dart';
import 'login_screen.dart';
import 'show_qr_screen.dart';
import 'profile_screen.dart';
import '../config/app_config.dart';
import '../widgets/account_logo_badge.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final OTPService _otpService = OTPService();
  final SyncService _syncService = SyncService();
  final ProfileService _profileService = ProfileService();

  Map<String, String> currentOTPs = {};
  Map<String, int> timers = {};
  Map<String, bool> blurredCodes = {};
  late AnimationController _animationController;
  String _searchQuery = '';
  bool _isSyncing = false;
  bool _allBlurred = false;
  String? _profilePhotoUrl;
  String? _username;
  Box<OTPAccount>? _userBox;
  bool _isLoadingVault = true;
  String? _loadError;

  // Track sync status for warning messages
  bool _isSyncEnabled = true;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _animationController.forward();
    _loadData();
    _loadSyncStatus();
  }

  Future<void> _loadSyncStatus() async {
    _isSyncEnabled = await _syncService.isSyncEnabled();
    setState(() {});
  }

  Future<void> _loadData() async {
    try {
      await _syncService.migrateLegacyLocalAccounts();
      await _initUserBox();
      await _loadProfileData();
      if (await _syncService.isSyncEnabled()) {
        await _syncService.downloadAndMergeAccounts();
        await _initUserBox();
      }
      _startTimer();
      _updateAllOTPs();
      if (mounted) {
        setState(() {
          _isLoadingVault = false;
          _loadError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingVault = false;
          _loadError = 'Failed to load your saved codes.';
        });
      }
    }
  }

  Future<void> _initUserBox() async {
    _userBox = await _syncService.getUserBox();
    print(
        'User box: ${await _syncService.getCurrentUserBoxName()} has ${_userBox?.length ?? 0} accounts');
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadProfileData() async {
    final username =
        await SecureStorageService().read(SecureStorageService.currentUserKey);
    if (mounted)
      setState(() => _username = username ?? 'User');
    final profile = await _profileService.getProfile();
    if (profile != null && mounted) {
      setState(() => _profilePhotoUrl = profile['profile']?['profile_photo']);
    }
  }

  void _startTimer() {
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        _updateAllOTPs();
        _startTimer();
      }
    });
  }

  void _updateAllOTPs() async {
    if (_userBox == null) return;
    final newOTPs = <String, String>{};
    final newTimers = <String, int>{};

    for (var account in _userBox!.values) {
      newOTPs[account.id] = await _otpService.generateOTP(account.secret);
      newTimers[account.id] = _otpService.secondsRemaining();
      blurredCodes.putIfAbsent(account.id, () => false);
    }

    if (mounted) {
      setState(() {
        currentOTPs = newOTPs;
        timers = newTimers;
      });
    }
  }

  void _toggleBlurAll() {
    setState(() {
      _allBlurred = !_allBlurred;
      for (var key in blurredCodes.keys) {
        blurredCodes[key] = _allBlurred;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accountCount = _userBox?.length ?? 0;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0F0F1A) : const Color(0xFFF0F2FF),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Check if it's a wide screen (laptop/desktop)
          final isWideScreen = constraints.maxWidth > 600;

          return Column(
            children: [
              _buildHeader(isDark, accountCount, isWideScreen),
              _buildSearchBar(isDark, isWideScreen),
              Expanded(child: _buildAccountsList(isDark)),
            ],
          );
        },
      ),
    );
  }

  // â”€â”€â”€ Header with account count - FIXED for desktop right alignment â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildHeader(bool isDark, int accountCount, bool isWideScreen) {
    final actionButtons = Wrap(
      spacing: isWideScreen ? 4 : 6,
      runSpacing: 6,
      children: [
        _headerAction(
            _allBlurred
                ? Icons.visibility_rounded
                : Icons.visibility_off_rounded,
            _toggleBlurAll,
            tooltip: _allBlurred ? 'Show codes' : 'Hide codes'),
        _headerAction(Icons.sync_rounded, _syncData,
            tooltip: 'Sync', loading: _isSyncing),
        _headerAction(
            Icons.settings_rounded,
            () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => SettingsScreen())),
            tooltip: 'Settings'),
        _headerAction(
            isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
            () => Provider.of<ThemeProvider>(context, listen: false)
                .toggleTheme(),
            tooltip: 'Theme'),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A2E) : const Color(0xFF4F46E5),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 12,
              offset: const Offset(0, 4))
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            children: [
              Row(
                children: [
                  GestureDetector(
                    onTap: () async {
                      final result = await Navigator.push(context,
                          MaterialPageRoute(builder: (_) => ProfileScreen()));
                      if (result == true) _loadProfileData();
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.white.withOpacity(0.3), width: 2),
                      ),
                      child: ClipOval(
                        child: _profilePhotoUrl != null &&
                                _profilePhotoUrl!.isNotEmpty
                            ? Image.network(
                                '${AppConfig.mediaUrl}${_profilePhotoUrl!.replaceFirst('/media/', '')}',
                                fit: BoxFit.cover,
                                width: 40,
                                height: 40,
                                errorBuilder: (_, __, ___) => Container(
                                  color: Colors.white.withOpacity(0.2),
                                  child: const Icon(Icons.person,
                                      color: Colors.white, size: 20),
                                ),
                              )
                            : Container(
                                color: Colors.white.withOpacity(0.2),
                                child: const Icon(Icons.person,
                                    color: Colors.white, size: 20),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('BeatzLock',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                letterSpacing: 0.3)),
                        Row(
                          children: [
                            Flexible(
                              child: Text(_username ?? 'Two-Factor Security',
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.white60),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '$accountCount',
                                style: const TextStyle(
                                    fontSize: 9,
                                    color: Colors.white70,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (isWideScreen) actionButtons,
                ],
              ),
              if (!isWideScreen) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: actionButtons,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerAction(IconData icon, VoidCallback onTap,
      {String? tooltip, bool loading = false}) {
    return Tooltip(
      message: tooltip ?? '',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 36,
          height: 36,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: loading
              ? const Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Icon(icon, color: Colors.white, size: 18),
        ),
      ),
    );
  }

  // â”€â”€â”€ Search bar with responsive width â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildSearchBar(bool isDark, bool isWideScreen) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      constraints: BoxConstraints(
        maxWidth: isWideScreen ? 600 : double.infinity,
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E32) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 2))
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      style: TextStyle(
                          color:
                              isDark ? Colors.white : const Color(0xFF1A1A2E),
                          fontSize: 14),
                      onChanged: (v) =>
                          setState(() => _searchQuery = v.toLowerCase()),
                      decoration: InputDecoration(
                        hintText: 'Search accounts',
                        hintStyle: TextStyle(
                            color: isDark ? Colors.white38 : Colors.grey[400],
                            fontSize: 14),
                        prefixIcon: Icon(Icons.search_rounded,
                            color: isDark ? Colors.white38 : Colors.grey[400],
                            size: 20),
                        border: InputBorder.none,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () async {
                      final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => AddAccountScreen()));
                      if (result == true) {
                        await _initUserBox();
                        _updateAllOTPs();
                      }
                    },
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                          color: const Color(0xFF4F46E5),
                          borderRadius: BorderRadius.circular(10)),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_rounded,
                              color: Colors.white, size: 18),
                          SizedBox(width: 4),
                          Text('Add',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // â”€â”€â”€ Accounts list with creation date â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildAccountsList(bool isDark) {
    if (_isLoadingVault) {
      return const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4F46E5)),
        ),
      );
    }

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 44,
                color: isDark ? Colors.white70 : const Color(0xFF4F46E5),
              ),
              const SizedBox(height: 12),
              Text(
                _loadError!,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF1A1A2E),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Try reloading your vault.',
                style: TextStyle(
                  color: isDark ? Colors.white54 : Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _isLoadingVault = true;
                    _loadError = null;
                  });
                  _loadData();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_userBox == null) {
      return const SizedBox.shrink();
    }

    var accounts = _userBox!.values.toList();
    // Sort by creation date (newest first)
    accounts.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (_searchQuery.isNotEmpty) {
      accounts = accounts
          .where((a) =>
              a.service.toLowerCase().contains(_searchQuery) ||
              (a.accountLabel?.toLowerCase().contains(_searchQuery) ?? false) ||
              (a.issuer?.toLowerCase().contains(_searchQuery) ?? false))
          .toList();
    }

    if (accounts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E32) : Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.08), blurRadius: 20)
                ],
              ),
              child: const Icon(Icons.security_rounded,
                  size: 40, color: Color(0xFF4F46E5)),
            ),
            const SizedBox(height: 20),
            Text('No accounts yet',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : const Color(0xFF1A1A2E))),
            const SizedBox(height: 6),
            Text('Tap Add to get started',
                style: TextStyle(
                    color: isDark ? Colors.white38 : Colors.grey[500],
                    fontSize: 13)),
          ],
        ),
      );
    }

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 800),
        child: ScrollConfiguration(
          behavior: const MaterialScrollBehavior().copyWith(scrollbars: false),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: accounts.length,
            itemBuilder: (context, index) {
              final account = accounts[index];
              final otp = currentOTPs[account.id] ?? '------';
              final timer = timers[account.id] ?? 30;
              final isBlurred = blurredCodes[account.id] ?? false;
              final isExpiring = timer <= 5;
              final accountSubtitle = _accountSubtitle(account);

              // Format creation date
              final addedDate = _formatDate(account.createdAt);

              return AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E1E32) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isExpiring
                        ? Colors.red.withOpacity(0.4)
                        : (isDark
                            ? Colors.white.withOpacity(0.06)
                            : Colors.transparent),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(isDark ? 0.2 : 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 3))
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          AccountLogoBadge(
                            service: account.service,
                            issuer: account.issuer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(account.service,
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: isDark
                                            ? Colors.white
                                            : const Color(0xFF1A1A2E)),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                if (accountSubtitle != null)
                                  Text(accountSubtitle,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: isDark
                                              ? Colors.white38
                                              : Colors.grey[500]),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                // Added date
                                Row(
                                  children: [
                                    Icon(Icons.calendar_today,
                                        size: 10,
                                        color: isDark
                                            ? Colors.white38
                                            : Colors.grey[400]),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Added $addedDate',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: isDark
                                            ? Colors.white38
                                            : Colors.grey[400],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isExpiring
                                      ? Colors.red.withOpacity(0.1)
                                      : const Color(0xFF4F46E5)
                                          .withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    isBlurred ? '*** ***' : _formatOtp(otp),
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      color: isExpiring
                                          ? Colors.red
                                          : (isDark
                                              ? Colors.white
                                              : const Color(0xFF1A1A2E)),
                                      letterSpacing: 3,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text('${timer}s',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: isExpiring
                                          ? Colors.red
                                          : (isDark
                                              ? Colors.white38
                                              : Colors.grey[500]))),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: timer / 30,
                          backgroundColor:
                              isDark ? Colors.white10 : Colors.grey[100],
                          valueColor: AlwaysStoppedAnimation<Color>(isExpiring
                              ? Colors.red
                              : const Color(0xFF4F46E5)),
                          minHeight: 4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _accountAction(Icons.copy_rounded, 'Copy',
                              () => _copyToClipboard(otp), isDark),
                          _accountAction(
                            isBlurred
                                ? Icons.visibility_rounded
                                : Icons.visibility_off_rounded,
                            isBlurred ? 'Show' : 'Hide',
                            () => setState(
                                () => blurredCodes[account.id] = !isBlurred),
                            isDark,
                          ),
                          _accountAction(
                            Icons.edit_rounded,
                            'Edit',
                            () => _showEditTitleDialog(account),
                            isDark,
                          ),
                          _accountAction(
                            Icons.qr_code_rounded,
                            'QR',
                            () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => ShowQRScreen(
                                        secret: account.secret,
                                        service: account.service,
                                        issuer: account.issuer))),
                            isDark,
                          ),
                          _accountAction(
                            Icons.delete_outline_rounded,
                            'Delete',
                            () => _showDeleteAccountDialog(
                                account.id, account.service),
                            isDark,
                            destructive: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      return 'today';
    } else if (difference.inDays == 1) {
      return 'yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else if (difference.inDays < 30) {
      final weeks = (difference.inDays / 7).floor();
      return '$weeks ${weeks == 1 ? 'week' : 'weeks'} ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  String? _accountSubtitle(OTPAccount account) {
    final label = account.accountLabel?.trim();
    if (label != null && label.isNotEmpty) {
      return label;
    }

    final issuer = account.issuer?.trim();
    if (issuer != null && issuer.isNotEmpty) {
      return issuer;
    }

    return null;
  }

  // â”€â”€â”€ Delete account dialog with enhanced warnings â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  void _showDeleteAccountDialog(String accountId, String serviceName) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF1E1E32) : Colors.white;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A2E);
    final textSecondary = isDark ? Colors.white38 : Colors.grey.shade500;

    // First, show the choice dialog
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: cardColor,
        title: Row(children: [
          const Icon(Icons.delete_outline_rounded, color: Colors.red, size: 24),
          const SizedBox(width: 10),
          Text('Delete "$serviceName"',
              style: TextStyle(
                  color: textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.bold)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Where should this account be deleted?',
                style: TextStyle(color: textSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            _deleteOptionTile(
              icon: Icons.phone_android_rounded,
              title: 'This device only',
              subtitle: _isSyncEnabled
                  ? 'Cloud sync is ON. This account may come back when you sync!'
                  : 'Local only. Other devices keep the account.',
              color: Colors.orange,
              onTap: () => Navigator.pop(context, 'local'),
            ),
            const SizedBox(height: 8),
            _deleteOptionTile(
              icon: Icons.cloud_off_rounded,
              title: 'Everywhere (Permanent)',
              subtitle: 'Removed from all devices & cloud. Cannot be undone!',
              color: Colors.red,
              onTap: () => Navigator.pop(context, 'everywhere'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: Text('Cancel', style: TextStyle(color: textSecondary)),
          ),
        ],
      ),
    );

    if (choice == null || choice == 'cancel') return;

    if (choice == 'local') {
      // Show warning about sync if enabled
      if (_isSyncEnabled) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            backgroundColor: cardColor,
            title: Row(children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.orange, size: 24),
              const SizedBox(width: 10),
              Text('Sync Warning',
                  style: TextStyle(color: textPrimary, fontSize: 17)),
            ]),
            content: Text(
              'âš ï¸ Cloud sync is currently ENABLED.\n\n'
              'If you delete this account locally only, it may be restored from the cloud when you sync.\n\n'
              'To permanently delete this account, choose "Everywhere" instead.\n\n'
              'Are you sure you want to delete locally only?',
              style: TextStyle(color: textSecondary, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel', style: TextStyle(color: textSecondary)),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white),
                child: const Text('Delete Locally'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }

      await _syncService.deleteAccountLocalOnly(accountId);
      setState(() {
        currentOTPs.remove(accountId);
        timers.remove(accountId);
        blurredCodes.remove(accountId);
      });
      _showSnackBar('Account removed from this device only', Colors.orange);
    } else if (choice == 'everywhere') {
      // Show final confirmation with "DELETE" typing
      final confirmed = await _showDeleteConfirmationDialog(
          context, serviceName, cardColor, textPrimary, textSecondary);
      if (!confirmed) return;

      _showSnackBar('Deleting everywhereâ€¦', Colors.grey);
      final ok = await _syncService.deleteAccountEverywhere(accountId);
      if (ok) {
        setState(() {
          currentOTPs.remove(accountId);
          timers.remove(accountId);
          blurredCodes.remove(accountId);
        });
        _showSnackBar('Account deleted from all devices', Colors.red);
      } else {
        _showSnackBar('Failed to delete from cloud â€“ try again', Colors.red);
      }
    }
  }

  Future<bool> _showDeleteConfirmationDialog(
      BuildContext context,
      String serviceName,
      Color cardColor,
      Color textPrimary,
      Color textSecondary) async {
    final TextEditingController confirmController = TextEditingController();
    bool canDelete = false;

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              backgroundColor: cardColor,
              title: Row(children: [
                const Icon(Icons.warning_amber_rounded,
                    color: Colors.red, size: 28),
                const SizedBox(width: 10),
                Text('PERMANENT DELETION',
                    style: TextStyle(
                        color: Colors.red,
                        fontSize: 17,
                        fontWeight: FontWeight.bold)),
              ]),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This action is IRREVERSIBLE and will delete "$serviceName" from ALL your devices and the cloud.',
                    style: TextStyle(
                        color: textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.withOpacity(0.3)),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.warning, color: Colors.red, size: 32),
                        const SizedBox(height: 8),
                        Text(
                          'This cannot be undone!',
                          style: TextStyle(
                              color: Colors.red,
                              fontSize: 13,
                              fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Type "DELETE" below to confirm:',
                    style: TextStyle(color: textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: confirmController,
                    onChanged: (value) {
                      setState(() {
                        canDelete = value.toUpperCase() == 'DELETE';
                      });
                    },
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: canDelete ? Colors.red : textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Type DELETE here',
                      hintStyle: TextStyle(color: textSecondary, fontSize: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:
                            BorderSide(color: Colors.red.withOpacity(0.5)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:
                            const BorderSide(color: Colors.red, width: 2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    confirmController.dispose();
                    Navigator.pop(context, false);
                  },
                  child: Text('Cancel', style: TextStyle(color: textSecondary)),
                ),
                ElevatedButton(
                  onPressed: canDelete
                      ? () {
                          confirmController.dispose();
                          Navigator.pop(context, true);
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Delete Forever'),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  Widget _deleteOptionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: color)),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11, color: color.withOpacity(0.7))),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: color.withOpacity(0.5), size: 18),
          ],
        ),
      ),
    );
  }

  // â”€â”€â”€ Helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  String _formatOtp(String otp) {
    if (otp.length == 6) return '${otp.substring(0, 3)} ${otp.substring(3)}';
    return otp;
  }

  Widget _accountAction(
      IconData icon, String label, VoidCallback onTap, bool isDark,
      {bool destructive = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: destructive
              ? Colors.red.withOpacity(0.08)
              : (isDark ? Colors.white.withOpacity(0.06) : Colors.grey[50]),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: destructive
                ? Colors.red.withOpacity(0.2)
                : (isDark ? Colors.white12 : Colors.grey[200]!),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 15,
                color: destructive
                    ? Colors.red
                    : (isDark ? Colors.white60 : Colors.grey[600])),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: destructive
                        ? Colors.red
                        : (isDark ? Colors.white60 : Colors.grey[600]))),
          ],
        ),
      ),
    );
  }

  Future<void> _showEditTitleDialog(OTPAccount account) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final controller = TextEditingController(text: account.service);

    final updatedTitle = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: isDark ? const Color(0xFF1E1E32) : Colors.white,
        title: const Text('Edit Account Title'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Title',
            hintText: 'Enter account title',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    controller.dispose();

    if (updatedTitle == null || updatedTitle.isEmpty) return;
    if (updatedTitle == account.service) return;

    await _saveAccountTitle(account, updatedTitle);
  }

  Future<void> _saveAccountTitle(OTPAccount account, String title) async {
    if (_userBox == null) return;

    account.service = title;
    await _userBox!.put(account.id, account);

    if (!mounted) return;
    setState(() {});

    final syncEnabled = await _syncService.isSyncEnabled();
    if (syncEnabled) {
      final synced =
          await _syncService.syncAccounts(preferLocalTitleChanges: true);
      if (!mounted) return;
      _showSnackBar(
        synced
            ? 'Account title updated'
            : 'Title updated locally. Cloud sync pending.',
        synced ? const Color(0xFF10B981) : Colors.orange,
      );
      return;
    }

    _showSnackBar('Account title updated', const Color(0xFF10B981));
  }

  void _copyToClipboard(String otp) async {
    await Clipboard.setData(ClipboardData(text: otp.replaceAll(' ', '')));
    _showSnackBar('Copied to clipboard', const Color(0xFF10B981));
  }

  void _syncData() async {
    final syncEnabled = await _syncService.isSyncEnabled();

    if (!syncEnabled) {
      _showSnackBar('Sync is disabled. Enable it in Settings â†’ Sync to Cloud',
          Colors.orange);
      return;
    }

    setState(() => _isSyncing = true);
    try {
      final success = await _syncService.syncAccounts();
      if (!mounted) return;
      setState(() => _isSyncing = false);
      if (success) {
        await _initUserBox();
        _updateAllOTPs();
        _showSnackBar('Sync completed!', Colors.green);
      } else {
        _showSnackBar(
            _syncService.lastErrorMessage ??
                'No internet or server unavailable',
            Colors.orange);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSyncing = false);
      _showSnackBar('Sync failed', Colors.red);
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(
            color == Colors.green || color == const Color(0xFF10B981)
                ? Icons.check_circle_rounded
                : Icons.info_rounded,
            color: Colors.white,
            size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ]),
      backgroundColor: color,
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Logout'),
        content: const Text('Your codes will remain saved on this device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4F46E5),
                foregroundColor: Colors.white),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await Provider.of<AuthProvider>(context, listen: false).logout();
      await _syncService.logout();
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => LoginScreen()));
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }
}
