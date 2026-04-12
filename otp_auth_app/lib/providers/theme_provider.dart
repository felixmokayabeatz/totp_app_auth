// lib/providers/theme_provider.dart


import 'package:flutter/material.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  int _accentColorIndex = 0;
  
  final List<Color> accentColors = [
    Color(0xFF667eea), // Default purple-blue
    Color(0xFF00b4db), // Cyan
    Color(0xFFf12711), // Red-orange
    Color(0xFF11998e), // Green
    Color(0xFFf53844), // Pink-red
    Color(0xFFfc4a1a), // Orange
  ];
  
  ThemeMode get themeMode => _themeMode;
  Color get accentColor => accentColors[_accentColorIndex];
  int get accentColorIndex => _accentColorIndex;
  
  ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      primaryColor: accentColor,
      colorScheme: ColorScheme.light(
        primary: accentColor,
        secondary: accentColor.withOpacity(0.7),
        tertiary: accentColor.withOpacity(0.3),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      cardTheme: CardThemeData(  // Changed from CardTheme to CardThemeData
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
        ),
      ),
    );
  }
  
  ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      primaryColor: accentColor,
      colorScheme: ColorScheme.dark(
        primary: accentColor,
        secondary: accentColor.withOpacity(0.7),
        tertiary: accentColor.withOpacity(0.3),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      cardTheme: CardThemeData(  // Changed from CardTheme to CardThemeData
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
        ),
      ),
    );
  }
  
  bool get isDarkMode {
    return _themeMode == ThemeMode.dark;
  }
  
  void toggleTheme() {
    if (_themeMode == ThemeMode.light) {
      _themeMode = ThemeMode.dark;
    } else if (_themeMode == ThemeMode.dark) {
      _themeMode = ThemeMode.system;
    } else {
      _themeMode = ThemeMode.light;
    }
    notifyListeners();
  }
  
  void setAccentColor(int index) {
    _accentColorIndex = index;
    notifyListeners();
  }
  
  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    notifyListeners();
  }
}