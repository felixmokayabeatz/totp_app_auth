// main.dart

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'models/otp_account.dart';
import 'models/password_entry.dart';
import 'services/secure_storage_service.dart';
import 'services/biometric_service.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();

  // REGISTER ADAPTERS MANUALLY
  Hive.registerAdapter(OTPAccountAdapter());
  Hive.registerAdapter(PasswordEntryAdapter());

  // DELETE CORRUPTED BOXES - RUN ONCE
  try {
    await Hive.deleteBoxFromDisk('otp_accounts');
    await Hive.deleteBoxFromDisk('passwords');
    await Hive.deleteBoxFromDisk('settings');
    await Hive.deleteBoxFromDisk('secure_data');
    print('All boxes deleted successfully');
  } catch (e) {
    print('Error deleting: $e');
  }

  // Open fresh boxes
  await Hive.openBox<OTPAccount>('otp_accounts');
  await Hive.openBox<PasswordEntry>('passwords');
  await Hive.openBox('settings');
  await Hive.openBox('secure_data');

  await SecureStorageService().init();
  await BiometricService().init();

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  MyApp({super.key});

  @override
  Widget build(BuildContext context) {
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
