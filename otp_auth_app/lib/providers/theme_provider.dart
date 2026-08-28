import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One selectable accent, with the name shown next to it in the picker.
class AccentOption {
  const AccentOption(this.name, this.color);

  final String name;
  final Color color;
}

class ThemeProvider extends ChangeNotifier {
  static const _themeModeKey = 'theme_mode';
  static const _accentColorIndexKey = 'accent_color_index';

  ThemeMode _themeMode = ThemeMode.system;
  int _accentColorIndex = 0;

  /// The accent palette.
  ///
  /// The first six slots keep the hue family they had before, so an existing
  /// user's saved index still lands on the colour they picked -- only the exact
  /// shade moved. Everything after that is new.
  ///
  /// The accent is not only a button fill here: screens also use it for icons
  /// and label text directly on a white card. That rules out the bright, pale
  /// tones -- a 500-weight cyan or lime looks lovely on a swatch and is
  /// unreadable as 13pt text. Every colour below clears 3.5:1 against white
  /// text as a fill, and most clear 4.5:1.
  static const List<AccentOption> accentOptions = [
    AccentOption('Indigo', Color(0xFF5B5BD6)),
    AccentOption('Teal', Color(0xFF0D9488)),
    AccentOption('Orange', Color(0xFFEA580C)),
    AccentOption('Rose', Color(0xFFE11D48)),
    AccentOption('Blue', Color(0xFF0A84FF)),
    AccentOption('Purple', Color(0xFF8B5CF6)),
    AccentOption('Green', Color(0xFF059669)),
    AccentOption('Pink', Color(0xFFDB2777)),
    AccentOption('Cyan', Color(0xFF0E7490)),
    AccentOption('Amber', Color(0xFFB45309)),
    AccentOption('Lime', Color(0xFF4D7C0F)),
    AccentOption('Graphite', Color(0xFF64748B)),
  ];

  List<Color> get accentColors =>
      accentOptions.map((option) => option.color).toList(growable: false);

  ThemeMode get themeMode => _themeMode;
  Color get accentColor => accentOptions[_accentColorIndex].color;
  String get accentColorName => accentOptions[_accentColorIndex].name;
  int get accentColorIndex => _accentColorIndex;

  // Themes are rebuilt only when the mode or accent actually changes. Building
  // one walks a large ColorScheme and a dozen component themes, and MaterialApp
  // reads both of these on every frame it rebuilds.
  ThemeData? _cachedLightTheme;
  ThemeData? _cachedDarkTheme;

  ThemeData get lightTheme =>
      _cachedLightTheme ??= _buildTheme(Brightness.light);
  ThemeData get darkTheme => _cachedDarkTheme ??= _buildTheme(Brightness.dark);

  void _invalidateThemes() {
    _cachedLightTheme = null;
    _cachedDarkTheme = null;
  }

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
        accentIndex < accentOptions.length) {
      _accentColorIndex = accentIndex;
    }
    _invalidateThemes();
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

    // A near-neutral ground with a whisper of the accent in it, the way iOS
    // tints its greys towards the active colour rather than sitting on pure
    // grey. Cards then sit a shade above it instead of blending in.
    final scaffoldColor = isDark
        ? Color.lerp(const Color(0xFF0E0F1A), exactPrimary, 0.08)!
        : Color.lerp(const Color(0xFFF2F4F8), exactPrimary, 0.035)!;
    // Kept a hair off 0xFF1E1E32, the navy the screens paint their own cards
    // with, so themed surfaces and hand-rolled ones read as the same material.
    final surfaceColor = isDark
        ? Color.lerp(const Color(0xFF1C1D2E), exactPrimary, 0.06)!
        : Colors.white;

    final colorScheme = ColorScheme.fromSeed(
      seedColor: accentColor,
      brightness: brightness,
    ).copyWith(
      primary: exactPrimary,
      onPrimary: _idealTextColor(exactPrimary),
      // Screens read colorScheme.surface for their own cards and sheets, so it
      // has to be the same material the card and dialog themes paint. Leaving
      // it at the seeded default put hand-rolled cards on one shade and themed
      // ones on another.
      surface: surfaceColor,
      primaryContainer: Color.lerp(
        exactPrimary,
        isDark ? Colors.black : Colors.white,
        0.82,
      )!,
      onPrimaryContainer: isDark ? Colors.white : _deepen(exactPrimary),
      secondary: secondary,
      onSecondary: _idealTextColor(secondary),
      secondaryContainer: Color.lerp(
        secondary,
        isDark ? Colors.black : Colors.white,
        0.84,
      )!,
      outlineVariant: Color.lerp(
        exactPrimary,
        isDark ? Colors.white : Colors.black,
        0.84,
      )!,
      surfaceTint: Colors.transparent,
    );

    final cardBorderColor = Color.lerp(
      colorScheme.outlineVariant,
      exactPrimary,
      isDark ? 0.18 : 0.12,
    )!;
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.black.withValues(alpha: 0.06);

    // Soft, wide, low-opacity shadows rather than the default hard drop.
    final shadowColor =
        isDark ? Colors.black : const Color(0xFF0B1120).withValues(alpha: 0.55);

    const cardRadius = 20.0;
    const controlRadius = 16.0;
    const sheetRadius = 28.0;

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldColor,
      canvasColor: surfaceColor,
      shadowColor: shadowColor,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      cardTheme: CardThemeData(
        elevation: isDark ? 0 : 1.5,
        color: surfaceColor,
        shadowColor: shadowColor,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: BorderSide(color: cardBorderColor),
        ),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        titleTextStyle: TextStyle(
          color: colorScheme.onPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: dividerColor,
        thickness: 1,
        space: 1,
      ),
      // Every AlertDialog in the app picks these up, so shape and depth stay
      // consistent without each screen restating them.
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceColor,
        surfaceTintColor: Colors.transparent,
        elevation: isDark ? 0 : 8,
        shadowColor: shadowColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
          side: BorderSide(color: cardBorderColor),
        ),
        titleTextStyle: TextStyle(
          color: colorScheme.onSurface,
          fontSize: 19,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        contentTextStyle: TextStyle(
          color: colorScheme.onSurfaceVariant,
          fontSize: 14,
          height: 1.45,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaceColor,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: surfaceColor,
        elevation: 0,
        showDragHandle: true,
        dragHandleColor: colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(sheetRadius)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colorScheme.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(controlRadius),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.primary.withValues(alpha: 0.10),
        selectedColor: colorScheme.primary.withValues(alpha: 0.20),
        side: BorderSide(color: colorScheme.primary.withValues(alpha: 0.18)),
        labelStyle: TextStyle(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: 12.5,
        ),
        shape: const StadiumBorder(),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2D3A) : const Color(0xFF1F2430),
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.35)
            : const Color(0xFFF6F7FA),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide(color: colorScheme.error, width: 1.4),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide(color: colorScheme.error, width: 1.6),
        ),
        prefixIconColor: colorScheme.primary,
        suffixIconColor: colorScheme.onSurfaceVariant,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 5, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 13.5,
          height: 1.4,
          fontWeight: FontWeight.w500,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: colorScheme.primary.withValues(alpha: 0.12),
        linearMinHeight: 6,
        borderRadius: BorderRadius.circular(999),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.white;
          }
          return isDark ? Colors.white70 : Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return isDark ? Colors.white24 : const Color(0xFFDDE1E8);
        }),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
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
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(controlRadius),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
          ),
          side: BorderSide(color: colorScheme.primary.withValues(alpha: 0.35)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(controlRadius),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(controlRadius),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        elevation: 2,
        highlightElevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(controlRadius),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surfaceColor,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: cardBorderColor),
        ),
      ),
    );

    return base.copyWith(
        textTheme: _tunedTextTheme(base.textTheme, colorScheme));
  }

  /// Tightens tracking on the large sizes and firms up the weights, which is
  /// most of what makes system UI on Apple platforms read the way it does.
  TextTheme _tunedTextTheme(TextTheme base, ColorScheme colorScheme) {
    final colored = base.apply(
      bodyColor: colorScheme.onSurface,
      displayColor: colorScheme.onSurface,
    );
    return colored.copyWith(
      displayLarge: colored.displayLarge?.copyWith(
        letterSpacing: -1.5,
        fontWeight: FontWeight.w700,
      ),
      displayMedium: colored.displayMedium?.copyWith(
        letterSpacing: -1.1,
        fontWeight: FontWeight.w700,
      ),
      displaySmall: colored.displaySmall?.copyWith(
        letterSpacing: -0.8,
        fontWeight: FontWeight.w700,
      ),
      headlineLarge: colored.headlineLarge?.copyWith(
        letterSpacing: -0.7,
        fontWeight: FontWeight.w700,
      ),
      headlineMedium: colored.headlineMedium?.copyWith(
        letterSpacing: -0.5,
        fontWeight: FontWeight.w700,
      ),
      headlineSmall: colored.headlineSmall?.copyWith(
        letterSpacing: -0.4,
        fontWeight: FontWeight.w700,
      ),
      titleLarge: colored.titleLarge?.copyWith(
        letterSpacing: -0.3,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: colored.titleMedium?.copyWith(
        letterSpacing: -0.2,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: colored.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: colored.bodyLarge?.copyWith(height: 1.45),
      bodyMedium: colored.bodyMedium?.copyWith(height: 1.45),
      labelLarge: colored.labelLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.1,
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

  /// A darker version of an accent, for text that has to sit on a pale tint of
  /// that same accent.
  Color _deepen(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness * 0.62).clamp(0.16, 0.42).toDouble())
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
    if (index < 0 || index >= accentOptions.length) return;
    if (index == _accentColorIndex) return;
    _accentColorIndex = index;
    _invalidateThemes();
    unawaited(_savePreferences());
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    if (mode == _themeMode) return;
    _themeMode = mode;
    unawaited(_savePreferences());
    notifyListeners();
  }
}
