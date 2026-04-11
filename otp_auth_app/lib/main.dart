import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'models/otp_account.dart';
import 'models/password_entry.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set minimum window size and always on top
  appWindow.minSize = Size(900, 700);
  appWindow.size = Size(900, 700);
  appWindow.alignment = Alignment.center;
  
  await Hive.initFlutter();
  
  // Register adapters FIRST
  if (!Hive.isAdapterRegistered(0)) {
    Hive.registerAdapter(OTPAccountAdapter());
  }
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(PasswordEntryAdapter());
  }
  
  // SAFELY delete old box - handle errors gracefully
  try {
    // Check if old box exists without trying to read its contents
    if (await Hive.boxExists('otp_accounts')) {
      print('Found old otp_accounts box, attempting to delete...');
      
      // Try to open and clear the box (may fail if type mismatch)
      try {
        final oldBox = await Hive.openBox('otp_accounts');
        await oldBox.clear();
        await oldBox.close();
      } catch (e) {
        print('Could not open old box normally: $e');
        // If normal open fails, try to delete directly from disk
      }
      
      // Force delete the box from disk
      await Hive.deleteBoxFromDisk('otp_accounts');
      print('Old box deleted successfully!');
    } else {
      print('No old box found');
    }
  } catch (e) {
    print('Error deleting old box (non-critical): $e');
    // Continue execution - this error shouldn't stop the app
  }
  
  // Open new boxes
  await Hive.openBox<OTPAccount>('otp_accounts');
  await Hive.openBox<PasswordEntry>('passwords');
  await Hive.openBox('settings');
  
  runApp(MyApp());
  appWindow.show();
}

class MyApp extends StatelessWidget {
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
            home: SplashScreen(),
            debugShowCheckedModeBanner: false,
          );
        },
      ),
    );
  }
}