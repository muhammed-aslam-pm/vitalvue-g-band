import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Centralized design tokens and theme matching the VitalVue dark navy UI mockup.
class AppColors {
  AppColors._();

  // ── Core Brand & Canvas ────────────────────────────────────────────────────
  static const Color background = Color(0xFF060B18); // Deep midnight navy canvas
  static const Color surface = Color(0xFF0D1936); // Primary card & surface container
  static const Color surfaceElevated = Color(0xFF101F42); // Elevated containers & pill backgrounds
  static const Color surfaceHighlight = Color(0xFF14244E); // Active list highlights / rows

  // ── Card & Border Accents ──────────────────────────────────────────────────
  static const Color cardBorder = Color(0xFF17264E); // Standard subtle card stroke
  static const Color cardBorderLight = Color(0xFF1E3260); // Hover/focused stroke

  // ── Primary & Brand Accents ────────────────────────────────────────────────
  static const Color primary = Color(0xFF1E6BFF); // Vibrant royal blue
  static const Color primaryGlow = Color(0x331E6BFF); // 20% alpha glow

  // ── Clinical & Vital Signs Accents ─────────────────────────────────────────
  static const Color cyan = Color(0xFF00D2D3); // SpO2, Respiratory, gauge tracks
  static const Color green = Color(0xFF00E676); // Normal, Stable, Within baseline
  static const Color red = Color(0xFFFF3B5C); // Heart Rate, Critical deterioration, Alerts
  static const Color amber = Color(0xFFF59E0B); // Blood Pressure, Warnings, Moderate stress
  static const Color purple = Color(0xFFA855F7); // Body Temp, HRV, Insights

  // ── Typography ─────────────────────────────────────────────────────────────
  static const Color textPrimary = Color(0xFFFFFFFF); // High emphasis title & values
  static const Color textSecondary = Color(0xFF8FA0C0); // Medium emphasis labels & subtitles
  static const Color textMuted = Color(0xFF5A6E94); // Low emphasis hints & captions
}

class AppTheme {
  AppTheme._();

  static ThemeData get darkTheme {
    final baseTextTheme = GoogleFonts.interTextTheme(ThemeData.dark().textTheme);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        onPrimary: Colors.white,
        secondary: AppColors.cyan,
        onSecondary: Colors.white,
        tertiary: AppColors.green,
        onTertiary: Colors.white,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
        error: AppColors.red,
        onError: Colors.white,
        outline: AppColors.cardBorder,
        surfaceContainerHighest: AppColors.surfaceElevated,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: AppColors.textPrimary,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        elevation: 16,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        modalBackgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      dividerColor: AppColors.cardBorder,
      textTheme: baseTextTheme.copyWith(
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: baseTextTheme.bodyLarge?.copyWith(
          color: AppColors.textPrimary,
        ),
        bodyMedium: baseTextTheme.bodyMedium?.copyWith(
          color: AppColors.textSecondary,
        ),
        bodySmall: baseTextTheme.bodySmall?.copyWith(
          color: AppColors.textMuted,
        ),
      ),
    );
  }
}
