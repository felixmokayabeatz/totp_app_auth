import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'models/otp_account.dart';
import 'models/password_entry.dart';
import 'services/secure_storage_service.dart';
import 'services/biometric_service.dart';
import 'services/app_lock_service.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/splash_screen.dart';

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

  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final AppLockService _appLockService = AppLockService();
  bool _isLocked = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndLockOnStart();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkAndLockOnStart() async {
    final isEnabled = await _appLockService.isAppLockEnabled();
    if (isEnabled && mounted) {
      // Record current time as last active time
      await _appLockService.recordAppActivity();
      setState(() => _isLocked = true);
      _initialized = true;
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _showUnlockDialog();
        }
      });
    } else {
      setState(() => _initialized = true);
    }
  }

  Future<void> _showUnlockDialog() async {
    if (!mounted) return;
    final authenticated = await _appLockService.authenticateToUnlock(context);
    if (authenticated && mounted) {
      setState(() => _isLocked = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print('DEBUG: Lifecycle state: $state');

    if (state == AppLifecycleState.paused) {
      // App went to background - THIS IS WHEN WE SHOULD RECORD THE TIME
      _appLockService.recordAppActivity();
      print('DEBUG: Recorded app activity at: ${DateTime.now()}');
    } else if (state == AppLifecycleState.resumed &&
        _initialized &&
        !_isLocked) {
      print('DEBUG: App resumed, checking lock');
      _checkAndLock();
    }
  }

  Future<void> _checkAndLock() async {
    final needsUnlock = await _appLockService.needsUnlock();
    print('DEBUG: Needs unlock: $needsUnlock');

    if (needsUnlock && !_isLocked && mounted) {
      setState(() => _isLocked = true);
      final authenticated = await _appLockService.authenticateToUnlock(context);
      if (authenticated && mounted) {
        setState(() => _isLocked = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (_isLocked) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.light(),
        home: Builder(
          builder: (lockContext) {
            return Scaffold(
              backgroundColor: const Color(0xFF667eea),
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.lock_outline,
                        size: 80, color: Colors.white),
                    const SizedBox(height: 20),
                    const Text('BeatzLock is locked',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    const Text('Authenticate to continue',
                        style: TextStyle(color: Colors.white70)),
                    const SizedBox(height: 30),
                    ElevatedButton.icon(
                      onPressed: () async {
                        final authenticated = await _appLockService
                            .authenticateToUnlock(lockContext);
                        if (authenticated && mounted) {
                          setState(() => _isLocked = false);
                        }
                      },
                      icon: const Icon(Icons.fingerprint),
                      label: const Text('Unlock'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFF667eea),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 40, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'BeatzLock Authenticator',
            theme: themeProvider.lightTheme,
            darkTheme: themeProvider.darkTheme,
            themeMode: themeProvider.themeMode,
            home: SplashScreen(),
          );
        },
      ),
    );
  }
}
