import 'package:flutter/material.dart';

// Palette of the web app (src/index.css): forest, gold, sand, brick, ember and ink

abstract final class L360Colors {
  static const ink = Color(0xFF1A2214);

  static const forest50 = Color(0xFFF2F6EE);
  static const forest100 = Color(0xFFE2EBD8);
  static const forest200 = Color(0xFFC5D7B2);
  static const forest300 = Color(0xFF9EBB84);
  static const forest500 = Color(0xFF4D7537);
  static const forest600 = Color(0xFF365B25);
  static const forest700 = Color(0xFF284A1B);
  static const forest800 = Color(0xFF1E3C13);
  static const forest900 = Color(0xFF183C0C);

  static const gold50 = Color(0xFFFDF8EA);
  static const gold100 = Color(0xFFFAEFCC);
  static const gold400 = Color(0xFFE9B640);
  static const gold500 = Color(0xFFD49B22);
  static const gold700 = Color(0xFF8A5E14);

  static const ember500 = Color(0xFFE46C24);
  static const ember600 = Color(0xFFC8551A);

  static const brick50 = Color(0xFFFDF1F0);
  static const brick500 = Color(0xFFB4302A);
  static const brick600 = Color(0xFF962620);

  static const sand50 = Color(0xFFFAF8F3);
  static const sand100 = Color(0xFFF3F0E7);
  static const sand200 = Color(0xFFE7E2D4);
  static const sand300 = Color(0xFFD3CCB8);
  static const sand400 = Color(0xFFA9A28B);
  static const sand500 = Color(0xFF7F7965);
  static const sand600 = Color(0xFF5E5A4A);
  static const sand700 = Color(0xFF45423A);
}

/// Spacing and radii used across the app
abstract final class L360 {
  static const radius = 16.0;
  static const radiusSmall = 12.0;
  static const gutter = 16.0;

  /// Panels and full screens on tablets keep about a phone's width
  static const panelMaxWidth = 560.0;

  /// Minimum touch target (Apple HIG 44 pt, Material 48 dp)
  static const touch = 44.0;

  static const shadow = [BoxShadow(color: Color(0x26000000), blurRadius: 16, offset: Offset(0, 4))];
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: L360Colors.forest700,
    primary: L360Colors.forest700,
    onPrimary: Colors.white,
    primaryContainer: L360Colors.forest100,
    onPrimaryContainer: L360Colors.forest800,
    secondary: L360Colors.gold500,
    onSecondary: L360Colors.ink,
    tertiary: L360Colors.ember500,
    error: L360Colors.brick500,
    surface: Colors.white,
    onSurface: L360Colors.ink,
    onSurfaceVariant: L360Colors.sand600,
    outline: L360Colors.sand300,
    outlineVariant: L360Colors.sand200,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: L360Colors.sand50,
    surfaceContainer: L360Colors.sand100,
  );

  const base = TextTheme(
    headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.4),
    titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.3),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: -0.1),
    titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontSize: 16, height: 1.4),
    bodyMedium: TextStyle(fontSize: 14, height: 1.4),
    bodySmall: TextStyle(fontSize: 12, height: 1.35, color: L360Colors.sand600),
    labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.6),
  );

  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(L360.radiusSmall),
    borderSide: const BorderSide(color: L360Colors.sand200),
  );

  return ThemeData(
    colorScheme: scheme,
    fontFamily: 'Inter',
    textTheme: base.apply(bodyColor: L360Colors.ink, displayColor: L360Colors.ink),
    scaffoldBackgroundColor: L360Colors.sand50,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: L360Colors.sand50,
      surfaceTintColor: Colors.transparent,
      foregroundColor: L360Colors.ink,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      titleTextStyle: TextStyle(fontFamily: 'Inter', fontSize: 17, fontWeight: FontWeight.w600, color: L360Colors.ink),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(L360.radius),
        side: const BorderSide(color: L360Colors.sand200),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: L360Colors.forest700,
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
      minVerticalPadding: 12,
    ),
    dividerTheme: const DividerThemeData(color: L360Colors.sand200, thickness: 0.6, space: 0.6),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(borderSide: const BorderSide(color: L360Colors.forest600, width: 1.6)),
      errorBorder: inputBorder.copyWith(borderSide: const BorderSide(color: L360Colors.brick500)),
      prefixIconColor: L360Colors.sand500,
      labelStyle: const TextStyle(color: L360Colors.sand600),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: L360Colors.forest700,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(50),
        textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(L360.radiusSmall)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: L360Colors.forest700,
        minimumSize: const Size.fromHeight(50),
        side: const BorderSide(color: L360Colors.sand300),
        textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(L360.radiusSmall)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: L360Colors.forest700,
        textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
      ),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: L360Colors.forest700,
      inactiveTrackColor: L360Colors.sand200,
      thumbColor: Colors.white,
      overlayColor: Color(0x1F284A1B),
      trackHeight: 4,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: L360Colors.ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(L360.radiusSmall)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: L360Colors.sand300,
    ),
  );
}
