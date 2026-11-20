import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/atlassend/atlas_identity.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme_provider.dart';
import 'package:localsend_app/atlassend/ui/atlas_widgets.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/about/about_page.dart';
import 'package:localsend_app/pages/tabs/settings_tab.dart';
import 'package:localsend_app/pages/tabs/settings_tab_controller.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/version_provider.dart';
import 'package:localsend_app/util/i18n.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// Frame colors offered besides "follow the theme": the accents of all themes plus a few Apple colors.
final _frameChoices = <Color>{
  for (final theme in kAtlasThemes) theme.accent,
  AppleColors.pink,
  AppleColors.purple,
  AppleColors.red,
}.toList();

class AtlasSettingsScreen extends StatelessWidget {
  const AtlasSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ViewModelBuilder(
      provider: (ref) => settingsTabControllerProvider,
      builder: (context, vm) {
        final theme = atlasOf(context);
        final ref = context.ref;
        final themeState = context.watch(atlasThemeProvider);
        final settings = vm.settings;
        final server = vm.serverState;
        final version = context.watch(versionProvider).data?.version;

        return AtlasScreen(
          children: [
            AtlasLargeTitle(t.settingsTab.title),

            // --- this device ----------------------------------------------
            AtlasGroup(
              separatorInset: 15,
              children: [
                AtlasRow(
                  leading: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color.lerp(theme.accent, Colors.white, 0.2)!, theme.accent],
                      ),
                    ),
                    child: Icon(
                      checkPlatformIsDesktop() ? CupertinoIcons.desktopcomputer : CupertinoIcons.device_phone_portrait,
                      color: theme.onAccent,
                      size: 26,
                    ),
                  ),
                  title: settings.alias,
                  subtitle: server == null ? t.general.offline : tx('Görünür  ·  Port ${server.port}', 'Visible  ·  Port ${server.port}'),
                  chevron: true,
                  onTap: () async {
                    final alias = await _askText(context, title: t.settingsTab.network.alias, initial: settings.alias);
                    if (alias != null && alias.trim().isNotEmpty && alias.trim() != settings.alias && context.mounted) {
                      await ref.notifier(settingsProvider).setAlias(alias.trim());
                      if (context.mounted) {
                        vm.onTapRestartServer(context);
                      }
                    }
                  },
                ),
              ],
            ),

            // --- appearance -----------------------------------------------
            AtlasGroup(
              header: tx('Tema', 'Theme'),
              separatorInset: 15,
              footer: tx(
                'Çerçeve rengi, gelen dosya kartının ve ekran kenarındaki ışığın rengidir.',
                'The frame color is used for the incoming file card and the screen edge glow.',
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 12,
                    children: [
                      for (final option in kAtlasThemes)
                        _ThemeTile(
                          option: option,
                          selected: option.id == themeState.theme.id,
                          onTap: () async => ref.notifier(atlasThemeProvider).setTheme(option),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(15, 12, 15, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tx('Çerçeve rengi', 'Frame color'), style: TextStyle(fontSize: 15.5, color: theme.text, letterSpacing: -0.2)),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _FrameDot(
                            color: themeState.theme.accent,
                            label: tx('Tema', 'Theme'),
                            selected: themeState.customFrame == null,
                            onTap: () async => ref.notifier(atlasThemeProvider).setFrame(null),
                          ),
                          for (final color in _frameChoices)
                            _FrameDot(
                              color: color,
                              selected: themeState.customFrame?.toARGB32() == color.toARGB32(),
                              onTap: () async => ref.notifier(atlasThemeProvider).setFrame(color),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // --- receiving ------------------------------------------------
            AtlasGroup(
              header: t.receiveTab.title,
              children: [
                AtlasRow(
                  leading: const AtlasIconTile(CupertinoIcons.folder_fill, AppleColors.blue),
                  title: t.settingsTab.receive.destination,
                  value: settings.destination ?? t.settingsTab.receive.downloads.replaceAll(RegExp(r'[()]'), ''),
                  chevron: true,
                  onTap: () async {
                    final choice = await showAtlasActionSheet(
                      context,
                      title: t.settingsTab.receive.destination,
                      actions: [tx('Klasör seç…', 'Choose folder…'), t.settingsTab.receive.downloads.replaceAll(RegExp(r'[()]'), '')],
                    );
                    if (choice == 0) {
                      final directory = await pickDirectoryPath();
                      if (directory != null) {
                        await ref.notifier(settingsProvider).setDestination(directory);
                      }
                    } else if (choice == 1) {
                      await ref.notifier(settingsProvider).setDestination(null);
                    }
                  },
                ),
                AtlasSwitchRow(
                  leading: const AtlasIconTile(CupertinoIcons.clock_fill, AppleColors.gray),
                  title: t.settingsTab.receive.saveToHistory,
                  value: settings.saveToHistory,
                  onChanged: (b) async => ref.notifier(settingsProvider).setSaveToHistory(b),
                ),
              ],
            ),

            // --- general --------------------------------------------------
            AtlasGroup(
              header: tx('Genel', 'General'),
              children: [
                AtlasRow(
                  leading: const AtlasIconTile(CupertinoIcons.globe, AppleColors.blue),
                  title: t.settingsTab.general.language,
                  value: settings.locale?.getLocaleName() ?? t.settingsTab.general.languageOptions.system,
                  chevron: true,
                  onTap: () => vm.onTapLanguage(context),
                ),
                if (checkPlatformIsDesktop()) ...[
                  AtlasSwitchRow(
                    leading: const AtlasIconTile(CupertinoIcons.power, AppleColors.green),
                    title: tx('Oturum açınca başlat', 'Open at login'),
                    value: vm.autoStart,
                    onChanged: (_) => vm.onToggleAutoStart(context),
                  ),
                  if (checkPlatformHasTray())
                    AtlasSwitchRow(
                      leading: const AtlasIconTile(CupertinoIcons.arrow_down_right_square_fill, AppleColors.indigo),
                      title: tx('Kapatınca arka planda çalış', 'Keep running when closed'),
                      value: settings.minimizeToTray,
                      onChanged: (b) async => ref.notifier(settingsProvider).setMinimizeToTray(b),
                    ),
                ],
                AtlasSwitchRow(
                  leading: const AtlasIconTile(CupertinoIcons.sparkles, AppleColors.pink),
                  title: t.settingsTab.general.animations,
                  value: settings.enableAnimations,
                  onChanged: (b) async => ref.notifier(settingsProvider).setEnableAnimations(b),
                ),
              ],
            ),

            // --- network --------------------------------------------------
            AtlasGroup(
              header: t.settingsTab.network.server,
              children: [
                AtlasRow(
                  leading: AtlasIconTile(CupertinoIcons.antenna_radiowaves_left_right, server == null ? AppleColors.gray : AppleColors.green),
                  title: server == null ? t.general.offline : tx('Çalışıyor', 'Running'),
                  value: server == null ? null : '${server.https ? 'HTTPS' : 'HTTP'} · ${server.port}',
                ),
                AtlasRow(
                  leading: const AtlasIconTile(CupertinoIcons.arrow_clockwise, AppleColors.orange),
                  title: t.general.restart,
                  onTap: () => vm.onTapRestartServer(context),
                ),
              ],
            ),

            // --- more -----------------------------------------------------
            AtlasGroup(
              footer: '$kAtlasAppName${version == null ? '' : ' $version'}  ·  $kAtlasBasedOn',
              children: [
                AtlasRow(
                  leading: const AtlasIconTile(CupertinoIcons.slider_horizontal_3, AppleColors.gray),
                  title: t.settingsTab.advancedSettings,
                  chevron: true,
                  onTap: () async => context.push(() => const _AdvancedSettingsPage()),
                ),
                AtlasRow(
                  leading: const AtlasIconTile(CupertinoIcons.info, AppleColors.blue),
                  title: tx('Hakkında', 'About'),
                  chevron: true,
                  onTap: () async => context.push(() => const AboutPage()),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The complete upstream settings, for everything the redesigned screen does not show.
class _AdvancedSettingsPage extends StatelessWidget {
  const _AdvancedSettingsPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.settingsTab.advancedSettings)),
      body: const SettingsTab(),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  final AtlasTheme option;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeTile({required this.option, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          width: 76,
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 68,
                height: 50,
                padding: const EdgeInsets.all(2.5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: selected ? theme.accent : theme.separator, width: selected ? 2.2 : 1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: ColoredBox(
                    color: option.bg,
                    child: Padding(
                      padding: const EdgeInsets.all(7),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            height: 6,
                            width: 30,
                            decoration: BoxDecoration(color: option.text, borderRadius: BorderRadius.circular(3)),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            height: 5,
                            width: 20,
                            decoration: BoxDecoration(color: option.muted, borderRadius: BorderRadius.circular(3)),
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  height: 9,
                                  decoration: BoxDecoration(color: option.surface, borderRadius: BorderRadius.circular(3)),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Container(
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(color: option.accent, shape: BoxShape.circle),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                option.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: selected ? theme.text : theme.muted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FrameDot extends StatelessWidget {
  final Color color;
  final String? label;
  final bool selected;
  final VoidCallback onTap;

  const _FrameDot({required this.color, required this.selected, required this.onTap, this.label});

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 30,
          width: label == null ? 30 : null,
          padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 10),
          decoration: BoxDecoration(
            color: label == null ? color : Colors.transparent,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: selected ? theme.text : (label == null ? theme.separator : color),
              width: selected ? 2.4 : 1.2,
            ),
          ),
          child: label == null
              ? (selected ? Icon(CupertinoIcons.checkmark, size: 14, color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white) : null)
              : Center(
                  widthFactor: 1,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        label!,
                        style: TextStyle(fontSize: 12.5, color: theme.text, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

Future<String?> _askText(BuildContext context, {required String title, required String initial}) {
  final controller = TextEditingController(text: initial);
  return showCupertinoDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (context) => CupertinoAlertDialog(
      title: Text(title),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: CupertinoTextField(controller: controller, autofocus: true, clearButtonMode: OverlayVisibilityMode.editing),
      ),
      actions: [
        CupertinoDialogAction(onPressed: () => Navigator.of(context).pop(), child: Text(t.general.cancel)),
        CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.of(context).pop(controller.text), child: Text(t.general.save)),
      ],
    ),
  );
}
