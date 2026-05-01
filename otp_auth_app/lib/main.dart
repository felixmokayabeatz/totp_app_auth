import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'models/app_update_info.dart';
import 'models/otp_account.dart';
import 'models/password_entry.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/app_update_service.dart';
import 'services/app_lock_service.dart';
import 'services/biometric_service.dart';
import 'services/otp_service.dart';
import 'services/secure_storage_service.dart';
import 'services/sync_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final appSupportDir = await getApplicationSupportDirectory();
    await Hive.initFlutter(appSupportDir.path);
  } else {
    await Hive.initFlutter();
  }

  if (!Hive.isAdapterRegistered(0)) {
    Hive.registerAdapter(OTPAccountAdapter());
  }
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(PasswordEntryAdapter());
  }

  await Hive.openBox<OTPAccount>('otp_accounts');
  await Hive.openBox<PasswordEntry>('passwords');
  await Hive.openBox('settings');

  await SecureStorageService().init();
  await BiometricService().init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  static const Duration _backgroundLockThreshold = Duration(seconds: 2);
  static const Duration _sessionHeartbeatInterval = Duration(seconds: 30);

  final AppLockService _appLockService = AppLockService();
  final AppUpdateService _appUpdateService = AppUpdateService();
  final SyncService _syncService = SyncService();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  bool _initialized = false;
  bool _isLocked = true;
  bool _unlockInProgress = false;
  bool _updateCheckInProgress = false;
  bool _sessionHeartbeatInProgress = false;
  bool _openingRequiredUpdate = false;
  bool _sessionReady = false;
  DateTime? _backgroundedAt;
  Timer? _updateTimer;
  Timer? _sessionHeartbeatTimer;
  AppUpdateInfo? _requiredUpdateInfo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _refreshUpdateStatus(),
    );
    _sessionHeartbeatTimer = Timer.periodic(
      _sessionHeartbeatInterval,
      (_) => unawaited(_runSessionHeartbeat()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeApp();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updateTimer?.cancel();
    _sessionHeartbeatTimer?.cancel();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    try {
      await _refreshUpdateStatus();
      final dialogContext = _navigatorKey.currentContext;
      if (dialogContext != null) {
        await _appLockService.ensureMandatoryLock(dialogContext);
      }
      await _restoreSession();
    } catch (e) {
      debugPrint('App init error: $e');
      if (mounted) {
        setState(() {
          _sessionReady = true;
        });
      }
    } finally {
      if (!mounted) return;
      setState(() {
        _initialized = true;
        _isLocked = true;
      });
      unawaited(_runSessionHeartbeat());
    }
  }

  Future<void> _refreshUpdateStatus() async {
    if (_updateCheckInProgress || _appUpdateService.currentPlatform.isEmpty) {
      return;
    }

    _updateCheckInProgress = true;
    try {
      final info = await _appUpdateService.checkForUpdate();
      if (!mounted) return;

      setState(() {
        _requiredUpdateInfo =
            info != null && info.updateAvailable && info.forceUpdate
                ? info
                : null;
      });
    } catch (e) {
      debugPrint('Update check error: $e');
    } finally {
      _updateCheckInProgress = false;
    }
  }

  Future<void> _openRequiredUpdate() async {
    final info = _requiredUpdateInfo;
    if (info == null || _openingRequiredUpdate) return;

    setState(() {
      _openingRequiredUpdate = true;
    });

    try {
      final opened = await _appUpdateService.openUpdate(info);
      if (!opened) {
        debugPrint('Failed to open update URL: ${info.preferredOpenUrl}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _openingRequiredUpdate = false;
        });
      }
    }
  }

  Future<void> _restoreSession() async {
    final secureStorage = SecureStorageService();
    final token = await secureStorage.read(SecureStorageService.accessTokenKey);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    try {
      if (token == null || token.isEmpty) {
        await authProvider.logout();
        return;
      }

      final email =
          await secureStorage.read(SecureStorageService.userEmailKey) ?? '';
      final username =
          await secureStorage.read(SecureStorageService.currentUserKey) ?? '';
      final userId =
          await secureStorage.read(SecureStorageService.userIdKey) ?? '';

      final sessionStillValid = await _syncService.validateCurrentSession();
      if (!sessionStillValid) {
        await _syncService.logout(notifyServer: false);
        await authProvider.logout();
        return;
      }

      OTPService().clearCachedUserId();
      await authProvider.setUserData(username, email, userId);
      final restoredKey = await _syncService.restoreEncryptionKey();

      try {
        await _syncService.migrateLegacyLocalAccounts();
      } catch (e) {
        debugPrint('Local account migration restore error: $e');
      }

      if (restoredKey) {
        unawaited(_restoreCloudDataInBackground());
      } else {
        debugPrint(
            'Cloud encryption key missing on startup; keeping user signed in and skipping cloud restore.');
      }
    } catch (e) {
      debugPrint('Session restore error: $e');
      final tokenStillExists =
          await secureStorage.read(SecureStorageService.accessTokenKey);
      if (tokenStillExists == null || tokenStillExists.isEmpty) {
        await authProvider.logout();
      }
    } finally {
      if (mounted) {
        setState(() {
          _sessionReady = true;
        });
      }
    }
  }

  Future<void> _restoreCloudDataInBackground() async {
    try {
      if (await _syncService.isSyncEnabled()) {
        await _syncService.downloadAndMergeAccounts();
      }
    } catch (e) {
      debugPrint('Background cloud restore error: $e');
    }
  }

  Future<void> _runSessionHeartbeat() async {
    if (!mounted ||
        !_initialized ||
        !_sessionReady ||
        _sessionHeartbeatInProgress) {
      return;
    }

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    if (!authProvider.isAuthenticated) {
      return;
    }

    _sessionHeartbeatInProgress = true;
    try {
      final sessionStillValid = await _syncService.heartbeatSession();
      if (!mounted || sessionStillValid) {
        return;
      }

      await authProvider.logout();
      if (!mounted) return;

      setState(() {
        _isLocked = false;
        _backgroundedAt = null;
      });
    } finally {
      _sessionHeartbeatInProgress = false;
    }
  }

  Future<void> _unlockApp(BuildContext context) async {
    if (!mounted || _unlockInProgress) return;

    setState(() {
      _unlockInProgress = true;
    });

    try {
      final authenticated = await _appLockService.authenticateToUnlock(context);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      if (authenticated) {
        await _appLockService.recordAppActivity();
        setState(() {
          _isLocked = false;
          _backgroundedAt = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _unlockInProgress = false;
        });
      }
    }
  }

  Future<void> _unlockWithPin(BuildContext context) async {
    if (!mounted || _unlockInProgress) return;

    setState(() {
      _unlockInProgress = true;
    });

    try {
      final authenticated = await _appLockService.authenticateWithPinOnly(
        context,
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      if (authenticated) {
        await _appLockService.recordAppActivity();
        setState(() {
          _isLocked = false;
          _backgroundedAt = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _unlockInProgress = false;
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_unlockInProgress || !_initialized) {
      return;
    }

    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        !_isLocked) {
      _backgroundedAt = DateTime.now();
      _appLockService.recordAppActivity();
      return;
    }

    if (state == AppLifecycleState.resumed && _backgroundedAt != null) {
      final elapsed = DateTime.now().difference(_backgroundedAt!);
      _backgroundedAt = null;

      if (elapsed >= _backgroundLockThreshold && mounted) {
        setState(() {
          _isLocked = true;
        });
      }

      unawaited(_refreshUpdateStatus());
      unawaited(_runSessionHeartbeat());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_refreshUpdateStatus());
      unawaited(_runSessionHeartbeat());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<ThemeProvider, AuthProvider>(
      builder: (context, themeProvider, authProvider, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'BeatzLock Authenticator',
          navigatorKey: _navigatorKey,
          theme: themeProvider.lightTheme,
          darkTheme: themeProvider.darkTheme,
          themeMode: themeProvider.themeMode,
          home: !_initialized || !_sessionReady
              ? const _LaunchLoadingScreen()
              : _requiredUpdateInfo != null
                  ? _RequiredUpdateScreen(
                      info: _requiredUpdateInfo!,
                      isOpeningUpdate: _openingRequiredUpdate,
                      onUpdateNow: _openRequiredUpdate,
                      onRefreshStatus: _refreshUpdateStatus,
                    )
                  : authProvider.isAuthenticated
                      ? (_isLocked
                          ? _AppLockScreen(
                              isBusy: _unlockInProgress,
                              onUnlock: _unlockApp,
                              onUsePin: _unlockWithPin,
                            )
                          : HomeScreen())
                      : LoginScreen(),
        );
      },
    );
  }
}

class _RequiredUpdateScreen extends StatelessWidget {
  const _RequiredUpdateScreen({
    required this.info,
    required this.isOpeningUpdate,
    required this.onUpdateNow,
    required this.onRefreshStatus,
  });

  final AppUpdateInfo info;
  final bool isOpeningUpdate;
  final Future<void> Function() onUpdateNow;
  final Future<void> Function() onRefreshStatus;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final releaseNotes = info.releaseNotes.trim();
    final notesMaxHeight =
        MediaQuery.sizeOf(context).height < 700 ? 220.0 : 280.0;

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Card(
                        child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.14),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(
                              Icons.system_update_alt_rounded,
                              color: Colors.orange,
                              size: 30,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Update required',
                                  style:
                                      Theme.of(context).textTheme.headlineSmall,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Install ${info.latestLabel} to continue using BeatzLock.',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Text(
                        info.reason,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      if (releaseNotes.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          'What changed',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: notesMaxHeight,
                            ),
                            child: Scrollbar(
                              child: SingleChildScrollView(
                                child: Text(releaseNotes),
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: isOpeningUpdate ? null : onUpdateNow,
                          icon: isOpeningUpdate
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.open_in_new_rounded),
                          label: Text(
                            isOpeningUpdate ? 'Opening download...' : 'Update now',
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: onRefreshStatus,
                          child: const Text('Check again'),
                        ),
                      ),
                    ],
                  ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LaunchLoadingScreen extends StatelessWidget {
  const _LaunchLoadingScreen();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined, size: 48, color: colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Preparing secure access...',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(color: colorScheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppLockScreen extends StatelessWidget {
  const _AppLockScreen({
    required this.isBusy,
    required this.onUnlock,
    required this.onUsePin,
  });

  final bool isBusy;
  final Future<void> Function(BuildContext context) onUnlock;
  final Future<void> Function(BuildContext context) onUsePin;

  @override
  Widget build(BuildContext context) {
    final isMobile = Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colorScheme.primary,
              colorScheme.primaryContainer,
              colorScheme.secondaryContainer,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                margin: const EdgeInsets.all(24),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.lock_outline_rounded,
                          size: 36,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'BeatzLock is protected',
                        style: textTheme.headlineSmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isMobile
                            ? 'Unlock the app with your device security or your BeatzLock PIN.'
                            : 'Unlock the app with your computer security or your BeatzLock PIN.',
                        style: textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: isBusy ? null : () => onUnlock(context),
                          icon: isBusy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.lock_open_rounded),
                          label: Text(isBusy ? 'Checking...' : 'Unlock'),
                        ),
                      ),
                      if (!isMobile) ...[
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: isBusy ? null : () => onUsePin(context),
                          child: const Text('Use BeatzLock PIN instead'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
