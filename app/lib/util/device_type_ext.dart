import 'package:flutter/cupertino.dart';
import 'package:localsend_isolates/model/device.dart';

extension DeviceTypeExt on DeviceType {
  IconData get icon {
    return switch (this) {
      DeviceType.mobile => CupertinoIcons.device_phone_portrait,
      DeviceType.desktop => CupertinoIcons.desktopcomputer,
      DeviceType.web => CupertinoIcons.globe,
      DeviceType.headless => CupertinoIcons.chevron_left_slash_chevron_right,
      DeviceType.server => CupertinoIcons.rectangle_stack,
    };
  }
}
