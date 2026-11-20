import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme_provider.dart';
import 'package:localsend_app/atlassend/ui/atlas_widgets.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/receive_history_page.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/animation_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/ip_helper.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

enum _QuickSave { off, favorites, everyone }

class AtlasReceiveScreen extends StatelessWidget {
  const AtlasReceiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    final ref = context.ref;
    final alias = context.watch(settingsProvider.select((s) => s.alias));
    final quickSave = context.watch(
      settingsProvider.select(
        (s) => s.quickSave
            ? _QuickSave.everyone
            : s.quickSaveFromFavorites
            ? _QuickSave.favorites
            : _QuickSave.off,
      ),
    );
    final server = context.watch(serverProvider);
    final localIps = context.watch(localIpProvider.select((s) => s.localIps));
    final online = server != null;
    final ids = localIps.map((ip) => '#${ip.visualId}').toSet().join(' ');

    String quickSaveLabel(_QuickSave mode) => switch (mode) {
      _QuickSave.off => t.general.off,
      _QuickSave.favorites => t.general.quickSaveFromFavorites,
      _QuickSave.everyone => tx('Herkes', 'Everyone'),
    };

    return AtlasScreen(
      children: [
        AtlasLargeTitle(t.receiveTab.title),
        const SizedBox(height: 18),
        Center(child: _Beacon(online: online)),
        const SizedBox(height: 22),
        Text(
          server?.alias ?? alias,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: -0.7, color: theme.text),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: online ? AppleColors.green : AppleColors.gray, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Text(
              online ? tx('Alıma hazır', 'Ready to receive') : t.general.offline,
              style: TextStyle(fontSize: 14.5, color: theme.muted),
            ),
            if (online && ids.isNotEmpty) Text('  ·  $ids', style: TextStyle(fontSize: 14.5, color: theme.muted)),
          ],
        ),
        const SizedBox(height: 34),
        AtlasGroup(
          footer: tx(
            'Aynı Wi‑Fi ağındaki cihazlar seni bu adla görür. “Favoriler” seçiliyken yalnızca favori cihazlarından gelen dosyalar sormadan kaydedilir.',
            'Devices on the same Wi‑Fi see you under this name. With “Favorites”, only files from your favorite devices are saved without asking.',
          ),
          children: [
            AtlasRow(
              leading: const AtlasIconTile(CupertinoIcons.bolt_fill, AppleColors.orange),
              title: t.general.quickSave,
              value: quickSaveLabel(quickSave),
              chevron: true,
              onTap: () async {
                final choice = await showAtlasActionSheet(
                  context,
                  title: t.general.quickSave,
                  actions: _QuickSave.values.map(quickSaveLabel).toList(),
                  selected: quickSave.index,
                );
                if (choice == null) {
                  return;
                }
                final settings = ref.notifier(settingsProvider);
                switch (_QuickSave.values[choice]) {
                  case _QuickSave.off:
                    await settings.setQuickSave(false);
                    await settings.setQuickSaveFromFavorites(false);
                  case _QuickSave.favorites:
                    await settings.setQuickSave(false);
                    await settings.setQuickSaveFromFavorites(true);
                  case _QuickSave.everyone:
                    await settings.setQuickSaveFromFavorites(false);
                    await settings.setQuickSave(true);
                }
              },
            ),
            AtlasRow(
              leading: const AtlasIconTile(CupertinoIcons.clock_fill, AppleColors.blue),
              title: t.receiveHistoryPage.title,
              chevron: true,
              onTap: () async => context.push(() => const ReceiveHistoryPage()),
            ),
            AtlasRow(
              leading: const AtlasIconTile(CupertinoIcons.globe, AppleColors.purple),
              title: t.receiveTab.link,
              chevron: true,
              onTap: () async => context.push(() => const WebSharePage()),
            ),
          ],
        ),
      ],
    );
  }
}

/// The device glyph in a soft accent disc, with rings that pulse outward while
/// the device is visible on the network.
class _Beacon extends StatefulWidget {
  final bool online;

  const _Beacon({required this.online});

  @override
  State<_Beacon> createState() => _BeaconState();
}

class _BeaconState extends State<_Beacon> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    final animations = context.watch(animationProvider);
    final active = context.watch(homePageControllerProvider.select((s) => s.currentTab)) == HomeTab.receive;
    final run = widget.online && animations && active;
    if (run && !_pulse.isAnimating) {
      // ignore: discarded_futures
      _pulse.repeat();
    } else if (!run && _pulse.isAnimating) {
      _pulse.stop();
    }

    const disc = 118.0;
    return SizedBox(
      width: 220,
      height: 220,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) => CustomPaint(
          painter: _RingsPainter(progress: run ? _pulse.value : 0, color: theme.accent, visible: run, inner: disc / 2),
          child: child,
        ),
        child: Center(
          child: Container(
            width: disc,
            height: disc,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: widget.online
                    ? [Color.lerp(theme.accent, Colors.white, 0.18)!, theme.accent]
                    : [theme.muted.withValues(alpha: 0.6), theme.muted.withValues(alpha: 0.4)],
              ),
              boxShadow: [
                if (widget.online) BoxShadow(color: theme.accent.withValues(alpha: 0.35), blurRadius: 30, offset: const Offset(0, 10)),
              ],
            ),
            child: Icon(
              checkPlatformIsDesktop() ? CupertinoIcons.desktopcomputer : CupertinoIcons.device_phone_portrait,
              size: 50,
              color: widget.online ? theme.onAccent : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool visible;
  final double inner;

  _RingsPainter({required this.progress, required this.color, required this.visible, required this.inner});

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) {
      return;
    }
    final center = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    for (var i = 0; i < 2; i++) {
      final p = (progress + i * 0.5) % 1.0;
      final radius = inner + (outer - inner) * Curves.easeOut.transform(p);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color.withValues(alpha: 0.45 * (1 - p)),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.progress != progress || old.visible != visible || old.color != color;
}
