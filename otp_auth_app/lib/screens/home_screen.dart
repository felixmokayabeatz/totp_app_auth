import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device_session_info.dart';
import '../models/otp_account.dart';
import '../providers/auth_provider.dart';
import '../services/otp_service.dart';
import '../services/sync_service.dart';
import '../services/profile_service.dart';
import '../services/secure_storage_service.dart';
import '../services/encryption_service.dart';
import '../services/app_lock_service.dart';
import '../services/otp_vault_snapshot_service.dart';
import '../providers/theme_provider.dart';
import 'add_account_screen.dart';
import 'settings_screen.dart';
import 'login_screen.dart';
import 'notifications_screen.dart';
import 'passwordless_requests_screen.dart';
import 'passwords_screen.dart';
import 'show_qr_screen.dart';
import 'profile_screen.dart';
import '../config/app_config.dart';
import '../widgets/account_logo_badge.dart';
import '../services/approval_notification_service.dart';
import '../services/background_passwordless_poll_service.dart';
import '../services/push_messaging_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  static const _offlineBackupReminderKey = 'offline_backup_reminder_last_shown';
  static const Duration _approvalPollInterval = Duration(seconds: 8);
  static const Duration _approvalDialogRefreshInterval = Duration(seconds: 2);

  final OTPService _otpService = OTPService();
  final SyncService _syncService = SyncService();
  final ProfileService _profileService = ProfileService();
  final AppLockService _appLockService = AppLockService();
  final ApprovalNotificationService _approvalNotificationService =
      ApprovalNotificationService();
  final OtpVaultSnapshotService _vaultSnapshotService =
      OtpVaultSnapshotService();

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
  int _unreadNotificationCount = 0;
  bool _offlineBackupReminderVisible = false;
  bool _canShowPasswordlessPrompt = false;
  bool _canShowBulkDeletePrompt = false;
  bool _isShowingApprovalPrompt = false;
  bool _isShowingBackupCodeRequirementDialog = false;
  bool _approvalPollInProgress = false;
  bool _openingPasswordlessRequestsFromNotification = false;
  Timer? _passwordlessPollTimer;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _accentSecondary => Theme.of(context).colorScheme.secondary;

  // Track sync status for warning messages
  bool _isSyncEnabled = false;

  @override
  void initState() {
    super.initState();
    _approvalNotificationService.passwordlessOpenSignal
        .addListener(_handlePasswordlessNotificationSignal);
    _approvalNotificationService.passwordlessRequestSignal
        .addListener(_handleForegroundPasswordlessRequestSignal);
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _animationController.forward();
    _loadData();
    _loadSyncStatus();
    _initializePasswordlessApprovals();
    unawaited(PushMessagingService().syncCurrentPushTokenIfPossible());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeOpenPasswordlessRequestsFromNotification());
    });
  }

  Future<void> _loadSyncStatus() async {
    _isSyncEnabled = await _syncService.isSyncEnabled();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadData() async {
    try {
      final isSignedIn = await _syncService.isLoggedIn();
      final syncEnabled = isSignedIn && await _syncService.isSyncEnabled();
      await _syncService.migrateLegacyLocalAccounts();
      await _initUserBox();
      await _loadProfileData();
      _startTimer();
      _updateAllOTPs();
      if (mounted) {
        setState(() {
          _isLoadingVault = false;
          _loadError = null;
        });
      }
      unawaited(
        _finishLoadingAfterInitialRender(
          isSignedIn: isSignedIn,
          syncEnabled: syncEnabled,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingVault = false;
          _loadError = 'Failed to load your saved codes.';
        });
      }
    }
  }

  Future<void> _finishLoadingAfterInitialRender({
    required bool isSignedIn,
    required bool syncEnabled,
  }) async {
    try {
      if (isSignedIn && syncEnabled) {
        await _syncService.downloadAndMergeAccounts();
        await _initUserBox();
        _updateAllOTPs();
        if (mounted) {
          setState(() {});
        }
      }

      await _vaultSnapshotService.captureDailySnapshotIfNeeded();
      await _loadUnreadNotificationCount();
      await _showOfflineBackupReminderIfNeeded();
      await _checkBackupCodeRequirement();
    } catch (_) {}
  }

  Future<void> _showOfflineBackupReminderIfNeeded() async {
    if (!mounted || await _syncService.isLoggedIn()) return;
    if ((_userBox?.isEmpty ?? true)) return;
    if (_offlineBackupReminderVisible) return;

    final prefs = await SharedPreferences.getInstance();
    final lastShownMs = prefs.getInt(_offlineBackupReminderKey) ?? 0;
    final lastShown = DateTime.fromMillisecondsSinceEpoch(lastShownMs);
    if (DateTime.now().difference(lastShown) < const Duration(hours: 24)) {
      return;
    }

    await prefs.setInt(
      _offlineBackupReminderKey,
      DateTime.now().millisecondsSinceEpoch,
    );
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      _offlineBackupReminderVisible = true;
      messenger
          .showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Your codes are saved on this device. Sign in anytime to back them up and sync across devices.',
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () {
                      messenger.hideCurrentSnackBar();
                      _openLoginForSync();
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Sign in',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              backgroundColor: _accent,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 5),
            ),
          )
          .closed
          .whenComplete(() {
        _offlineBackupReminderVisible = false;
      });
    });
  }

  Future<void> _loadUnreadNotificationCount() async {
    if (!await _syncService.isLoggedIn()) {
      if (mounted) {
        setState(() => _unreadNotificationCount = 0);
      }
      return;
    }

    final notifications = await _syncService.getNotifications();
    if (!mounted) return;

    setState(() {
      _unreadNotificationCount =
          notifications.where((item) => !item.isRead).length;
    });
  }

  Future<void> _initializePasswordlessApprovals() async {
    await _refreshPasswordlessApprovalCapability();
    _passwordlessPollTimer?.cancel();
    if (!_canShowPasswordlessPrompt && !_canShowBulkDeletePrompt) {
      await _approvalNotificationService
          .clearPasswordlessApprovalNotification();
      return;
    }

    _passwordlessPollTimer = Timer.periodic(
      _approvalPollInterval,
      (_) => unawaited(_pollPrimaryApprovalRequests()),
    );
    await _pollPrimaryApprovalRequests();
  }

  Future<void> _refreshPasswordlessApprovalCapability() async {
    if (!mounted || !await _syncService.isLoggedIn()) {
      await BackgroundPasswordlessPollService()
          .syncRegistration(enabled: false);
      if (mounted) {
        setState(() {
          _canShowPasswordlessPrompt = false;
          _canShowBulkDeletePrompt = false;
        });
      }
      return;
    }

    final sessions = await _syncService.getActiveDeviceSessions();
    if (!mounted) return;
    final currentSession = sessions.cast<DeviceSessionInfo?>().firstWhere(
          (session) => session?.isCurrent == true,
          orElse: () => null,
        );
    final canShowBulkDelete =
        currentSession != null && currentSession.isPrimary;
    final canShowPasswordless = canShowBulkDelete &&
        (Platform.isAndroid || Platform.isIOS) &&
        currentSession.deviceKind == 'mobile';

    await BackgroundPasswordlessPollService().syncRegistration(
      enabled: canShowPasswordless,
    );

    setState(() {
      _canShowPasswordlessPrompt = canShowPasswordless;
      _canShowBulkDeletePrompt = canShowBulkDelete;
    });
  }

  Future<void> _pollPrimaryApprovalRequests() async {
    if (_approvalPollInProgress) {
      return;
    }

    _approvalPollInProgress = true;
    try {
      await _pollPasswordlessApprovalRequests();
      await _pollBulkDeleteApprovalRequests();
      await _pollBackupCodeGenerationRequests();
      await _maybeOpenPasswordlessRequestsFromNotification();
    } finally {
      _approvalPollInProgress = false;
    }
  }

  Future<void> _pollPasswordlessApprovalRequests() async {
    if (!mounted || !_canShowPasswordlessPrompt) {
      return;
    }

    final requests = await _syncService.getPasswordlessRequests();
    if (!mounted) return;
    if (requests.isEmpty) {
      await _approvalNotificationService
          .clearPasswordlessApprovalNotification();
      return;
    }

    Map<String, dynamic>? pendingRequest;
    for (final item in requests) {
      if ((item['status']?.toString() ?? '').toLowerCase() == 'pending') {
        pendingRequest = item;
        break;
      }
    }

    if (pendingRequest == null) {
      await _approvalNotificationService
          .clearPasswordlessApprovalNotification();
      return;
    }

    await _approvalNotificationService.clearPasswordlessApprovalNotification();

    if (_isShowingApprovalPrompt ||
        _openingPasswordlessRequestsFromNotification ||
        _approvalNotificationService.hasPendingPasswordlessOpenIntent) {
      return;
    }

    _isShowingApprovalPrompt = true;
    try {
      await _showPasswordlessPrompt(pendingRequest);
    } finally {
      _isShowingApprovalPrompt = false;
    }
  }

  void _handlePasswordlessNotificationSignal() {
    unawaited(_maybeOpenPasswordlessRequestsFromNotification());
  }

  void _handleForegroundPasswordlessRequestSignal() {
    unawaited(_pollPrimaryApprovalRequests());
  }

  Future<void> _maybeOpenPasswordlessRequestsFromNotification() async {
    if (!mounted ||
        _isShowingApprovalPrompt ||
        _openingPasswordlessRequestsFromNotification) {
      return;
    }
    if (!_approvalNotificationService.takePendingPasswordlessOpenIntent()) {
      return;
    }
    if (!await _syncService.isLoggedIn()) {
      return;
    }
    if (!mounted) {
      return;
    }

    _openingPasswordlessRequestsFromNotification = true;
    try {
      final result = await Navigator.push<String?>(
        context,
        MaterialPageRoute(
          builder: (_) => const PasswordlessRequestsScreen(
            closeOnSuccessfulApproval: true,
          ),
        ),
      );
      if (!mounted) return;
      if (result != null && result.trim().isNotEmpty) {
        _showSnackBar(result, const Color(0xFF10B981));
      }
      await _refreshPasswordlessApprovalCapability();
      await _loadUnreadNotificationCount();
    } finally {
      _openingPasswordlessRequestsFromNotification = false;
    }
  }

  Future<void> _pollBulkDeleteApprovalRequests() async {
    if (!mounted || !_canShowBulkDeletePrompt || _isShowingApprovalPrompt) {
      return;
    }

    final requests = await _syncService.getBulkDeleteRequests();
    if (!mounted || requests.isEmpty) return;

    Map<String, dynamic>? pendingRequest;
    for (final item in requests) {
      if ((item['status']?.toString() ?? '').toLowerCase() == 'pending') {
        pendingRequest = item;
        break;
      }
    }

    if (pendingRequest == null) {
      return;
    }

    _isShowingApprovalPrompt = true;
    try {
      await _showBulkDeleteApprovalPrompt(pendingRequest);
    } finally {
      _isShowingApprovalPrompt = false;
    }
  }

  Future<void> _pollBackupCodeGenerationRequests() async {
    if (!mounted || !_canShowBulkDeletePrompt || _isShowingApprovalPrompt) {
      return;
    }

    final requests = await _syncService.getBackupCodeGenerationRequests();
    if (!mounted || requests.isEmpty) return;

    Map<String, dynamic>? pendingRequest;
    for (final item in requests) {
      if ((item['status']?.toString() ?? '').toLowerCase() == 'pending') {
        pendingRequest = item;
        break;
      }
    }

    if (pendingRequest == null) {
      return;
    }

    _isShowingApprovalPrompt = true;
    try {
      await _showBackupCodeGenerationApprovalPrompt(pendingRequest);
    } finally {
      _isShowingApprovalPrompt = false;
    }
  }

  Future<void> _showPasswordlessPrompt(Map<String, dynamic> item) async {
    if (!mounted) return;

    final requestId = item['id']?.toString() ?? '';
    Map<String, dynamic> currentItem = Map<String, dynamic>.from(item);
    String label =
        currentItem['requester_device_label']?.toString() ?? 'Unknown device';
    List<String> choices =
        ((currentItem['verification_choices'] as List?) ?? const [])
            .map((choice) => choice.toString())
            .where((choice) => choice.trim().isNotEmpty)
            .toList();
    String? selectedCode;
    Timer? dialogRefreshTimer;
    BuildContext? activeDialogContext;
    StateSetter? dialogSetState;
    var dialogClosed = false;

    Future<void> refreshDialogData() async {
      if (!mounted || dialogClosed || requestId.isEmpty) {
        return;
      }

      final requests = await _syncService.getPasswordlessRequests();
      if (!mounted || dialogClosed) {
        return;
      }

      Map<String, dynamic>? refreshedItem;
      for (final request in requests) {
        if (request['id']?.toString() == requestId) {
          refreshedItem = Map<String, dynamic>.from(request);
          break;
        }
      }

      if (refreshedItem == null) {
        return;
      }

      final status =
          (refreshedItem['status']?.toString() ?? 'pending').toLowerCase();
      if (status != 'pending') {
        dialogRefreshTimer?.cancel();
        dialogClosed = true;
        final dialogContext = activeDialogContext;
        if (dialogContext != null && dialogContext.mounted) {
          Navigator.pop(dialogContext);
        }
        if (!mounted) return;
        _showSnackBar(
          status == 'expired'
              ? '$label sign-in request expired.'
              : '$label sign-in request is no longer pending.',
          Colors.orange,
        );
        return;
      }

      currentItem = refreshedItem;
      label = currentItem['requester_device_label']?.toString() ?? label;
      choices = ((currentItem['verification_choices'] as List?) ?? const [])
          .map((choice) => choice.toString())
          .where((choice) => choice.trim().isNotEmpty)
          .toList();
      if (selectedCode != null && !choices.contains(selectedCode)) {
        selectedCode = null;
      }
      dialogSetState?.call(() {});
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          activeDialogContext = dialogContext;
          dialogSetState = setDialogState;
          dialogRefreshTimer ??= Timer.periodic(
            _approvalDialogRefreshInterval,
            (_) => unawaited(refreshDialogData()),
          );
          final theme = Theme.of(dialogContext);
          final isDark = theme.brightness == Brightness.dark;
          final surfaceColor = isDark ? const Color(0xFF1E1E32) : Colors.white;
          final softAccent = _accent.withValues(alpha: isDark ? 0.18 : 0.08);
          final textPrimary =
              isDark ? Colors.white : theme.colorScheme.onSurface;

          Widget buildChoiceButton(String choice) {
            final isSelected = selectedCode == choice;
            return ElevatedButton(
              onPressed: () {
                setDialogState(() => selectedCode = choice);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: isSelected ? _accent : softAccent,
                foregroundColor: isSelected ? Colors.white : textPrimary,
                elevation: isSelected ? 1 : 0,
                side: BorderSide(
                  color: isSelected ? _accent : _accent.withValues(alpha: 0.28),
                  width: isSelected ? 2 : 1.4,
                ),
                minimumSize: const Size.fromHeight(72),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: Text(
                choice,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.6,
                  color: isSelected ? Colors.white : textPrimary,
                ),
              ),
            );
          }

          Widget buildChoiceRow() {
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                for (final choice in choices)
                  SizedBox(
                    width: 150,
                    child: buildChoiceButton(choice),
                  ),
              ],
            );
          }

          return AlertDialog(
            scrollable: true,
            backgroundColor: surfaceColor,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Passwordless sign-in request'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$label is asking to sign in.',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Choose the exact 3-digit code shown on $label, then tap Accept.',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                    height: 1.35,
                  ),
                ),
                if (choices.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  buildChoiceRow(),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  final success =
                      await _syncService.denyPasswordlessRequest(requestId);
                  if (!dialogContext.mounted) return;
                  dialogClosed = true;
                  Navigator.pop(dialogContext);
                  _showSnackBar(
                    success
                        ? 'Denied $label.'
                        : (_syncService.lastErrorMessage ??
                            'Could not deny that sign-in request.'),
                    success ? Colors.orange : Colors.red,
                  );
                },
                child: const Text('Deny'),
              ),
              FilledButton(
                onPressed: selectedCode == null
                    ? null
                    : () async {
                        final unlocked = await _appLockService
                            .authenticateToUnlock(dialogContext);
                        if (!dialogContext.mounted || !unlocked) return;
                        final success =
                            await _syncService.approvePasswordlessRequest(
                          requestId,
                          selectedCode: selectedCode!,
                        );
                        if (!dialogContext.mounted) return;
                        dialogClosed = true;
                        Navigator.pop(dialogContext);
                        _showSnackBar(
                          success
                              ? 'Approved $label.'
                              : (_syncService.lastErrorMessage ??
                                  'Could not approve that sign-in request.'),
                          success ? const Color(0xFF10B981) : Colors.red,
                        );
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Accept'),
              ),
            ],
          );
        },
      ),
    );
    dialogClosed = true;
    dialogRefreshTimer?.cancel();
  }

  Future<void> _showBulkDeleteApprovalPrompt(Map<String, dynamic> item) async {
    if (!mounted) return;

    final requestId = item['id']?.toString() ?? '';
    if (requestId.isEmpty) return;

    final label =
        item['requester_device_label']?.toString() ?? 'Unknown device';
    final requestedCount =
        int.tryParse(item['requested_count']?.toString() ?? '0') ?? 0;
    final startDate = DateTime.tryParse(
      item['range_start_date']?.toString() ?? '',
    );
    final endDate = DateTime.tryParse(
      item['range_end_date']?.toString() ?? '',
    );

    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Theme.of(dialogContext).brightness == Brightness.dark
            ? const Color(0xFF1E1E32)
            : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('OTP delete approval request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$label wants to delete '
              '$requestedCount OTP account${requestedCount == 1 ? '' : 's'} '
              'everywhere.',
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Date range: ${_formatAbsoluteDate(startDate ?? DateTime.now())} '
              'to ${_formatAbsoluteDate(endDate ?? DateTime.now())}',
              style: TextStyle(
                color: Theme.of(dialogContext)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.78),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Approve this only if you started the delete request yourself.',
              style: TextStyle(
                color: Theme.of(dialogContext)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.78),
                height: 1.35,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Deny'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );

    if (approved == null) return;
    if (!mounted) return;

    final unlocked = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !unlocked) return;

    if (!approved) {
      final denied = await _syncService.denyBulkDeleteRequest(requestId);
      if (!mounted) return;
      _showSnackBar(
        denied
            ? 'Denied delete request from $label.'
            : (_syncService.lastErrorMessage ??
                'Could not deny that delete request.'),
        denied ? Colors.orange : Colors.red,
      );
      return;
    }

    final deletedCount = await _syncService.approveBulkDeleteRequest(requestId);
    if (!mounted) return;
    if (deletedCount == null) {
      _showSnackBar(
        _syncService.lastErrorMessage ??
            'Could not approve that delete request.',
        Colors.red,
      );
      return;
    }

    await _syncService.downloadAndMergeAccounts();
    await _initUserBox();
    _updateAllOTPs();
    if (!mounted) return;
    setState(() {});
    _showSnackBar(
      'Approved and deleted $deletedCount OTP account${deletedCount == 1 ? '' : 's'} everywhere.',
      Colors.red,
    );
  }

  Future<void> _showBackupCodeGenerationApprovalPrompt(
    Map<String, dynamic> item,
  ) async {
    if (!mounted) return;

    final requestId = item['id']?.toString() ?? '';
    if (requestId.isEmpty) return;

    final label =
        item['requester_device_label']?.toString() ?? 'Unknown device';

    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Theme.of(dialogContext).brightness == Brightness.dark
            ? const Color(0xFF1E1E32)
            : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Recovery Codes PDF Approval'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$label wants this primary device to generate and save the Recovery Codes PDF.',
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Approve this only if you started the request. BeatzLock will generate the required Recovery Codes PDF and save it to this device Downloads folder.',
              style: TextStyle(
                color: Theme.of(dialogContext)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.78),
                height: 1.35,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Deny'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save PDF'),
          ),
        ],
      ),
    );

    if (approved == null) return;
    if (!mounted) return;

    final unlocked = await _appLockService.authenticateToUnlock(context);
    if (!mounted || !unlocked) return;

    if (!approved) {
      final denied =
          await _syncService.denyBackupCodeGenerationRequest(requestId);
      if (!mounted) return;
      _showSnackBar(
        denied
            ? 'Denied the Recovery Codes PDF request from $label.'
            : (_syncService.lastErrorMessage ??
                'Could not deny that Recovery Codes PDF request.'),
        denied ? Colors.orange : Colors.red,
      );
      return;
    }

    final savedPath = await _runWithBlockingProgress<String?>(
      message: 'Saving Recovery Codes PDF to Downloads...',
      action: () => _syncService.approveBackupCodeGenerationRequest(
        requestId,
        preferDarkTheme: Theme.of(context).brightness == Brightness.dark,
      ),
    );
    if (!mounted) return;
    if (savedPath == null) {
      _showSnackBar(
        _syncService.lastErrorMessage ??
            'Could not save the Recovery Codes PDF on this device.',
        Colors.red,
      );
      return;
    }

    await _loadUnreadNotificationCount();
    await _showBackupCodesSavedDialog(savedPath);
  }

  Future<void> _showBackupCodesSavedDialog(String savedPath) async {
    if (!mounted) return;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF1E1E32) : Colors.white;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A2E);
    final textSecondary =
        isDark ? Colors.white70 : theme.colorScheme.onSurfaceVariant;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: cardColor,
        title: Row(
          children: [
            Icon(Icons.picture_as_pdf_rounded, color: _accent),
            const SizedBox(width: 10),
            Text(
              'Recovery Codes PDF Saved',
              style: TextStyle(color: textPrimary),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your BeatzLock Recovery Codes PDF was saved successfully.',
              style: TextStyle(color: textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Text(
              savedPath,
              style: TextStyle(
                color: textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _checkBackupCodeRequirement() async {
    if (!mounted ||
        _isShowingApprovalPrompt ||
        _isShowingBackupCodeRequirementDialog) {
      return;
    }

    if (!await _syncService.isLoggedIn()) {
      return;
    }

    final status = await _syncService.getBackupCodeStatus();
    if (!mounted || status == null) return;
    if (status['has_codes'] == true) return;

    final isPrimary = status['is_primary_device'] == true;
    final hasPendingRequest = status['pending_request_exists'] == true;
    if (!isPrimary && hasPendingRequest) {
      return;
    }
    if (isPrimary) {
      final requests = await _syncService.getBackupCodeGenerationRequests();
      if (!mounted) return;
      final hasPendingPrimaryRequest = requests.any(
        (item) => (item['status']?.toString() ?? '').toLowerCase() == 'pending',
      );
      if (hasPendingPrimaryRequest) {
        return;
      }
    }
    final primaryLabel =
        (status['primary_device_label']?.toString().trim() ?? '').isEmpty
            ? 'your primary device'
            : status['primary_device_label'].toString().trim();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          _isShowingApprovalPrompt ||
          _isShowingBackupCodeRequirementDialog) {
        return;
      }

      _isShowingBackupCodeRequirementDialog = true;
      try {
        final action = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            final theme = Theme.of(dialogContext);
            final isDark = theme.brightness == Brightness.dark;
            final surfaceColor =
                isDark ? const Color(0xFF1E1E32) : Colors.white;
            final textColor = theme.colorScheme.onSurface;
            final mutedColor = theme.colorScheme.onSurfaceVariant;

            return PopScope(
              canPop: false,
              child: AlertDialog(
                backgroundColor: surfaceColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
                title: const Text('Recovery Codes PDF Required'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'You must save your Recovery Codes PDF and store it somewhere safe. It is required for account recovery if you ever lose access to your primary device.',
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isPrimary
                          ? 'This is your primary device, so you need to save the Recovery Codes PDF here before continuing.'
                          : hasPendingRequest
                              ? 'A Recovery Codes PDF request is already waiting on $primaryLabel.'
                              : '$primaryLabel is your primary device. Send a request there so it can generate and save the Recovery Codes PDF.',
                      style: TextStyle(
                        color: mutedColor,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
                actions: [
                  if (!isPrimary && !hasPendingRequest)
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, 'request'),
                      child: const Text('Send request'),
                    ),
                  if (isPrimary)
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, 'download'),
                      child: const Text('Save PDF now'),
                    ),
                ],
              ),
            );
          },
        );

        if (!mounted) return;

        if (action == 'download') {
          final unlocked = await _appLockService.authenticateToUnlock(context);
          if (!mounted || !unlocked) return;

          final savedPath = await _runWithBlockingProgress<String?>(
            message: 'Saving Recovery Codes PDF to Downloads...',
            action: () => _syncService.downloadBackupCodesPdf(
              preferDarkTheme: Theme.of(context).brightness == Brightness.dark,
            ),
          );
          if (!mounted) return;
          if (savedPath == null) {
            _showSnackBar(
              _syncService.lastErrorMessage ??
                  'Could not save the Recovery Codes PDF right now.',
              Colors.red,
            );
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _checkBackupCodeRequirement();
            });
            return;
          }

          await _loadUnreadNotificationCount();
          await _showBackupCodesSavedDialog(savedPath);
          return;
        }

        if (action == 'request') {
          final requestedPrimaryLabel =
              await _syncService.createBackupCodeGenerationRequest();
          if (!mounted) return;
          if (requestedPrimaryLabel == null) {
            _showSnackBar(
              _syncService.lastErrorMessage ??
                  'Could not send the Recovery Codes PDF request.',
              Colors.red,
            );
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _checkBackupCodeRequirement();
            });
            return;
          }

          _showSnackBar(
            'Sent a Recovery Codes PDF request to $requestedPrimaryLabel. Finish the save there to continue.',
            const Color(0xFF10B981),
          );
        }
      } finally {
        _isShowingBackupCodeRequirementDialog = false;
      }
    });
  }

  Future<void> _initUserBox() async {
    _userBox = await _syncService.getUserBox();
    debugPrint(
        'User box: ${await _syncService.getCurrentUserBoxName()} has ${_userBox?.length ?? 0} accounts');
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadProfileData() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final isSignedIn =
        authProvider.isAuthenticated && await _syncService.isLoggedIn();

    if (!isSignedIn) {
      if (mounted) {
        setState(() {
          _username = 'Offline vault';
          _profilePhotoUrl = null;
        });
      }
      return;
    }

    final storage = SecureStorageService();
    final username = await storage.read(SecureStorageService.currentUserKey);
    if (mounted) {
      setState(() => _username = username ?? 'Signed in');
    }
    if (username == null || username.isEmpty) {
      return;
    }

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
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
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
        if (!authProvider.isAuthenticated)
          _headerAction(
            Icons.login_rounded,
            _openLoginForSync,
            tooltip: 'Sign in to sync',
          ),
        _headerAction(Icons.sync_rounded, _syncData,
            tooltip: 'Sync', loading: _isSyncing),
        _headerAction(
          Icons.delete_sweep_rounded,
          _showBulkDeleteByDateDialog,
          tooltip: 'Delete OTP accounts by date',
        ),
        _headerAction(Icons.password_rounded, () async {
          final unlocked = await _appLockService.authenticateToUnlock(context);
          if (!mounted || !unlocked) return;
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PasswordsScreen()),
          );
        }, tooltip: 'Passwords'),
        _headerAction(
          Icons.notifications_none_rounded,
          () async {
            if (!authProvider.isAuthenticated) {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => LoginScreen()),
              );
              return;
            }
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const NotificationsScreen(),
              ),
            );
            await _loadUnreadNotificationCount();
          },
          tooltip: 'Notifications',
          badgeCount: _unreadNotificationCount,
        ),
        _headerAction(Icons.settings_rounded, () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => SettingsScreen()),
          );
          await _loadUnreadNotificationCount();
          await _initializePasswordlessApprovals();
          await _checkBackupCodeRequirement();
        }, tooltip: 'Settings'),
        _headerAction(
            isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
            () => Provider.of<ThemeProvider>(context, listen: false)
                .toggleTheme(
                    platformBrightness:
                        MediaQuery.platformBrightnessOf(context)),
            tooltip: 'Theme'),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(_accent, Colors.black, isDark ? 0.28 : 0.08)!,
            _accent,
            Color.lerp(_accentSecondary, _accent, 0.22)!,
          ],
        ),
        boxShadow: [
          BoxShadow(
              color: _accent.withValues(alpha: isDark ? 0.28 : 0.22),
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
                      if (!authProvider.isAuthenticated) {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => LoginScreen()),
                        );
                        return;
                      }
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
                            color: Colors.white.withValues(alpha: 0.3),
                            width: 2),
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
                                  color: Colors.white.withValues(alpha: 0.2),
                                  child: const Icon(Icons.person,
                                      color: Colors.white, size: 20),
                                ),
                              )
                            : Container(
                                color: Colors.white.withValues(alpha: 0.2),
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
                                color: Colors.white.withValues(alpha: 0.2),
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
      {String? tooltip, bool loading = false, int badgeCount = 0}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(icon, color: Colors.white, size: 18),
              ),
              if (!loading && badgeCount > 0)
                Positioned(
                  top: -4,
                  right: -4,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: isDark ? const Color(0xFF1A1A2E) : _accent,
                        width: 1.5,
                      ),
                    ),
                    constraints: const BoxConstraints(minWidth: 18),
                    child: Text(
                      badgeCount > 99 ? '99+' : '$badgeCount',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // â”€â”€â”€ Search bar with responsive width â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildSearchBar(bool isDark, bool isWideScreen) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      constraints: BoxConstraints(
        maxWidth: isWideScreen ? 760 : double.infinity,
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E32) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _accent.withValues(alpha: 0.16)),
                boxShadow: [
                  BoxShadow(
                      color: _accent.withValues(alpha: isDark ? 0.14 : 0.08),
                      blurRadius: 14,
                      offset: const Offset(0, 2))
                ],
              ),
              child: TextField(
                style: TextStyle(
                    color: isDark ? Colors.white : const Color(0xFF1A1A2E),
                    fontSize: 14),
                onChanged: (v) =>
                    setState(() => _searchQuery = v.toLowerCase()),
                decoration: InputDecoration(
                  hintText: 'Search accounts',
                  hintStyle: TextStyle(
                      color: isDark ? Colors.white38 : Colors.grey[400],
                      fontSize: 14),
                  prefixIcon: Icon(Icons.search_rounded,
                      color: _accent.withValues(alpha: isDark ? 0.82 : 0.66),
                      size: 20),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 13),
                ),
              ),
            ),
          ),
          if (Platform.isAndroid || Platform.isIOS) ...[
            const SizedBox(width: 10),
            Tooltip(
              message: 'Scan QR code',
              child: InkWell(
                onTap: () => _openAddAccount(startScanning: true),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E1E32) : Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _accent.withValues(alpha: 0.22)),
                    boxShadow: [
                      BoxShadow(
                        color: _accent.withValues(alpha: isDark ? 0.14 : 0.08),
                        blurRadius: 14,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.qr_code_scanner_rounded,
                    color: _accent,
                    size: 21,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 10),
          Tooltip(
            message: 'Add account',
            child: InkWell(
              onTap: _openAddAccount,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                height: 48,
                padding: EdgeInsets.symmetric(
                  horizontal: isWideScreen ? 18 : 14,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      _accent,
                      Color.lerp(_accentSecondary, _accent, 0.18)!,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: _accent.withValues(alpha: 0.24),
                      blurRadius: 16,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.add_rounded,
                        color: Colors.white, size: 20),
                    if (isWideScreen) ...[
                      const SizedBox(width: 6),
                      const Text('Add',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openAddAccount({bool startScanning = false}) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => AddAccountScreen(startScanning: startScanning)),
    );
    if (result == true) {
      await _initUserBox();
      _updateAllOTPs();
      await _loadUnreadNotificationCount();
      await _showOfflineBackupReminderIfNeeded();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Success. Account added.'),
          backgroundColor: const Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  // â”€â”€â”€ Accounts list with creation date â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildAccountsList(bool isDark) {
    if (_isLoadingVault) {
      return Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(_accent),
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
                color: isDark ? Colors.white70 : _accent,
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
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 20)
                ],
              ),
              child: Icon(Icons.security_rounded, size: 40, color: _accent),
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
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isDark
                        ? [
                            const Color(0xFF1E1E32),
                            Color.lerp(const Color(0xFF1E1E32), _accent, 0.06)!,
                          ]
                        : [
                            Colors.white,
                            Color.lerp(Colors.white, _accent, 0.035)!,
                          ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isExpiring
                        ? Colors.red.withValues(alpha: 0.4)
                        : _accent.withValues(alpha: isDark ? 0.18 : 0.10),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: (isDark ? Colors.black : _accent)
                            .withValues(alpha: isDark ? 0.22 : 0.07),
                        blurRadius: 16,
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
                                      ? Colors.red.withValues(alpha: 0.1)
                                      : _accent.withValues(
                                          alpha: isDark ? 0.18 : 0.10,
                                        ),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isExpiring
                                        ? Colors.red.withValues(alpha: 0.16)
                                        : _accent.withValues(alpha: 0.14),
                                  ),
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
                              _accent.withValues(alpha: isDark ? 0.14 : 0.10),
                          valueColor: AlwaysStoppedAnimation<Color>(
                              isExpiring ? Colors.red : _accent),
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
                            () => _openQrForAccount(account),
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

  Future<void> _openQrForAccount(OTPAccount account) async {
    final userId = await _otpService.getCurrentUserId();
    final base32Secret = _readBase32Secret(account, userId);

    if (base32Secret == null) {
      _showSnackBar(
        'Could not unlock the Base32 secret for this account.',
        Colors.red,
      );
      return;
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ShowQRScreen(
          secret: base32Secret,
          advancedSecret: account.secret,
          service: account.service,
          issuer: account.issuer,
          accountLabel: account.accountLabel,
        ),
      ),
    );
  }

  String? _readBase32Secret(OTPAccount account, String userId) {
    final storedSecret = account.secret;

    try {
      final decrypted = EncryptionService.decryptSecret(storedSecret, userId);
      final cleanDecrypted = _cleanBase32Secret(decrypted);
      if (_isBase32Secret(cleanDecrypted)) {
        return cleanDecrypted;
      }
    } catch (_) {}

    final cleanStored = _cleanBase32Secret(storedSecret);
    if (_isBase32Secret(cleanStored)) {
      return cleanStored;
    }

    final cleanCached = _cleanBase32Secret(account.getSecret(userId));
    if (_isBase32Secret(cleanCached)) {
      return cleanCached;
    }

    return null;
  }

  String _cleanBase32Secret(String value) {
    return value
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('=', '')
        .toUpperCase();
  }

  bool _isBase32Secret(String value) {
    return value.isNotEmpty && RegExp(r'^[A-Z2-7]+$').hasMatch(value);
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

  DateTime _dateOnly(DateTime value) {
    final local = value.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  String _formatAbsoluteDate(DateTime date) {
    final local = date.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }

  List<OTPAccount> _accountsInDateRange(
    DateTime startDate,
    DateTime endDate,
  ) {
    final box = _userBox;
    if (box == null) return const [];

    final start = _dateOnly(startDate);
    final end = _dateOnly(endDate);
    return box.values.where((account) {
      final created = _dateOnly(account.createdAt);
      return !created.isBefore(start) && !created.isAfter(end);
    }).toList();
  }

  Future<DeviceSessionInfo?> _currentSessionInfo() async {
    final sessions = await _syncService.getActiveDeviceSessions();
    for (final session in sessions) {
      if (session.isCurrent) {
        return session;
      }
    }
    return null;
  }

  Future<bool> _confirmBulkDeleteEverywhereWithOtp({
    required int count,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final username = await SecureStorageService()
            .read(SecureStorageService.currentUserKey) ??
        '';
    if (username.isEmpty) {
      _showSnackBar('Sign in first to verify this cloud deletion.', Colors.red);
      return false;
    }

    final otpSent = await _syncService.sendDeleteOtp(username);
    if (!mounted) return false;
    if (!otpSent) {
      _showSnackBar(
        _syncService.lastErrorMessage ??
            'Failed to send the verification code.',
        Colors.red,
      );
      return false;
    }

    var otpCode = '';
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: Theme.of(dialogContext).brightness == Brightness.dark
              ? const Color(0xFF1E1E32)
              : Colors.white,
          title: const Text('Confirm OTP deletion'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.email_outlined, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(
                'A 6-digit code was sent to your email. Enter it to delete '
                '$count OTP account${count == 1 ? '' : 's'} everywhere for '
                '${_formatAbsoluteDate(startDate)} to ${_formatAbsoluteDate(endDate)}.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 18),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(dialogContext).brightness == Brightness.dark
                      ? Colors.white12
                      : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                ),
                child: TextField(
                  onChanged: (value) {
                    setDialogState(() => otpCode = value);
                  },
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 24,
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                  ),
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    hintText: '000000',
                    hintStyle: TextStyle(fontSize: 18, letterSpacing: 2),
                    border: InputBorder.none,
                    counterText: '',
                    contentPadding: EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final code = otpCode.trim();
                if (code.length != 6) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(
                      content: Text('Enter the 6-digit code.'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  return;
                }
                final ok = await _syncService.verifyDeleteOtp(username, code);
                if (!dialogContext.mounted) return;
                Navigator.pop(dialogContext, ok);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Verify'),
            ),
          ],
        ),
      ),
    );

    if (!mounted) return false;
    if (verified != true) {
      _showSnackBar('Invalid code or deletion cancelled.', Colors.red);
      return false;
    }
    return true;
  }

  Future<void> _showBulkDeleteByDateDialog() async {
    final box = _userBox;
    if (box == null || box.isEmpty) {
      _showSnackBar('No OTP accounts to delete right now.', Colors.orange);
      return;
    }

    final isLoggedIn = await _syncService.isLoggedIn();
    if (!mounted) return;

    final now = DateTime.now();
    var startDate = DateTime(now.year, now.month, now.day);
    var endDate = DateTime(now.year, now.month, now.day);
    var deleteEverywhere = false;

    Future<DateTime?> pickDate(DateTime initialDate) {
      return showDatePicker(
        context: context,
        initialDate: initialDate,
        firstDate: DateTime(2020),
        lastDate: DateTime(now.year + 1, 12, 31),
      );
    }

    final result = await showDialog<_BulkDeleteDateResult>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final start = _dateOnly(startDate);
          final end = _dateOnly(endDate);
          final validRange = !end.isBefore(start);
          final matchCount =
              validRange ? _accountsInDateRange(start, end).length : 0;

          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            backgroundColor: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF1E1E32)
                : Colors.white,
            title: const Text('Delete OTP Accounts By Date'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Choose a date range. Every OTP account added within that range will be selected for deletion.',
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await pickDate(startDate);
                            if (picked == null) return;
                            setDialogState(() => startDate = picked);
                          },
                          icon: const Icon(Icons.calendar_today_rounded),
                          label: Text(_formatAbsoluteDate(startDate)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await pickDate(endDate);
                            if (picked == null) return;
                            setDialogState(() => endDate = picked);
                          },
                          icon: const Icon(Icons.event_available_rounded),
                          label: Text(_formatAbsoluteDate(endDate)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(
                        label: const Text('Today'),
                        onPressed: () {
                          final today = DateTime(now.year, now.month, now.day);
                          setDialogState(() {
                            startDate = today;
                            endDate = today;
                          });
                        },
                      ),
                      ActionChip(
                        label: const Text('Last 7 days'),
                        onPressed: () {
                          final today = DateTime(now.year, now.month, now.day);
                          setDialogState(() {
                            startDate = today.subtract(const Duration(days: 6));
                            endDate = today;
                          });
                        },
                      ),
                      ActionChip(
                        label: const Text('Last 30 days'),
                        onPressed: () {
                          final today = DateTime(now.year, now.month, now.day);
                          setDialogState(() {
                            startDate =
                                today.subtract(const Duration(days: 29));
                            endDate = today;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (isLoggedIn)
                    SwitchListTile(
                      value: deleteEverywhere,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Delete everywhere'),
                      subtitle: const Text(
                        'Turn this on to remove the matching OTP accounts from all synced devices too.',
                      ),
                      onChanged: (value) {
                        setDialogState(() => deleteEverywhere = value);
                      },
                    )
                  else
                    const Text(
                      'Sign in if you want bulk deletion to remove OTP accounts everywhere. Offline mode can only delete them on this device.',
                    ),
                  const SizedBox(height: 8),
                  Text(
                    !validRange
                        ? 'Choose an end date on or after the start date.'
                        : '$matchCount OTP account${matchCount == 1 ? '' : 's'} match this range.',
                    style: TextStyle(
                      color: !validRange
                          ? Colors.red
                          : Theme.of(context).brightness == Brightness.dark
                              ? Colors.white70
                              : Colors.grey.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: validRange && matchCount > 0
                    ? () => Navigator.pop(
                          dialogContext,
                          _BulkDeleteDateResult(
                            startDate: start,
                            endDate: end,
                            deleteEverywhere: deleteEverywhere,
                          ),
                        )
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      deleteEverywhere ? Colors.red : Colors.orange,
                  foregroundColor: Colors.white,
                ),
                child: Text(
                  deleteEverywhere ? 'Review permanent delete' : 'Delete local',
                ),
              ),
            ],
          );
        },
      ),
    );

    if (result == null) return;

    final matches = _accountsInDateRange(result.startDate, result.endDate);
    if (matches.isEmpty) {
      _showSnackBar('No OTP accounts matched that date range.', Colors.orange);
      return;
    }

    if (result.deleteEverywhere) {
      if (!await _syncService.isLoggedIn()) {
        if (!mounted) return;
        _showSnackBar(
          'Sign in first to delete synced OTP accounts everywhere.',
          Colors.orange,
        );
        return;
      }

      final currentSession = await _currentSessionInfo();
      if (!mounted) return;
      if (currentSession == null) {
        _showSnackBar(
          'This device could not be verified for cloud deletion.',
          Colors.red,
        );
        return;
      }
      if (!currentSession.isPrimary) {
        _showSnackBar(
          'Deleting multiple OTP accounts everywhere is only available from your primary device.',
          Colors.orange,
        );
        return;
      }
    }

    final confirmed = await _showBulkDeleteConfirmationDialog(
      count: matches.length,
      startDate: result.startDate,
      endDate: result.endDate,
      deleteEverywhere: result.deleteEverywhere,
    );
    if (!confirmed) return;

    var deletedCount = 0;
    var failedCount = 0;

    if (result.deleteEverywhere) {
      final verified = await _confirmBulkDeleteEverywhereWithOtp(
        count: matches.length,
        startDate: result.startDate,
        endDate: result.endDate,
      );
      if (!verified) return;

      for (final account in matches) {
        final ok = await _syncService.deleteAccountEverywhere(account.id);
        if (ok) {
          deletedCount++;
          currentOTPs.remove(account.id);
          timers.remove(account.id);
          blurredCodes.remove(account.id);
        } else {
          failedCount++;
        }
      }
    } else {
      for (final account in matches) {
        await _syncService.deleteAccountLocalOnly(account.id);
        deletedCount++;
        currentOTPs.remove(account.id);
        timers.remove(account.id);
        blurredCodes.remove(account.id);
      }
    }

    await _initUserBox();
    _updateAllOTPs();
    if (!mounted) return;

    setState(() {});
    if (failedCount == 0) {
      _showSnackBar(
        result.deleteEverywhere
            ? 'Deleted $deletedCount OTP account${deletedCount == 1 ? '' : 's'} everywhere.'
            : 'Deleted $deletedCount OTP account${deletedCount == 1 ? '' : 's'} on this device.',
        result.deleteEverywhere ? Colors.red : Colors.orange,
      );
    } else {
      _showSnackBar(
        'Deleted $deletedCount OTP account${deletedCount == 1 ? '' : 's'}, but $failedCount failed.',
        Colors.orange,
      );
    }
  }

  Future<bool> _showBulkDeleteConfirmationDialog({
    required int count,
    required DateTime startDate,
    required DateTime endDate,
    required bool deleteEverywhere,
  }) async {
    var confirmationText = '';

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              final canDelete =
                  confirmationText.trim().toUpperCase() == 'DELETE';
              return AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                backgroundColor: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF1E1E32)
                    : Colors.white,
                title: Row(
                  children: [
                    Icon(
                      deleteEverywhere
                          ? Icons.warning_amber_rounded
                          : Icons.delete_sweep_rounded,
                      color: deleteEverywhere ? Colors.red : Colors.orange,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      deleteEverywhere
                          ? 'Permanent OTP Deletion'
                          : 'Delete OTP Accounts',
                    ),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      deleteEverywhere
                          ? 'This will permanently delete $count OTP account${count == 1 ? '' : 's'} added between ${_formatAbsoluteDate(startDate)} and ${_formatAbsoluteDate(endDate)} from all synced devices.'
                          : 'This will delete $count OTP account${count == 1 ? '' : 's'} added between ${_formatAbsoluteDate(startDate)} and ${_formatAbsoluteDate(endDate)} from this device only.',
                    ),
                    const SizedBox(height: 16),
                    const Text('Type DELETE to confirm.'),
                    const SizedBox(height: 8),
                    TextField(
                      onChanged: (value) {
                        setDialogState(() => confirmationText = value);
                      },
                      decoration: const InputDecoration(
                        hintText: 'DELETE',
                        border: OutlineInputBorder(),
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
                    onPressed: canDelete
                        ? () => Navigator.pop(dialogContext, true)
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          deleteEverywhere ? Colors.red : Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(
                      deleteEverywhere ? 'Delete everywhere' : 'Delete local',
                    ),
                  ),
                ],
              );
            },
          ),
        ) ??
        false;
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
    final isLoggedIn = await _syncService.isLoggedIn();
    if (!mounted) return;

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
              subtitle: isLoggedIn && _isSyncEnabled
                  ? 'Cloud sync is ON. This account may come back when you sync!'
                  : 'Local only. Other devices keep the account.',
              color: Colors.orange,
              onTap: () => Navigator.pop(context, 'local'),
            ),
            const SizedBox(height: 8),
            _deleteOptionTile(
              icon: isLoggedIn
                  ? Icons.cloud_off_rounded
                  : Icons.lock_outline_rounded,
              title: isLoggedIn
                  ? 'Everywhere (Permanent)'
                  : 'Everywhere (Sign in required)',
              subtitle: isLoggedIn
                  ? 'Removed from all devices & cloud. Cannot be undone!'
                  : 'Cloud deletion is not available while using offline mode.',
              color: isLoggedIn ? Colors.red : Colors.grey,
              onTap: () =>
                  Navigator.pop(context, isLoggedIn ? 'everywhere' : 'signin'),
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

    if (choice == 'signin') {
      _showSnackBar(
        'Sign in first to delete synced accounts everywhere.',
        Colors.orange,
      );
      return;
    }

    if (choice == 'local') {
      // Show warning about sync if enabled
      if (isLoggedIn && _isSyncEnabled) {
        if (!mounted) return;
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
              'Cloud sync is currently ENABLED.\n\n'
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
      if (!await _syncService.isLoggedIn()) {
        _showSnackBar(
          'Sign in first to delete synced accounts everywhere.',
          Colors.orange,
        );
        return;
      }

      // Show final confirmation with "DELETE" typing
      if (!mounted) return;
      final confirmed = await _showDeleteConfirmationDialog(
          context, serviceName, cardColor, textPrimary, textSecondary);
      if (!confirmed) return;

      _showSnackBar('Deleting everywhere', Colors.grey);
      final ok = await _syncService.deleteAccountEverywhere(accountId);
      if (ok) {
        setState(() {
          currentOTPs.remove(accountId);
          timers.remove(accountId);
          blurredCodes.remove(accountId);
        });
        _showSnackBar('Account deleted from all devices', Colors.red);
      } else {
        _showSnackBar('Failed to delete from cloud try again', Colors.red);
      }
    }
  }

  Future<bool> _showDeleteConfirmationDialog(
      BuildContext context,
      String serviceName,
      Color cardColor,
      Color textPrimary,
      Color textSecondary) async {
    var confirmationText = '';

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
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: Colors.red.withValues(alpha: 0.3)),
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
                    onChanged: (value) {
                      setState(() {
                        confirmationText = value;
                      });
                    },
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: confirmationText.trim().toUpperCase() == 'DELETE'
                          ? Colors.red
                          : textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Type DELETE here',
                      hintStyle: TextStyle(color: textSecondary, fontSize: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                            color: Colors.red.withValues(alpha: 0.5)),
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
                    Navigator.pop(context, false);
                  },
                  child: Text('Cancel', style: TextStyle(color: textSecondary)),
                ),
                ElevatedButton(
                  onPressed: confirmationText.trim().toUpperCase() == 'DELETE'
                      ? () {
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
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
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
                          fontSize: 11, color: color.withValues(alpha: 0.7))),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: color.withValues(alpha: 0.5), size: 18),
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
              ? Colors.red.withValues(alpha: 0.08)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.grey[50]),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: destructive
                ? Colors.red.withValues(alpha: 0.2)
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

  void _openLoginForSync() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const LoginScreen(returnToPreviousOnOffline: true),
      ),
    );
    if (!mounted) return;

    await _loadSyncStatus();
    await _initUserBox();
    await _loadProfileData();
    await _loadUnreadNotificationCount();
    await _initializePasswordlessApprovals();
    await _checkBackupCodeRequirement();
    _updateAllOTPs();
  }

  void _syncData() async {
    if (!await _syncService.isLoggedIn()) {
      _showSnackBar(
        'Sign in to enable automatic cross-platform sync.',
        Colors.orange,
      );
      _openLoginForSync();
      return;
    }

    final syncEnabled = await _syncService.isSyncEnabled();

    if (!syncEnabled) {
      _showSnackBar('Sync is disabled. Enable it in Settings -> Sync to Cloud',
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
        await _loadUnreadNotificationCount();
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
      _showSnackBar(
        _syncService.lastErrorMessage ??
            'Sync failed. Check your internet connection.',
        Colors.red,
      );
    }
  }

  void _showSnackBar(String message, Color color) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
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

  Future<T> _runWithBlockingProgress<T>({
    required String message,
    required Future<T> Function() action,
  }) async {
    var progressShown = false;
    if (mounted) {
      progressShown = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => PopScope(
            canPop: false,
            child: AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              backgroundColor:
                  Theme.of(dialogContext).brightness == Brightness.dark
                      ? const Color(0xFF1E1E32)
                      : Colors.white,
              content: Row(
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.8),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(
                        color: Theme.of(dialogContext).colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    try {
      return await action();
    } finally {
      if (mounted && progressShown) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _passwordlessPollTimer?.cancel();
    _approvalNotificationService.passwordlessOpenSignal
        .removeListener(_handlePasswordlessNotificationSignal);
    _approvalNotificationService.passwordlessRequestSignal
        .removeListener(_handleForegroundPasswordlessRequestSignal);
    super.dispose();
  }
}

class _BulkDeleteDateResult {
  const _BulkDeleteDateResult({
    required this.startDate,
    required this.endDate,
    required this.deleteEverywhere,
  });

  final DateTime startDate;
  final DateTime endDate;
  final bool deleteEverywhere;
}
