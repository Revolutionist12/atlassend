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

/// iOS 26 corner radii (continuous corners), shared by the AtlasSend widgets.
const kAtlasGroupRadius = 22.0; // inset grouped sections, cards
const kAtlasAlertRadius = 28.0; // alerts / dialogs
const kAtlasSheetRadius = 34.0; // sheets
const kAtlasFieldRadius = 12.0; // text fields

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

  final border = OutlineInputBorder(borderRadius: BorderRadius.circular(kAtlasFieldRadius), borderSide: BorderSide.none);
  // iOS 26 shapes: continuous (superellipse) corners, capsule buttons.
  const capsule = StadiumBorder();
  RoundedSuperellipseBorder squircle(double r) => RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(r));
  const buttonPadding = EdgeInsets.symmetric(horizontal: 22, vertical: 14);
  const buttonText = TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: -0.3);

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
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: squircle(kAtlasGroupRadius),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.surface,
      elevation: 0,
      shape: squircle(kAtlasAlertRadius),
      titleTextStyle: TextStyle(fontFamily: 'Inter', fontSize: 17, fontWeight: FontWeight.w600, color: t.text, letterSpacing: -0.4),
      contentTextStyle: TextStyle(fontFamily: 'Inter', fontSize: 14.5, color: t.text, height: 1.35),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.surface,
      elevation: 0,
      showDragHandle: true,
      dragHandleColor: t.muted.withValues(alpha: 0.5),
      shape: const RoundedSuperellipseBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(kAtlasSheetRadius))),
    ),
    listTileTheme: ListTileThemeData(
      shape: squircle(14),
      iconColor: t.accent,
      titleTextStyle: TextStyle(fontFamily: 'Inter', fontSize: 15.5, color: t.text, letterSpacing: -0.2),
      subtitleTextStyle: TextStyle(fontFamily: 'Inter', fontSize: 12.5, color: t.muted),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: capsule,
      backgroundColor: t.isDark ? const Color(0xFF2C2C2E) : const Color(0xFF1C1C1E),
      contentTextStyle: const TextStyle(fontFamily: 'Inter', fontSize: 14.5, color: Colors.white),
      elevation: 0,
    ),
    popupMenuTheme: PopupMenuThemeData(color: t.surface, elevation: 6, shape: squircle(14)),
    chipTheme: ChipThemeData(shape: capsule, side: BorderSide.none, backgroundColor: t.text.withValues(alpha: 0.08)),
    segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(shape: capsule)),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: t.accent)),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: t.accent,
      foregroundColor: t.onAccent,
      elevation: 0,
      highlightElevation: 0,
      shape: capsule,
    ),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {for (final p in TargetPlatform.values) p: const CupertinoPageTransitionsBuilder()},
    ),
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
        shape: capsule,
        padding: buttonPadding,
        textStyle: buttonText,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        shape: capsule,
        padding: buttonPadding,
        textStyle: buttonText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: t.accent, shape: capsule, textStyle: buttonText.copyWith(fontWeight: FontWeight.w500)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        // iOS "gray" button: tinted fill, no outline.
        foregroundColor: t.accent,
        backgroundColor: t.text.withValues(alpha: t.isDark ? 0.10 : 0.06),
        side: BorderSide.none,
        shape: capsule,
        padding: buttonPadding,
        textStyle: buttonText,
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
