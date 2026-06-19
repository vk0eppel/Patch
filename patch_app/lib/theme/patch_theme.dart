import 'package:flutter/material.dart';

/// PATCH design tokens — dark, high-contrast, stage-readable.
class PatchTheme {
  PatchTheme._();

  // ── Palette ───────────────────────────────────────────────────────────────
  static const background    = Color(0xFF0D0D0D);
  static const surface       = Color(0xFF1A1A1A);
  static const surfaceHigh   = Color(0xFF242424);
  static const border        = Color(0xFF2E2E2E);

  static const textPrimary   = Color(0xFFEEEEEE);
  static const textSecondary = Color(0xFF888888);
  static const textMuted     = Color(0xFF555555);

  static const accent        = Color(0xFF00B4FF); // PATCH blue
  static const critical      = Color(0xFFE53935); // red
  static const warning       = Color(0xFFFFB300); // amber
  static const success       = Color(0xFF43A047); // green

  /// The synthetic ALL / crew-wide broadcast tab. Neutral light-grey on purpose —
  /// ALL isn't a department, and a real colour (the old accent blue) clashed with
  /// the RF channel. Softer than pure white so it doesn't glare next to the vivid
  /// channel dots. Used for the ALL tab dot, its header label, and the broadcast flash.
  static const broadcast     = Color(0xFFCCCCCC); // soft light-grey

  // ── Layout ────────────────────────────────────────────────────────────────
  /// Unified header height for all top-of-screen sections (channel strip,
  /// message area header, shortcuts panel, peers panel).
  static const double headerHeight = 48.0;

  /// Unified footer height for the bottom-of-screen row in each side-by-side
  /// column (channel strip's identity chip, message area's input bar, peers
  /// panel's "Clear inactive" button) — keeps their top dividers aligned
  /// across columns, the same way [headerHeight] aligns the top ones. Equal
  /// to headerHeight so the header/footer rows match too.
  static const double footerHeight = headerHeight;

  // ── Typography ────────────────────────────────────────────────────────────
  /// Large, readable timestamp / label for stage desk use
  static const fontSizeLarge  = 18.0;
  static const fontSizeMedium = 15.0;
  static const fontSizeSmall  = 12.0;

  static ThemeData dark() {
    return ThemeData.dark().copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.dark(
        surface: surface,
        primary: accent,
        secondary: accent,
        error: critical,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: textPrimary,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: fontSizeLarge,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5,
        ),
      ),
      dividerColor: border,
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: textPrimary, fontSize: fontSizeMedium),
        bodyMedium: TextStyle(color: textPrimary, fontSize: fontSizeSmall),
        labelSmall: TextStyle(color: textSecondary, fontSize: fontSizeSmall),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        hintStyle: const TextStyle(color: textMuted),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.black,
          textStyle: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.8),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }
}
