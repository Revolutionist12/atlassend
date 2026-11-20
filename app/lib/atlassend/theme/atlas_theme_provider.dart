import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _themeKey = 'atlas_theme';
const _frameKey = 'atlas_frame_color'; // ARGB int; absent = the theme's accent

/// Set once in main() after the persistence layer is initialized.
final atlasPrefsProvider = Provider<SharedPreferences>((ref) => throw 'atlasPrefsProvider not initialized');

final atlasThemeProvider = NotifierProvider<AtlasThemeNotifier, AtlasThemeState>((ref) => AtlasThemeNotifier());

class AtlasThemeState {
  final AtlasTheme theme;

  /// Color of the overlay card frame and the screen edge glow. `null` follows [AtlasTheme.accent].
  final Color? customFrame;

  const AtlasThemeState({required this.theme, required this.customFrame});

  Color get frame => customFrame ?? theme.accent;
}

class AtlasThemeNotifier extends Notifier<AtlasThemeState> {
  @override
  AtlasThemeState init() {
    final prefs = ref.read(atlasPrefsProvider);
    final id = prefs.getString(_themeKey);
    final frame = prefs.getInt(_frameKey);
    return AtlasThemeState(
      theme: kAtlasThemes.firstWhere((t) => t.id == id, orElse: () => atlasDefaultTheme),
      customFrame: frame == null ? null : Color(frame),
    );
  }

  Future<void> setTheme(AtlasTheme theme) async {
    state = AtlasThemeState(theme: theme, customFrame: state.customFrame);
    await ref.read(atlasPrefsProvider).setString(_themeKey, theme.id);
  }

  /// `null` resets the frame to the theme's accent.
  Future<void> setFrame(Color? color) async {
    state = AtlasThemeState(theme: state.theme, customFrame: color);
    final prefs = ref.read(atlasPrefsProvider);
    if (color == null) {
      await prefs.remove(_frameKey);
    } else {
      await prefs.setInt(_frameKey, color.toARGB32());
    }
  }
}

extension AtlasThemeColors on AtlasTheme {
  bool get isDark => bg.computeLuminance() < 0.4;

  Brightness get brightness => isDark ? Brightness.dark : Brightness.light;

  /// Text / icon color on top of [accent].
  Color get onAccent => accent.computeLuminance() > 0.5 ? const Color(0xFF111111) : Colors.white;

  /// Hairline between rows of a grouped list.
  Color get separator => muted.withValues(alpha: isDark ? 0.28 : 0.22);

  /// Background of a pressed row.
  Color get pressed => text.withValues(alpha: isDark ? 0.08 : 0.06);
}

const _fontFallback = ['Segoe UI', 'Yu Gothic UI', 'Malgun Gothic', 'Microsoft YaHei UI', 'Noto Sans'];

/// Material theme derived from an [AtlasTheme], so the upstream pages that are
/// not redesigned yet (dialogs, receive / progress pages) still match.
ThemeData atlasMaterialTheme(AtlasTheme t) {
  final scheme = ColorScheme(
    brightness: t.brightness,
    primary: t.accent,
    onPrimary: t.onAccent,
    secondary: t.accent,
    onSecondary: t.onAccent,
    tertiary: t.accent,
    onTertiary: t.onAccent,
    error: const Color(0xFFFF453A),
    onError: Colors.white,
    surface: t.bg,
    onSurface: t.text,
    onSurfaceVariant: t.muted,
    surfaceContainerLowest: t.bg,
    surfaceContainerLow: t.surface,
    surfaceContainer: t.surface,
    surfaceContainerHigh: t.surface,
    surfaceContainerHighest: t.surface,
    secondaryContainer: Color.alphaBlend(t.accent.withValues(alpha: 0.16), t.surface),
    onSecondaryContainer: t.text,
    primaryContainer: Color.alphaBlend(t.accent.withValues(alpha: 0.22), t.surface),
    onPrimaryContainer: t.text,
    outline: t.separator,
    outlineVariant: t.separator,
    surfaceTint: Colors.transparent,
    shadow: Colors.black,
  );

  final border = OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: t.brightness,
    scaffoldBackgroundColor: t.bg,
    canvasColor: t.bg,
    cardColor: t.surface,
    dividerColor: t.separator,
    fontFamily: 'Inter',
    fontFamilyFallback: _fontFallback,
    visualDensity: VisualDensity.standard,
    splashFactory: NoSplash.splashFactory,
    highlightColor: t.pressed,
    appBarTheme: AppBarTheme(
      backgroundColor: t.bg,
      foregroundColor: t.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: !checkPlatformIsDesktop(),
      titleTextStyle: TextStyle(fontFamily: 'Inter', fontSize: 17, fontWeight: FontWeight.w600, color: t.text, letterSpacing: -0.4),
    ),
    cardTheme: CardThemeData(
      color: t.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: t.surface),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.isDark ? t.text.withValues(alpha: 0.08) : t.text.withValues(alpha: 0.05),
      border: border,
      enabledBorder: border,
      focusedBorder: border,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: t.accent)),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: t.accent,
        side: BorderSide(color: t.separator),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.accent : t.muted.withValues(alpha: 0.35)),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: t.accent, linearTrackColor: t.text.withValues(alpha: 0.1)),
    cupertinoOverrideTheme: CupertinoThemeData(primaryColor: t.accent, brightness: t.brightness, scaffoldBackgroundColor: t.bg),
  );
}
