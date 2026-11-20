import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme_provider.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Apple's system colors (dark variants), used for the small icon tiles of a
/// grouped list, like in the iOS Settings app.
abstract final class AppleColors {
  static const blue = Color(0xFF0A84FF);
  static const green = Color(0xFF30D158);
  static const orange = Color(0xFFFF9F0A);
  static const red = Color(0xFFFF453A);
  static const purple = Color(0xFFBF5AF2);
  static const pink = Color(0xFFFF375F);
  static const teal = Color(0xFF40C8E0);
  static const indigo = Color(0xFF5E5CE6);
  static const gray = Color(0xFF8E8E93);
  static const yellow = Color(0xFFFFD60A);
}

/// The selected AtlasSend theme; rebuilds the caller when it changes.
AtlasTheme atlasOf(BuildContext context) => context.watch(atlasThemeProvider.select((s) => s.theme));

/// Copy that only AtlasSend shows (Turkish / English); everything else uses the upstream translations.
String tx(String tr, String en) => LocaleSettings.currentLocale.languageCode == 'tr' ? tr : en;

/// A scrollable page with the theme background, centered on wide windows.
class AtlasScreen extends StatelessWidget {
  final List<Widget> children;
  final double maxWidth;

  const AtlasScreen({required this.children, this.maxWidth = 680, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    return ColoredBox(
      color: theme.bg,
      child: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

/// iOS "large title": 34 pt bold, left aligned, optional trailing actions.
class AtlasLargeTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const AtlasLargeTitle(this.title, {this.trailing, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -0.9, color: theme.text, height: 1.1),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Inset grouped section: an optional small caps header, rounded rows, an optional footer.
class AtlasGroup extends StatelessWidget {
  final String? header;
  final String? footer;
  final List<Widget> children;

  /// Left inset of the separators; rows with an icon tile use the default.
  final double separatorInset;

  const AtlasGroup({required this.children, this.header, this.footer, this.separatorInset = 58, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) {
        rows.add(
          Padding(
            padding: EdgeInsets.only(left: separatorInset),
            child: Container(height: 0.6, color: theme.separator),
          ),
        );
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
              child: Text(
                header!.toUpperCase(),
                style: TextStyle(fontSize: 12.5, color: theme.muted, letterSpacing: 0.2, fontWeight: FontWeight.w500),
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: theme.surface,
              child: Column(children: rows),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
              child: Text(footer!, style: TextStyle(fontSize: 12.5, color: theme.muted, height: 1.35)),
            ),
        ],
      ),
    );
  }
}

/// The colored rounded square in front of a settings row.
class AtlasIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const AtlasIconTile(this.icon, this.color, {this.size = 29, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * 0.24)),
      child: Icon(icon, size: size * 0.62, color: Colors.white),
    );
  }
}

/// One row of a grouped list.
class AtlasRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final bool chevron;
  final bool destructive;
  final VoidCallback? onTap;

  const AtlasRow({
    required this.title,
    this.leading,
    this.subtitle,
    this.value,
    this.trailing,
    this.chevron = false,
    this.destructive = false,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    return AtlasPressable(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 46),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 14)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15.5,
                        color: destructive ? AppleColors.red : theme.text,
                        letterSpacing: -0.2,
                      ),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          style: TextStyle(fontSize: 12.5, color: theme.muted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              if (value != null)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(
                      value!,
                      style: TextStyle(fontSize: 15.5, color: theme.muted, letterSpacing: -0.2),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              if (trailing != null) ...[const SizedBox(width: 10), trailing!],
              if (chevron)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(CupertinoIcons.chevron_right, size: 15, color: theme.muted.withValues(alpha: 0.7)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row with an iOS switch.
class AtlasSwitchRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const AtlasSwitchRow({required this.title, required this.value, required this.onChanged, this.leading, this.subtitle, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    return AtlasRow(
      leading: leading,
      title: title,
      subtitle: subtitle,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: CupertinoSwitch(
        value: value,
        onChanged: onChanged,
        activeTrackColor: theme.accent == Colors.white || theme.accent.computeLuminance() > 0.85 ? AppleColors.green : theme.accent,
      ),
    );
  }
}

/// Dims its child slightly while pressed, like a UITableViewCell.
class AtlasPressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;

  const AtlasPressable({required this.child, this.onTap, this.borderRadius, super.key});

  @override
  State<AtlasPressable> createState() => _AtlasPressableState();
}

class _AtlasPressableState extends State<AtlasPressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null) {
      return widget.child;
    }
    final theme = atlasOf(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Duration(milliseconds: _down ? 0 : 220),
          decoration: BoxDecoration(color: _down ? theme.pressed : Colors.transparent, borderRadius: widget.borderRadius),
          child: widget.child,
        ),
      ),
    );
  }
}

/// iOS style action sheet; returns the index of the chosen action or null.
Future<int?> showAtlasActionSheet(BuildContext context, {required String title, required List<String> actions, int? selected}) {
  return showCupertinoModalPopup<int>(
    context: context,
    builder: (context) => CupertinoActionSheet(
      title: Text(title),
      actions: [
        for (var i = 0; i < actions.length; i++)
          CupertinoActionSheetAction(
            isDefaultAction: i == selected,
            onPressed: () => Navigator.of(context).pop(i),
            child: Text(actions[i]),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(t.general.cancel),
      ),
    ),
  );
}
