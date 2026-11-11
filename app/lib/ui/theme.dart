import 'package:flutter/material.dart';

/// Deep harbour teal.
const Color seedColor = Color(0xFF0E6E78);

/// One colour per angler, used on pins, chips and counts everywhere.
const Map<String, Color> _anglerColors = {
  'Jase': Color(0xFFF97316), // orange
  'Matt': Color(0xFFD946EF), // fuchsia
};
const List<Color> _spareColors = [Color(0xFF22C55E), Color(0xFFEAB308), Color(0xFF3B82F6)];

Color anglerColor(String angler) {
  final c = _anglerColors[angler];
  if (c != null) return c;
  return _spareColors[angler.hashCode.abs() % _spareColors.length];
}

String colorHex(Color c) {
  final v = c.toARGB32() & 0xFFFFFF;
  return '#${v.toRadixString(16).padLeft(6, '0')}';
}

/// Route speed shading, slow to fast (km/h stops). Kept clear of the angler colours.
const List<(double, Color)> speedRamp = [
  (0, Color(0xFF6366F1)), // indigo: drifting
  (5, Color(0xFF0EA5E9)), // sky: trolling
  (14, Color(0xFF22D3EE)), // cyan
  (24, Color(0xFFA3E635)), // lime: running
  (35, Color(0xFFFDE047)), // yellow: flat out
];

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      margin: EdgeInsets.zero,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: scheme.surfaceTint,
      centerTitle: false,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      extendedTextStyle: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        textStyle: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
    }),
    sliderTheme: base.sliderTheme.copyWith(
      trackHeight: 4,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
    ),
  );
}
