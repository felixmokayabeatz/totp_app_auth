import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'models/otp_account.dart';
import 'models/password_entry.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/splash_screen.dart';
import 'services/app_lock_service.dart';
import 'services/biometric_service.dart';
import 'services/secure_storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();

  if (!Hive.isAdapterRegistered(0)) {
    Hive.registerAdapter(OTPAccountAdapter());
  }
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(PasswordEntryAdapter());
  }

  await Hive.openBox<OTPAccount>('otp_accounts');
  await Hive.openBox<PasswordEntry>('passwords');
  await Hive.openBox('settings');
  await Hive.openBox('secure_data');

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
  final AppLockService _appLockService = AppLockService();

  bool _initialized = false;
  bool _isLocked = true;
  bool _unlockInProgress = false;
  bool _didEnterBackground = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeSecurity();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _initializeSecurity() async {
    await _appLockService.ensureMandatoryLock(context);
    if (!mounted) return;

    setState(() {
      _initialized = true;
      _isLocked = true;
    });
  }

  Future<void> _unlockApp() async {
    if (!mounted || _unlockInProgress) return;

    setState(() {
      _unlockInProgress = true;
    });

    final authenticated = await _appLockService.authenticateToUnlock(context);
    if (!mounted) return;

    if (authenticated) {
      await _appLockService.recordAppActivity();
      setState(() {
        _isLocked = false;
      });
    }

    if (mounted) {
      setState(() {
        _unlockInProgress = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_unlockInProgress || !_initialized) {
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _didEnterBackground = true;
      _appLockService.recordAppActivity();
      return;
    }

    if (state == AppLifecycleState.resumed &&
        _initialized &&
        _didEnterBackground) {
      _didEnterBackground = false;
      if (mounted) {
        setState(() {
          _isLocked = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'BeatzLock Authenticator',
          theme: themeProvider.lightTheme,
          darkTheme: themeProvider.darkTheme,
          themeMode: themeProvider.themeMode,
          home: !_initialized
              ? const _LaunchLoadingScreen()
              : _isLocked
                  ? _AppLockScreen(
                      isBusy: _unlockInProgress,
                      onUnlock: _unlockApp,
                    )
                  : const SplashScreen(),
        );
      },
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
  });

  final bool isBusy;
  final Future<void> Function() onUnlock;

  @override
  Widget build(BuildContext context) {
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
                        'Unlock the app with your phone security or your BeatzLock PIN.',
                        style: textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: isBusy ? null : () => onUnlock(),
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
