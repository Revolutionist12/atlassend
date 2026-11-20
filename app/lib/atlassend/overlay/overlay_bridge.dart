import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:localsend_app/atlassend/overlay/overlay_protocol.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme_provider.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/util/native/open_folder.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:logging/logging.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('AtlasOverlayBridge');

/// Up to this many files each get their own card; larger transfers share one summary card.
const _maxFileCards = 3;

/// The overlay engine is shut down after the overlay has been empty for this long.
const _engineIdleTimeout = Duration(seconds: 60);

/// How often the progress of a running transfer is forwarded (about 30 times per second).
const _progressInterval = Duration(milliseconds: 33);

/// Lives in the MAIN isolate. Watches the receive session and mirrors it as
/// cards into the overlay engine.
///
/// It only observes existing providers ([serverProvider], [fileTransferProvider]);
/// the receive flow itself is untouched, and the file data never passes through here.
class AtlasOverlayBridge {
  AtlasOverlayBridge._(this._container);

  static AtlasOverlayBridge? _instance;

  /// Starts the bridge. Does nothing on platforms without the overlay window.
  static void start(RefenaContainer container) {
    if (!Platform.isWindows || _instance != null) {
      return;
    }
    _instance = AtlasOverlayBridge._(container).._init();
  }

  final RefenaContainer _container;
  final _host = const MethodChannel(kOverlayHostChannel);
  final _mainPort = ReceivePort();

  SendPort? _overlayPort;
  bool _starting = false;
  Completer<void>? _ready;
  final _pending = <List<Object?>>[];
  Timer? _progressTimer;
  Timer? _stopTimer;

  _TrackedSession? _tracked;

  /// What a click on a card does. Kept after the session is gone, because cards outlive it.
  final _actions = <String, _CardAction>{};

  void _init() {
    IsolateNameServer.removePortNameMapping(kOverlayMainPortName);
    IsolateNameServer.registerPortWithName(_mainPort.sendPort, kOverlayMainPortName);
    _mainPort.listen(_onOverlayMessage);
    _container.stream(serverProvider).listen((event) => _onServerState(event.next));
  }

  // --- session -> cards ----------------------------------------------------

  void _onServerState(ServerState? state) {
    try {
      final session = state?.session;
      final tracked = _tracked;
      if (tracked != null && (session == null || session.sessionId != tracked.sessionId)) {
        // The session was closed or replaced; whatever did not finish disappears.
        _stopTracking(removeUnfinished: true);
      }
      if (session == null) {
        return;
      }
      if (_tracked == null) {
        if (session.status != SessionStatus.sending) {
          // Not accepted yet (or already over): the main window handles that.
          return;
        }
        final accepted = session.files.values.where((f) => f.desiredName != null).toList();
        if (accepted.isEmpty) {
          return;
        }
        _startTracking(session, accepted);
      }
      _syncCards(session);
    } catch (e, st) {
      _logger.warning('Overlay update failed', e, st);
    }
  }

  void _startTracking(ReceiveSessionState session, List<ReceivingFile> accepted) {
    final turkish = LocaleSettings.currentLocale.languageCode == 'tr';
    final cards = <_Card>[];
    if (accepted.length <= _maxFileCards) {
      for (final file in accepted) {
        final name = p.basename(file.desiredName!);
        final extension = p.extension(name).replaceFirst('.', '').toUpperCase();
        cards.add(
          _Card(
            id: '${session.sessionId}:${file.file.id}',
            fileIds: [file.file.id],
            title: name,
            subtitle: '${file.file.size.asReadableFileSize} · ${session.senderAlias}',
            badge: extension.isEmpty || extension.length > 5 ? (turkish ? 'DOSYA' : 'FILE') : '.$extension',
          ),
        );
      }
    } else {
      final total = accepted.fold<int>(0, (sum, f) => sum + f.file.size);
      cards.add(
        _Card(
          id: '${session.sessionId}:all',
          fileIds: [for (final f in accepted) f.file.id],
          title: turkish ? '${accepted.length} dosya' : '${accepted.length} files',
          subtitle: '${total.asReadableFileSize} · ${session.senderAlias}',
          badge: '×${accepted.length}',
        ),
      );
    }

    _tracked = _TrackedSession(
      sessionId: session.sessionId,
      sizes: {for (final f in accepted) f.file.id: f.file.size},
      cards: cards,
    );

    final themeState = _container.read(atlasThemeProvider);
    final theme = themeState.theme;
    _send([
      kMsgConfig,
      theme.bg.toARGB32(),
      theme.surface.toARGB32(),
      theme.text.toARGB32(),
      theme.muted.toARGB32(),
      theme.accent.toARGB32(),
      themeState.frame.toARGB32(),
      turkish ? 'Tamamlandı' : 'Done',
      turkish ? 'Başarısız' : 'Failed',
      turkish ? 'Açılıyor…' : 'Opening…',
    ]);
    for (final card in cards) {
      _actions[card.id] = _CardAction(folder: session.destinationDirectory);
      _send([kMsgAdd, card.id, card.title, card.subtitle, card.badge, null]);
    }

    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(_progressInterval, (_) => _forwardProgress());
  }

  /// Reports finished and failed files of [session] to their cards.
  void _syncCards(ReceiveSessionState session) {
    final tracked = _tracked;
    if (tracked == null) {
      return;
    }
    final transfers = _container.read(fileTransferProvider);
    final cancelled = session.status == SessionStatus.canceledBySender || session.status == SessionStatus.canceledByReceiver;
    final turkish = LocaleSettings.currentLocale.languageCode == 'tr';

    for (final card in tracked.cards.where((c) => !c.closed)) {
      final statuses = [for (final id in card.fileIds) transfers.getStatus(sessionId: tracked.sessionId, fileId: id)];
      final finished = statuses.where((s) => s == FileStatus.finished).length;
      final allOver = statuses.isFinishedOrError;

      if (allOver && finished > 0) {
        final action = _actions[card.id];
        if (action != null && card.fileIds.length == 1) {
          action.file = session.files[card.fileIds.single]?.path;
        }
        if (finished < statuses.length) {
          // Some files of a summary card failed; say so instead of a plain "done".
          _send([kMsgFail, card.id, '$finished/${statuses.length}']);
        } else {
          _send([kMsgProgress, card.id, 1.0]);
          _send([kMsgDone, card.id]);
        }
        card.closed = true;
      } else if (allOver) {
        final error = card.fileIds.length == 1 ? session.files[card.fileIds.single]?.errorMessage : null;
        _send([kMsgFail, card.id, error ?? '']);
        card.closed = true;
      } else if (cancelled) {
        _send([kMsgFail, card.id, turkish ? 'İptal edildi' : 'Canceled']);
        card.closed = true;
      }
    }

    if (tracked.cards.every((c) => c.closed)) {
      _stopTracking(removeUnfinished: false);
    }
  }

  void _forwardProgress() {
    final tracked = _tracked;
    if (tracked == null) {
      _progressTimer?.cancel();
      return;
    }
    final transfers = _container.read(fileTransferProvider);
    for (final card in tracked.cards.where((c) => !c.closed)) {
      var done = 0.0;
      var total = 0;
      for (final id in card.fileIds) {
        final size = tracked.sizes[id] ?? 0;
        total += size;
        done += transfers.getProgress(sessionId: tracked.sessionId, fileId: id) * size;
      }
      final progress = total == 0 ? 0.0 : done / total;
      if ((progress - card.lastProgress).abs() >= 0.004) {
        card.lastProgress = progress;
        _send([kMsgProgress, card.id, progress]);
      }
    }
  }

  void _stopTracking({required bool removeUnfinished}) {
    final tracked = _tracked;
    _tracked = null;
    _progressTimer?.cancel();
    _progressTimer = null;
    if (tracked != null && removeUnfinished) {
      for (final card in tracked.cards.where((c) => !c.closed)) {
        _send([kMsgRemove, card.id]);
        _actions.remove(card.id);
      }
    }
  }

  // --- transport -----------------------------------------------------------

  void _send(List<Object?> message) {
    _stopTimer?.cancel();
    final port = _overlayPort;
    if (port != null) {
      port.send(message);
      return;
    }
    _pending.add(message);
    // ignore: discarded_futures
    _startOverlay();
  }

  Future<void> _startOverlay() async {
    if (_starting) {
      return;
    }
    _starting = true;
    final watch = Stopwatch()..start();
    final ready = _ready = Completer<void>();
    try {
      final started = await _host.invokeMethod<bool>('start');
      if (started != true) {
        throw StateError('The runner could not create the overlay window');
      }
      // The overlay isolate announces itself with [kMsgReady]; see [_onOverlayMessage].
      await ready.future.timeout(const Duration(seconds: 8));
      _logger.info('Overlay engine ready after ${watch.elapsedMilliseconds} ms');
    } catch (e) {
      _logger.warning('Overlay unavailable, falling back to the main window only', e);
      _pending.clear();
    } finally {
      _starting = false;
      _ready = null;
    }
  }

  void _onOverlayMessage(Object? message) {
    if (message is! List || message.isEmpty) {
      return;
    }
    switch (message[0]) {
      case kMsgReady:
        final port = message[1] as SendPort;
        _overlayPort = port;
        for (final pending in _pending) {
          port.send(pending);
        }
        _pending.clear();
        final ready = _ready;
        if (ready != null && !ready.isCompleted) {
          ready.complete();
        }
      case kMsgOpen:
        // ignore: discarded_futures
        _open(message[1] as String, reveal: false);
      case kMsgReveal:
        // ignore: discarded_futures
        _open(message[1] as String, reveal: true);
      case kMsgIdle:
        _stopTimer?.cancel();
        _stopTimer = Timer(_engineIdleTimeout, _stopOverlay);
    }
  }

  /// Frees the second engine again; it is restarted with the next transfer.
  Future<void> _stopOverlay() async {
    if (_tracked != null || _pending.isNotEmpty) {
      return;
    }
    _overlayPort = null;
    _actions.clear();
    try {
      await _host.invokeMethod<bool>('stop');
    } catch (e) {
      _logger.warning('Stopping the overlay failed', e);
    }
  }

  Future<void> _open(String cardId, {required bool reveal}) async {
    final action = _actions[cardId];
    if (action == null) {
      return;
    }
    try {
      final file = action.file;
      if (file == null) {
        // Summary card (or a file without a path): open the destination folder.
        await openFolder(folderPath: action.folder);
      } else if (reveal) {
        await openFolder(folderPath: p.dirname(file), fileName: p.basename(file));
      } else {
        await OpenFile.open(file);
      }
    } catch (e) {
      _logger.warning('Could not open $cardId', e);
    }
  }
}

class _TrackedSession {
  final String sessionId;
  final Map<String, int> sizes; // file id -> bytes
  final List<_Card> cards;

  _TrackedSession({required this.sessionId, required this.sizes, required this.cards});
}

class _Card {
  final String id;
  final List<String> fileIds;
  final String title;
  final String subtitle;
  final String badge;
  double lastProgress = 0;

  /// A final state (done / failed) has been sent.
  bool closed = false;

  _Card({required this.id, required this.fileIds, required this.title, required this.subtitle, required this.badge});
}

class _CardAction {
  final String folder;
  String? file;

  _CardAction({required this.folder});
}
