import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'dart:io' show Platform;
import 'models/otp_account.dart';
import 'models/password_entry.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Only use bitsdojo_window on desktop platforms
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    appWindow.minSize = const Size(900, 700);
    appWindow.size = const Size(900, 700);
    appWindow.alignment = Alignment.center;
  }

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

  runApp(const MyApp());

  // Only call show on desktop platforms
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    appWindow.show();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

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
            title: 'BeatzLock Authenticator',
            theme: themeProvider.lightTheme,
            darkTheme: themeProvider.darkTheme,
            themeMode: themeProvider.themeMode,
            home: SplashScreen(), // Removed 'const' keyword
            debugShowCheckedModeBanner: false,
          );
        },
      ),
    );
  }
}
