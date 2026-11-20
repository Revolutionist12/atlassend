import 'dart:io';

import 'package:localsend_app/util/alias_generator.dart';

/// Single source of truth for the visible identity of this fork.
///
/// AtlasSend is based on LocalSend (https://localsend.org, Apache License 2.0).
/// Upstream code keeps its own names internally (package name, i18n keys); only
/// what the user sees is routed through these constants.
const kAtlasAppName = 'AtlasSend';

/// Attribution shown on the about page.
const kAtlasBasedOn = 'Based on LocalSend';

/// Tray icon on Windows. Bundled through the `assets/img/` folder entry in pubspec.yaml.
const kAtlasTrayIconWindows = 'assets/img/atlassend.ico';

/// The alias a fresh installation announces on the network, e.g. `AtlasSend · EXCALIBUR`.
/// Falls back to a random alias when the device has no usable host name.
String atlasDefaultAlias() {
  String host;
  try {
    host = Platform.localHostname.trim();
  } catch (_) {
    host = '';
  }
  if (host.isEmpty || host.toLowerCase() == 'localhost') {
    host = generateRandomAlias();
  }
  return '$kAtlasAppName · $host';
}
