import 'dart:ui';

/// One AtlasSend color theme. Role order: bg / surface / text / muted / accent.
class AtlasTheme {
  final String id;
  final String label;
  final Color bg;
  final Color surface;
  final Color text;
  final Color muted;
  final Color accent;

  const AtlasTheme({
    required this.id,
    required this.label,
    required this.bg,
    required this.surface,
    required this.text,
    required this.muted,
    required this.accent,
  });
}

/// The built-in themes. The settings section to pick one comes in phase 2;
/// until then [atlasDefaultTheme] is used everywhere.
const kAtlasThemes = <AtlasTheme>[
  AtlasTheme(
    id: 'obsidian',
    label: 'Obsidyen',
    bg: Color(0xFF000000),
    surface: Color(0xFF141414),
    text: Color(0xFFFAFAFA),
    muted: Color(0xFF6B6B6B),
    accent: Color(0xFFFFFFFF),
  ),
  AtlasTheme(
    id: 'pro_blue',
    label: 'Pro mavi',
    bg: Color(0xFF000000),
    surface: Color(0xFF1D1D1F),
    text: Color(0xFFF5F5F7),
    muted: Color(0xFF86868B),
    accent: Color(0xFF2997FF),
  ),
  AtlasTheme(
    id: 'silver',
    label: 'Gümüş',
    bg: Color(0xFFD7D9DC),
    surface: Color(0xFFECEEF0),
    text: Color(0xFF141619),
    muted: Color(0xFF6A6F76),
    accent: Color(0xFF2A2D31),
  ),
  AtlasTheme(
    id: 'copper_night',
    label: 'Bakır gece',
    bg: Color(0xFF15110D),
    surface: Color(0xFF231C16),
    text: Color(0xFFF3ECE4),
    muted: Color(0xFF9A8B7C),
    accent: Color(0xFFD08C4E),
  ),
  AtlasTheme(
    id: 'ivory',
    label: 'Fildişi',
    bg: Color(0xFFFAF8F3),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF22201C),
    muted: Color(0xFF8A857B),
    accent: Color(0xFF2F5D50),
  ),
  AtlasTheme(
    id: 'ice',
    label: 'Buz',
    bg: Color(0xFFEEF3F7),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF0F1B2A),
    muted: Color(0xFF6F8196),
    accent: Color(0xFF0A84FF),
  ),
  AtlasTheme(
    id: 'laser_green',
    label: 'Lazer yeşil',
    bg: Color(0xFF050807),
    surface: Color(0xFF0E1411),
    text: Color(0xFFE8F2EC),
    muted: Color(0xFF62756A),
    accent: Color(0xFF39FF88),
  ),
  AtlasTheme(
    id: 'coffee',
    label: 'Kahve',
    bg: Color(0xFF1F1611),
    surface: Color(0xFF2E221B),
    text: Color(0xFFF2E8DF),
    muted: Color(0xFF9C8878),
    accent: Color(0xFFD4A373),
  ),
  AtlasTheme(
    id: 'desert',
    label: 'Çöl',
    bg: Color(0xFFEDE0CC),
    surface: Color(0xFFF7EFE2),
    text: Color(0xFF3A2E20),
    muted: Color(0xFF9A8A72),
    accent: Color(0xFFC17F3E),
  ),
];

/// "Bakır gece".
AtlasTheme get atlasDefaultTheme => kAtlasThemes.firstWhere((theme) => theme.id == 'copper_night');
