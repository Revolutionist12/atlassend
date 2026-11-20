import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/atlassend/atlas_identity.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme_provider.dart';
import 'package:localsend_app/atlassend/ui/atlas_widgets.dart';
import 'package:localsend_app/atlassend/ui/receive_screen.dart';
import 'package:localsend_app/atlassend/ui/send_screen.dart';
import 'package:localsend_app/atlassend/ui/settings_screen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/home_page.dart';

/// Wide windows get a sidebar (like macOS apps), narrow ones a tab bar (like iOS apps).
const _sidebarBreakpoint = 720.0;

extension on HomeTab {
  IconData get outlineIcon => switch (this) {
    HomeTab.receive => CupertinoIcons.arrow_down_circle,
    HomeTab.send => CupertinoIcons.paperplane,
    HomeTab.settings => CupertinoIcons.gear,
  };

  IconData get filledIcon => switch (this) {
    HomeTab.receive => CupertinoIcons.arrow_down_circle_fill,
    HomeTab.send => CupertinoIcons.paperplane_fill,
    HomeTab.settings => CupertinoIcons.gear_solid,
  };
}

/// The AtlasSend home: replaces the content of the upstream [HomePage], which
/// keeps owning the tab state, the start-up logic and drag & drop.
class AtlasShell extends StatelessWidget {
  final PageController controller;
  final HomeTab currentTab;
  final ValueChanged<HomeTab> onSelect;
  final bool dropIndicator;

  const AtlasShell({
    required this.controller,
    required this.currentTab,
    required this.onSelect,
    required this.dropIndicator,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    final pages = Stack(
      children: [
        // A PageView (not an IndexedStack) because the upstream tab controller jumps a PageController.
        PageView(
          controller: controller,
          physics: const NeverScrollableScrollPhysics(),
          children: const [AtlasReceiveScreen(), AtlasSendScreen(), AtlasSettingsScreen()],
        ),
        if (dropIndicator) const _DropIndicator(),
      ],
    );

    return Scaffold(
      backgroundColor: theme.bg,
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= _sidebarBreakpoint) {
            return Row(
              children: [
                _Sidebar(currentTab: currentTab, onSelect: onSelect),
                Container(width: 0.6, color: theme.separator),
                Expanded(child: pages),
              ],
            );
          }
          return Column(
            children: [
              Expanded(child: pages),
              _TabBar(currentTab: currentTab, onSelect: onSelect),
            ],
          );
        },
      ),
    );
  }
}

String _label(HomeTab tab) => switch (tab) {
  HomeTab.receive => t.receiveTab.title,
  HomeTab.send => t.sendTab.title,
  HomeTab.settings => t.settingsTab.title,
};

class _TabBar extends StatelessWidget {
  final HomeTab currentTab;
  final ValueChanged<HomeTab> onSelect;

  const _TabBar({required this.currentTab, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surface,
        border: Border(top: BorderSide(color: theme.separator, width: 0.6)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 54,
          child: Row(
            children: [
              for (final tab in HomeTab.values)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onSelect(tab),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(tab == currentTab ? tab.filledIcon : tab.outlineIcon, size: 25, color: tab == currentTab ? theme.accent : theme.muted),
                        const SizedBox(height: 3),
                        Text(
                          _label(tab),
                          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w500, color: tab == currentTab ? theme.accent : theme.muted),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final HomeTab currentTab;
  final ValueChanged<HomeTab> onSelect;

  const _Sidebar({required this.currentTab, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    return Container(
      width: 220,
      color: theme.surface,
      padding: const EdgeInsets.fromLTRB(12, 22, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 22),
            child: Row(
              children: [
                AtlasIconTile(CupertinoIcons.paperplane_fill, theme.accent, size: 26),
                const SizedBox(width: 10),
                Text(
                  kAtlasAppName,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: theme.text, letterSpacing: -0.4),
                ),
              ],
            ),
          ),
          for (final tab in HomeTab.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: AtlasPressable(
                onTap: () => onSelect(tab),
                borderRadius: BorderRadius.circular(8),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: tab == currentTab ? theme.accent.withValues(alpha: theme.isDark ? 0.22 : 0.16) : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(tab == currentTab ? tab.filledIcon : tab.outlineIcon, size: 19, color: tab == currentTab ? theme.accent : theme.muted),
                      const SizedBox(width: 10),
                      Text(
                        _label(tab),
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: tab == currentTab ? FontWeight.w600 : FontWeight.w500,
                          color: theme.text,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DropIndicator extends StatelessWidget {
  const _DropIndicator();

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    return Positioned.fill(
      child: ColoredBox(
        color: theme.bg.withValues(alpha: 0.94),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: theme.accent, width: 2),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.tray_arrow_down_fill, size: 64, color: theme.accent),
                  const SizedBox(height: 16),
                  Text(
                    tx('Göndermek için bırak', 'Drop to send'),
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: theme.text, letterSpacing: -0.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
