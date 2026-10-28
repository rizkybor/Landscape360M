import 'package:flutter/material.dart';

// Palette of the web app (src/index.css): forest, gold, sand, brick, ember and ink

abstract final class L360Colors {
  static const ink = Color(0xFF1A2214);

  static const forest50 = Color(0xFFF2F6EE);
  static const forest100 = Color(0xFFE2EBD8);
  static const forest300 = Color(0xFF9EBB84);
  static const forest500 = Color(0xFF4D7537);
  static const forest600 = Color(0xFF365B25);
  static const forest700 = Color(0xFF284A1B);
  static const forest900 = Color(0xFF183C0C);

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
  static const sand500 = Color(0xFF7F7965);
  static const sand700 = Color(0xFF45423A);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: L360Colors.forest700,
    primary: L360Colors.forest700,
    onPrimary: Colors.white,
    secondary: L360Colors.gold500,
    onSecondary: L360Colors.ink,
    tertiary: L360Colors.ember500,
    error: L360Colors.brick500,
    surface: Colors.white,
    onSurface: L360Colors.ink,
  );

  return ThemeData(
    colorScheme: scheme,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: L360Colors.sand50,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: L360Colors.ink,
      elevation: 0,
      scrolledUnderElevation: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: L360Colors.sand200),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: L360Colors.forest700,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
  );
}
