import 'package:flutter/material.dart';

/// ألوان التطبيق
class AppColors {
  AppColors._();

  static const bg = Color(0xFF0A0E16);
  static const surface = Color(0xFF121826);
  static const surfaceHigh = Color(0xFF1A2335);
  static const outline = Color(0xFF263248);
  static const accent = Color(0xFF2DD4BF);
  static const onAccent = Color(0xFF04201D);
  static const warn = Color(0xFFFBBF24);
  static const danger = Color(0xFFF87171);
  static const textDim = Color(0xFF94A3B8);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    onPrimary: AppColors.onAccent,
    surface: AppColors.surface,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: AppColors.accent,
      inactiveTrackColor: AppColors.outline,
      thumbColor: AppColors.accent,
      overlayColor: AppColors.accent.withValues(alpha: 0.15),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}
