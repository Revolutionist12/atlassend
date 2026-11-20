import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:localsend_app/atlassend/atlas_identity.dart';
import 'package:localsend_app/atlassend/overlay/overlay_app.dart';
import 'package:localsend_app/atlassend/overlay/overlay_bridge.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme_provider.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/config/init_error.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/widget/watcher/life_cycle_watcher.dart';
import 'package:localsend_app/widget/watcher/shortcut_watcher.dart';
import 'package:localsend_app/widget/watcher/tray_watcher.dart';
import 'package:localsend_app/widget/watcher/window_brightness_watcher.dart';
import 'package:localsend_app/widget/watcher/window_watcher.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_date_time_format/system_date_time_format.dart';

Future<void> main(List<String> args) async {
  final RefenaContainer container;
  try {
    container = await preInit(args);
  } catch (e, stackTrace) {
    showInitErrorApp(
      error: e,
      stackTrace: stackTrace,
    );
    return;
  }

  // AtlasSend: theme preferences live in the same store as the upstream settings.
  await container.set(atlasPrefsProvider.overrideWithValue(await SharedPreferences.getInstance()));

  runApp(
    RefenaScope.withContainer(
      container: container,
      child: SDTFScope(
        child: TranslationProvider(
          child: const LocalSendApp(),
        ),
      ),
    ),
  );

  // AtlasSend: mirror incoming transfers into the overlay window (Windows only).
  AtlasOverlayBridge.start(container);
}

/// Entry point of the overlay engine. The Windows runner starts a second
/// Flutter engine with this function instead of [main]; it has to live in the
/// root library to be found by name.
@pragma('vm:entry-point')
void atlasOverlayMain() => atlasOverlayAppMain();

class LocalSendApp extends StatelessWidget {
  const LocalSendApp();

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    // AtlasSend: the colors come from the selected AtlasSend theme (light or dark by itself).
    final atlasTheme = ref.watch(atlasThemeProvider.select((s) => s.theme));
    final materialTheme = atlasMaterialTheme(atlasTheme);
    return TrayWatcher(
      child: WindowWatcher(
        child: LifeCycleWatcher(
          onChangedState: (AppLifecycleState state) {
            switch (state) {
              case AppLifecycleState.resumed:
                ref.redux(localIpProvider).dispatch(InitLocalIpAction());
                if (checkPlatform([TargetPlatform.iOS, TargetPlatform.android])) {
                  // The OS may have invalidated the sockets of the suspended app without any error ever reaching the accept loop.
                  // ignore: discarded_futures
                  ref.notifier(serverProvider).ensureRunning();
                }
                if (checkPlatform([TargetPlatform.iOS])) {
                  // The multicast sockets die the same silent way but cannot be probed, so always rebind them.
                  ref.redux(parentIsolateProvider).dispatch(IsolateDiscoveryRestartAction());
                }
                break;
              case AppLifecycleState.detached:
                // The main isolate is only exited when all child isolates are exited.
                // https://github.com/localsend/localsend/issues/1568
                ref.redux(parentIsolateProvider).dispatch(IsolateDisposeAction());
                break;
              default:
                break;
            }
          },
          child: ShortcutWatcher(
            child: MaterialApp(
              title: kAtlasAppName,
              locale: TranslationProvider.of(context).flutterLocale,
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              debugShowCheckedModeBanner: false,
              theme: materialTheme,
              darkTheme: materialTheme,
              themeMode: atlasTheme.isDark ? ThemeMode.dark : ThemeMode.light,
              builder: (context, child) => WindowBrightnessWatcher(child: child!),
              navigatorKey: context.read(navigationProvider).key,
              home: RouterinoHome(
                builder: () => const HomePage(
                  initialTab: HomeTab.receive,
                  appStart: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
