import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  static const _themeModeKey = 'theme_mode';
  static const _accentColorIndexKey = 'accent_color_index';

  ThemeMode _themeMode = ThemeMode.system;
  int _accentColorIndex = 0;

  final List<Color> accentColors = const [
    Color(0xFF4F46E5),
    Color(0xFF0F766E),
    Color(0xFFEA580C),
    Color(0xFFDC2626),
    Color(0xFF2563EB),
    Color(0xFF7C3AED),
  ];

  ThemeMode get themeMode => _themeMode;
  Color get accentColor => accentColors[_accentColorIndex];
  int get accentColorIndex => _accentColorIndex;

  ThemeData get lightTheme => _buildTheme(Brightness.light);
  ThemeData get darkTheme => _buildTheme(Brightness.dark);

  bool isDarkMode([Brightness? platformBrightness]) {
    return switch (_themeMode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => platformBrightness == Brightness.dark,
    };
  }

  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final themeModeName = prefs.getString(_themeModeKey);
    final accentIndex = prefs.getInt(_accentColorIndexKey);

    _themeMode = ThemeMode.values.firstWhere(
      (mode) => mode.name == themeModeName,
      orElse: () => ThemeMode.system,
    );
    if (accentIndex != null &&
        accentIndex >= 0 &&
        accentIndex < accentColors.length) {
      _accentColorIndex = accentIndex;
    }
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, _themeMode.name);
    await prefs.setInt(_accentColorIndexKey, _accentColorIndex);
  }

  ThemeData _buildTheme(Brightness brightness) {
    final exactPrimary = accentColor;
    final secondary = _shiftHue(exactPrimary, 34);
    final isDark = brightness == Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: accentColor,
      brightness: brightness,
    ).copyWith(
      primary: exactPrimary,
      onPrimary: _idealTextColor(exactPrimary),
      primaryContainer:
          Color.lerp(exactPrimary, isDark ? Colors.black : Colors.white, 0.82)!,
      onPrimaryContainer: isDark ? Colors.white : exactPrimary,
      secondary: secondary,
      onSecondary: _idealTextColor(secondary),
      secondaryContainer:
          Color.lerp(secondary, isDark ? Colors.black : Colors.white, 0.84)!,
      outlineVariant:
          Color.lerp(exactPrimary, isDark ? Colors.white : Colors.black, 0.84)!,
      surfaceTint: Colors.transparent,
    );

    final scaffoldColor = isDark
        ? Color.lerp(const Color(0xFF0B1120), exactPrimary, 0.08)!
        : Color.lerp(const Color(0xFFF4F7FB), exactPrimary, 0.04)!;
    final cardBorderColor = Color.lerp(
      colorScheme.outlineVariant,
      exactPrimary,
      isDark ? 0.18 : 0.12,
    )!;

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldColor,
      cardTheme: CardThemeData(
        elevation: isDark ? 0 : 2,
        color: colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cardBorderColor),
        ),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.35)
            : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.4),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: colorScheme.primary.withValues(alpha: 0.12),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.onPrimary;
          }
          return isDark ? Colors.white70 : Colors.grey.shade100;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return isDark ? Colors.white12 : Colors.grey.shade300;
        }),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: colorScheme.primary,
          highlightColor: colorScheme.primary.withValues(alpha: 0.12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: colorScheme.primary.withValues(alpha: 0.35)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: colorScheme.onSurface,
        displayColor: colorScheme.onSurface,
      ),
    );
  }

  Color _shiftHue(Color color, double degrees) {
    final hsl = HSLColor.fromColor(color);
    final hue = (hsl.hue + degrees) % 360;
    final saturation = (hsl.saturation * 0.9).clamp(0.36, 0.88).toDouble();
    final lightness = hsl.lightness.clamp(0.34, 0.62).toDouble();
    return hsl
        .withHue(hue)
        .withSaturation(saturation)
        .withLightness(lightness)
        .toColor();
  }

  Color _idealTextColor(Color background) {
    return background.computeLuminance() > 0.45 ? Colors.black : Colors.white;
  }

  void toggleTheme({Brightness? platformBrightness}) {
    final currentlyDark = isDarkMode(platformBrightness);
    _themeMode = currentlyDark ? ThemeMode.light : ThemeMode.dark;
    unawaited(_savePreferences());
    notifyListeners();
  }

  void setAccentColor(int index) {
    if (index < 0 || index >= accentColors.length) return;
    _accentColorIndex = index;
    unawaited(_savePreferences());
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    unawaited(_savePreferences());
    notifyListeners();
  }
}
