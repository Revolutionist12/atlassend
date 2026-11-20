import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme_provider.dart';
import 'package:localsend_app/atlassend/ui/atlas_widgets.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/pages/selected_files_page.dart';
import 'package:localsend_app/pages/tabs/send_tab.dart' show pickerOptions;
import 'package:localsend_app/pages/tabs/send_tab_vm.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/favorites.dart';
import 'package:localsend_app/util/ip_helper.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/widget/file_thumbnail.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

extension on FilePickerOption {
  IconData get appleIcon => switch (this) {
    FilePickerOption.file => CupertinoIcons.doc_fill,
    FilePickerOption.folder => CupertinoIcons.folder_fill,
    FilePickerOption.media => CupertinoIcons.photo_fill_on_rectangle_fill,
    FilePickerOption.text => CupertinoIcons.text_bubble_fill,
    FilePickerOption.app => CupertinoIcons.square_grid_2x2_fill,
    FilePickerOption.clipboard => CupertinoIcons.doc_on_clipboard_fill,
  };

  Color get appleColor => switch (this) {
    FilePickerOption.file => AppleColors.blue,
    FilePickerOption.folder => AppleColors.teal,
    FilePickerOption.media => AppleColors.pink,
    FilePickerOption.text => AppleColors.green,
    FilePickerOption.app => AppleColors.indigo,
    FilePickerOption.clipboard => AppleColors.orange,
  };
}

extension on DeviceType {
  IconData get appleIcon => switch (this) {
    DeviceType.mobile => CupertinoIcons.device_phone_portrait,
    DeviceType.desktop => CupertinoIcons.desktopcomputer,
    DeviceType.web => CupertinoIcons.globe,
    DeviceType.headless || DeviceType.server => CupertinoIcons.tv,
  };

  Color get appleColor => switch (this) {
    DeviceType.mobile => AppleColors.blue,
    DeviceType.desktop => AppleColors.indigo,
    DeviceType.web => AppleColors.teal,
    DeviceType.headless || DeviceType.server => AppleColors.gray,
  };
}

class AtlasSendScreen extends StatelessWidget {
  const AtlasSendScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ViewModelBuilder(
      provider: (ref) => sendTabVmProvider,
      init: (context) async => context.global.dispatchAsync(SendTabInitAction(context)), // ignore: discarded_futures
      builder: (context, vm) {
        final theme = atlasOf(context);
        final ref = context.ref;
        final scanning = context.watch(nearbyDevicesProvider.select((s) => s.runningFavoriteScan || s.runningIps.isNotEmpty));
        final devices = vm.nearbyDevices.toList();

        return AtlasScreen(
          children: [
            AtlasLargeTitle(
              t.sendTab.title,
              trailing: _ScanButton(scanning: scanning, onTap: () async => ref.global.dispatchAsync(StartSmartScan())),
            ),

            // --- what to send ---------------------------------------------
            if (vm.selectedFiles.isEmpty)
              _PickerGrid(
                onPick: (option) async => ref.global.dispatchAsync(PickFileAction(option: option, context: context)),
              )
            else
              AtlasGroup(
                header: t.sendTab.selection.title,
                separatorInset: 15,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(15, 14, 15, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: defaultThumbnailSize,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: vm.selectedFiles.length,
                            separatorBuilder: (_, _) => const SizedBox(width: 8),
                            itemBuilder: (context, i) => ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SmartFileThumbnail.fromCrossFile(vm.selectedFiles[i]),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '${tx('${vm.selectedFiles.length} öğe', '${vm.selectedFiles.length} items')}  ·  '
                          '${vm.selectedFiles.fold<int>(0, (sum, f) => sum + f.size).asReadableFileSize}',
                          style: TextStyle(fontSize: 14, color: theme.muted),
                        ),
                      ],
                    ),
                  ),
                  AtlasRow(
                    leading: Icon(CupertinoIcons.plus_circle_fill, color: theme.accent, size: 22),
                    title: tx('Daha fazla ekle', 'Add more'),
                    onTap: () async {
                      final option = await showAtlasActionSheet(
                        context,
                        title: tx('Ekle', 'Add'),
                        actions: pickerOptions.map((o) => o.label).toList(),
                      );
                      if (option != null && context.mounted) {
                        await ref.global.dispatchAsync(PickFileAction(option: pickerOptions[option], context: context));
                      }
                    },
                  ),
                  AtlasRow(
                    leading: Icon(CupertinoIcons.pencil_circle_fill, color: theme.accent, size: 22),
                    title: t.general.edit,
                    onTap: () async => context.push(() => const SelectedFilesPage()),
                  ),
                  AtlasRow(
                    leading: const Icon(CupertinoIcons.xmark_circle_fill, color: AppleColors.red, size: 22),
                    title: tx('Seçimi temizle', 'Clear selection'),
                    destructive: true,
                    onTap: () => ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction()),
                  ),
                ],
              ),

            // --- send mode ------------------------------------------------
            Padding(
              padding: const EdgeInsets.only(bottom: 22),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoSlidingSegmentedControl<SendMode>(
                  groupValue: vm.sendMode == SendMode.multiple ? SendMode.multiple : SendMode.single,
                  backgroundColor: theme.surface,
                  thumbColor: theme.isDark ? theme.muted.withValues(alpha: 0.45) : Colors.white,
                  padding: const EdgeInsets.all(3),
                  children: {
                    SendMode.single: _Segment(t.sendTab.sendModes.single),
                    SendMode.multiple: _Segment(t.sendTab.sendModes.multiple),
                  },
                  onValueChanged: (mode) async {
                    if (mode != null) {
                      await vm.onTapSendMode(context, mode);
                    }
                  },
                ),
              ),
            ),

            // --- nearby devices -------------------------------------------
            AtlasGroup(
              header: t.sendTab.nearbyDevices,
              footer: devices.isEmpty
                  ? null
                  : (vm.selectedFiles.isEmpty
                        ? tx('Bir cihaza dokun; önce dosya seçmen istenecek.', 'Tap a device; you will be asked to pick files first.')
                        : tx('Göndermek için bir cihaza dokun.', 'Tap a device to send.')),
              children: devices.isEmpty
                  ? [
                      AtlasRow(
                        leading: scanning
                            ? const CupertinoActivityIndicator(radius: 9)
                            : Icon(CupertinoIcons.wifi_slash, size: 20, color: theme.muted),
                        title: scanning ? tx('Cihazlar aranıyor…', 'Looking for devices…') : tx('Cihaz bulunamadı', 'No devices found'),
                        subtitle: scanning
                            ? null
                            : tx(
                                'Diğer cihazda AtlasSend veya LocalSend açık ve aynı Wi‑Fi’de olmalı.',
                                'The other device must have AtlasSend or LocalSend open on the same Wi‑Fi.',
                              ),
                      ),
                    ]
                  : [
                      for (final device in devices)
                        Builder(
                          builder: (context) {
                            final favorite = vm.favoriteDevices.findDevice(device);
                            final details = [
                              if (device.deviceModel != null && device.deviceModel!.isNotEmpty) device.deviceModel!,
                              if (device.ip != null) '#${device.ip!.visualId}',
                            ].join('  ·  ');
                            return AtlasRow(
                              leading: AtlasIconTile(device.deviceType.appleIcon, device.deviceType.appleColor),
                              title: favorite?.alias ?? device.alias,
                              subtitle: details.isEmpty ? null : details,
                              trailing: favorite != null ? const Icon(CupertinoIcons.star_fill, size: 15, color: AppleColors.yellow) : null,
                              chevron: true,
                              onTap: () async =>
                                  vm.sendMode == SendMode.multiple ? vm.onTapDeviceMultiSend(context, device) : vm.onTapDevice(context, device),
                            );
                          },
                        ),
                    ],
            ),

            // --- other ways -----------------------------------------------
            AtlasGroup(
              children: [
                AtlasRow(
                  leading: const AtlasIconTile(CupertinoIcons.star_fill, AppleColors.yellow),
                  title: t.dialogs.favoriteDialog.title,
                  chevron: true,
                  onTap: () async => vm.onTapFavorite(context),
                ),
                AtlasRow(
                  leading: const AtlasIconTile(CupertinoIcons.number, AppleColors.gray),
                  title: tx('Adresle gönder', 'Send to address'),
                  chevron: true,
                  onTap: () async => vm.onTapAddress(context),
                ),
                AtlasRow(
                  leading: const AtlasIconTile(CupertinoIcons.link, AppleColors.purple),
                  title: t.sendTab.sendModes.link,
                  chevron: true,
                  onTap: () async => vm.onTapSendMode(context, SendMode.link),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Segment extends StatelessWidget {
  final String label;

  const _Segment(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Text(
        label,
        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: theme.text, letterSpacing: -0.2),
      ),
    );
  }
}

class _PickerGrid extends StatelessWidget {
  final ValueChanged<FilePickerOption> onPick;

  const _PickerGrid({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth > 520 ? 4 : 2;
          const gap = 10.0;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final option in pickerOptions)
                SizedBox(
                  width: width,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: ColoredBox(
                      color: theme.surface,
                      child: AtlasPressable(
                        onTap: () => onPick(option),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 13),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AtlasIconTile(option.appleIcon, option.appleColor, size: 32),
                              const SizedBox(height: 14),
                              Text(
                                option.label,
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: theme.text, letterSpacing: -0.3),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ScanButton extends StatefulWidget {
  final bool scanning;
  final VoidCallback onTap;

  const _ScanButton({required this.scanning, required this.onTap});

  @override
  State<_ScanButton> createState() => _ScanButtonState();
}

class _ScanButtonState extends State<_ScanButton> {
  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: AtlasPressable(
        onTap: widget.scanning ? null : widget.onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: theme.surface, shape: BoxShape.circle),
          child: Center(
            child: widget.scanning
                ? const CupertinoActivityIndicator(radius: 9)
                : Icon(CupertinoIcons.arrow_clockwise, size: 18, color: theme.accent),
          ),
        ),
      ),
    );
  }
}
