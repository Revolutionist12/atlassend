import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:localsend_app/atlassend/overlay/overlay_protocol.dart';

/// Card width in logical pixels (the overlay window is 640 wide).
const _cardWidth = 400.0;

/// Space around a card that stays inside the window region, so the glow is not cut off.
const _glowMargin = 40.0;

const _doneLifetime = Duration(seconds: 4);
const _failedLifetime = Duration(seconds: 7);

/// Entry point of the OVERLAY engine (see `atlasOverlayMain` in main.dart).
///
/// This isolate is display-only: it has no providers, no plugins and no file
/// access. Everything it shows arrives as messages from the main isolate.
void atlasOverlayAppMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _OverlayApp());
}

enum _CardState { receiving, done, failed }

class _CardModel {
  final String id;
  final String title;
  final String subtitle;
  final String badge;
  final progress = ValueNotifier<double>(0);
  final state = ValueNotifier<_CardState>(_CardState.receiving);
  final key = GlobalKey<_CardViewState>();
  String failMessage = '';

  _CardModel({required this.id, required this.title, required this.subtitle, required this.badge});
}

class _Palette {
  final Color surface;
  final Color text;
  final Color muted;
  final Color accent;
  final Color frame;
  final String doneLabel;
  final String failedLabel;

  const _Palette({
    required this.surface,
    required this.text,
    required this.muted,
    required this.accent,
    required this.frame,
    required this.doneLabel,
    required this.failedLabel,
  });

  /// "Bakır gece", used until the main isolate sends the real configuration.
  static const fallback = _Palette(
    surface: Color(0xFF231C16),
    text: Color(0xFFF3ECE4),
    muted: Color(0xFF9A8B7C),
    accent: Color(0xFFD08C4E),
    frame: Color(0xFFD08C4E),
    doneLabel: 'Done',
    failedLabel: 'Failed',
  );

  static const error = Color(0xFFE5484D);
}

class _OverlayApp extends StatefulWidget {
  const _OverlayApp();

  @override
  State<_OverlayApp> createState() => _OverlayAppState();
}

class _OverlayAppState extends State<_OverlayApp> with SingleTickerProviderStateMixin {
  static const _window = MethodChannel(kOverlayWindowChannel);

  final _port = ReceivePort();
  final _cards = <_CardModel>[];
  SendPort? _mainPort;
  _Palette _palette = _Palette.fallback;

  /// Slow "breathing" of the frame glow. Only runs while something is being received,
  /// so a finished card costs no frames while it waits to disappear.
  late final AnimationController _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  List<int> _lastRegion = const [];
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _port.listen(_onMessage);
    _mainPort = IsolateNameServer.lookupPortByName(kOverlayMainPortName);
    _mainPort?.send([kMsgReady, _port.sendPort]);

    // Registered after the binding's own frame callback, so layout is already
    // done when this runs: once per drawn frame, never when nothing animates.
    SchedulerBinding.instance.addPersistentFrameCallback((_) => _updateRegion());
  }

  void _onMessage(Object? message) {
    if (message is! List || message.isEmpty) {
      return;
    }
    switch (message[0]) {
      case kMsgConfig:
        setState(() {
          _palette = _Palette(
            surface: Color(message[2] as int),
            text: Color(message[3] as int),
            muted: Color(message[4] as int),
            accent: Color(message[5] as int),
            frame: Color(message[6] as int),
            doneLabel: message[7] as String,
            failedLabel: message[8] as String,
          );
        });
      case kMsgAdd:
        setState(() {
          _cards.add(
            _CardModel(
              id: message[1] as String,
              title: message[2] as String,
              subtitle: message[3] as String,
              badge: message[4] as String,
            ),
          );
        });
        _syncBreath();
      case kMsgProgress:
        _find(message[1])?.progress.value = (message[2] as num).toDouble();
      case kMsgDone:
        final card = _find(message[1]);
        if (card != null) {
          card.progress.value = 1;
          card.state.value = _CardState.done;
        }
        _syncBreath();
      case kMsgFail:
        final card = _find(message[1]);
        if (card != null) {
          card.failMessage = message[2] as String;
          card.state.value = _CardState.failed;
        }
        _syncBreath();
      case kMsgRemove:
        // ignore: discarded_futures
        _find(message[1])?.key.currentState?.dismiss();
    }
  }

  _CardModel? _find(Object? id) {
    for (final card in _cards) {
      if (card.id == id) {
        return card;
      }
    }
    return null;
  }

  void _syncBreath() {
    final receiving = _cards.any((c) => c.state.value == _CardState.receiving);
    if (receiving && !_breath.isAnimating) {
      // ignore: discarded_futures
      _breath.repeat(reverse: true);
    } else if (!receiving && _breath.isAnimating) {
      _breath.stop();
    }
  }

  void _onCardGone(_CardModel card) {
    setState(() => _cards.remove(card));
    _syncBreath();
    if (_cards.isEmpty) {
      _lastRegion = const [];
      _visible = false;
      // ignore: discarded_futures
      _window.invokeMethod<void>('setRegion', {'rects': const <int>[]});
      _mainPort?.send([kMsgIdle]);
    }
  }

  /// Keeps the window region equal to the cards (plus glow): the rest of the
  /// overlay window is neither painted nor clickable.
  void _updateRegion() {
    if (_cards.isEmpty) {
      return;
    }
    final dpr = PlatformDispatcher.instance.views.first.devicePixelRatio;
    final region = <int>[];
    for (final card in _cards) {
      final box = card.key.currentState?.cardBox;
      if (box == null || !box.attached || !box.hasSize) {
        continue;
      }
      final rect = (box.localToGlobal(Offset.zero) & box.size).inflate(_glowMargin);
      region
        ..add((rect.left * dpr).floor())
        ..add((rect.top * dpr).floor())
        ..add((rect.right * dpr).ceil())
        ..add((rect.bottom * dpr).ceil());
    }
    if (region.isEmpty || listEquals(region, _lastRegion)) {
      return;
    }
    _lastRegion = region;
    // ignore: discarded_futures
    _window.invokeMethod<void>('setRegion', {'rects': region});
    if (!_visible) {
      _visible = true;
      // ignore: discarded_futures
      _window.invokeMethod<void>('raise');
    }
  }

  @override
  void dispose() {
    _port.close();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(
        style: TextStyle(
          fontFamily: 'Segoe UI Variable Display',
          fontFamilyFallback: const ['Segoe UI'],
          color: _palette.text,
          fontSize: 14,
          decoration: TextDecoration.none,
        ),
        // Everything outside the cards stays fully transparent.
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final card in _cards)
                _CardView(
                  key: card.key,
                  model: card,
                  palette: _palette,
                  breath: _breath,
                  onOpen: () => _mainPort?.send([kMsgOpen, card.id]),
                  onReveal: () => _mainPort?.send([kMsgReveal, card.id]),
                  onGone: () => _onCardGone(card),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardView extends StatefulWidget {
  final _CardModel model;
  final _Palette palette;
  final Animation<double> breath;
  final VoidCallback onOpen;
  final VoidCallback onReveal;
  final VoidCallback onGone;

  const _CardView({
    required super.key,
    required this.model,
    required this.palette,
    required this.breath,
    required this.onOpen,
    required this.onReveal,
    required this.onGone,
  });

  @override
  State<_CardView> createState() => _CardViewState();
}

class _CardViewState extends State<_CardView> with TickerProviderStateMixin {
  final _boxKey = GlobalKey();

  /// Height of the card's slot in the stack: grows on entry and collapses on exit,
  /// so the other cards glide instead of jumping.
  late final AnimationController _slot = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));

  /// Vertical offset of the card from its resting place (spring driven).
  late final AnimationController _fly = AnimationController.unbounded(vsync: this);

  late final AnimationController _exit = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));

  Timer? _dismissTimer;
  bool _hovered = false;
  bool _dismissing = false;

  /// The painted card, used by the app to compute the window region.
  RenderBox? get cardBox => _boxKey.currentContext?.findRenderObject() as RenderBox?;

  @override
  void initState() {
    super.initState();
    widget.model.state.addListener(_onStateChanged);

    // Default entry (no fling data): the card rises from below the bottom edge
    // and settles with a spring.
    final view = PlatformDispatcher.instance.views.first;
    final start = view.physicalSize.height / view.devicePixelRatio / 2 + 160;
    _fly.value = start;
    // ignore: discarded_futures
    _slot.forward();
    // ignore: discarded_futures
    _fly.animateWith(SpringSimulation(const SpringDescription(mass: 1, stiffness: 170, damping: 22), start, 0, -1800));

    // A small file can be finished before this view is mounted; the state
    // listener never fires for it, so the lifetime has to start here.
    _scheduleDismiss();
  }

  void _onStateChanged() {
    if (mounted) {
      setState(() {});
    }
    _scheduleDismiss();
  }

  void _scheduleDismiss() {
    _dismissTimer?.cancel();
    final state = widget.model.state.value;
    if (state == _CardState.receiving || _hovered) {
      return;
    }
    _dismissTimer = Timer(state == _CardState.done ? _doneLifetime : _failedLifetime, dismiss);
  }

  /// Fades the card out, closes its slot and removes it.
  Future<void> dismiss() async {
    if (_dismissing || !mounted) {
      return;
    }
    _dismissing = true;
    _dismissTimer?.cancel();
    await _exit.forward();
    if (!mounted) {
      return;
    }
    await _slot.reverse();
    if (mounted) {
      widget.onGone();
    }
  }

  @override
  void dispose() {
    widget.model.state.removeListener(_onStateChanged);
    _dismissTimer?.cancel();
    _slot.dispose();
    _fly.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final model = widget.model;
    final state = model.state.value;
    final frame = state == _CardState.failed ? _Palette.error : palette.frame;

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(color: palette.accent, borderRadius: BorderRadius.circular(8)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  child: Text(
                    model.badge,
                    style: TextStyle(color: palette.surface, fontWeight: FontWeight.w700, fontSize: 12.5, letterSpacing: 0.2),
                  ),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      model.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // "Show in folder". The inner detector wins over the card's own tap.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onReveal,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.folder_open_rounded, size: 20, color: palette.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 18,
            child: switch (state) {
              _CardState.receiving => Align(
                alignment: Alignment.centerLeft,
                child: ValueListenableBuilder<double>(
                  valueListenable: model.progress,
                  builder: (context, value, _) => TweenAnimationBuilder<double>(
                    // Smooths the ~30 updates per second into a continuous motion.
                    tween: Tween<double>(end: value.clamp(0.0, 1.0)),
                    duration: const Duration(milliseconds: 160),
                    builder: (context, shown, _) => Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: SizedBox(
                              height: 5,
                              child: Stack(
                                children: [
                                  Positioned.fill(child: ColoredBox(color: palette.text.withValues(alpha: 0.12))),
                                  FractionallySizedBox(
                                    widthFactor: shown,
                                    child: ColoredBox(color: palette.accent, child: const SizedBox.expand()),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            '${(shown * 100).round()}%',
                            textAlign: TextAlign.right,
                            style: TextStyle(color: palette.muted, fontSize: 12, fontFeatures: const [FontFeature.tabularFigures()]),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _CardState.done => Row(
                children: [
                  Icon(Icons.check_circle_rounded, size: 17, color: palette.accent),
                  const SizedBox(width: 6),
                  Text(
                    palette.doneLabel,
                    style: TextStyle(color: palette.accent, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              _CardState.failed => Row(
                children: [
                  const Icon(Icons.error_rounded, size: 17, color: _Palette.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      model.failMessage.isEmpty ? palette.failedLabel : '${palette.failedLabel} · ${model.failMessage}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _Palette.error, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            },
          ),
        ],
      ),
    );

    final card = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        _hovered = true;
        _dismissTimer?.cancel();
      },
      onExit: (_) {
        _hovered = false;
        _scheduleDismiss();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          widget.onOpen();
          // ignore: discarded_futures
          dismiss();
        },
        onSecondaryTap: widget.onReveal,
        child: AnimatedBuilder(
          // Only the frame and its glow repaint while the glow "breathes".
          animation: widget.breath,
          builder: (context, child) => DecoratedBox(
            key: _boxKey,
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: frame, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: frame.withValues(alpha: state == _CardState.receiving ? 0.28 + 0.27 * widget.breath.value : 0.42),
                  blurRadius: 26,
                ),
              ],
            ),
            child: child,
          ),
          child: SizedBox(width: _cardWidth, child: content),
        ),
      ),
    );

    return AnimatedBuilder(
      animation: Listenable.merge([_slot, _fly, _exit]),
      builder: (context, child) => Align(
        // Not a SizeTransition: that one clips, which would cut the glow and the flying card.
        heightFactor: Curves.easeOutCubic.transform(_slot.value.clamp(0.0, 1.0)),
        child: Transform.translate(
          offset: Offset(0, _fly.value),
          child: Opacity(
            opacity: 1 - _exit.value,
            child: Transform.scale(scale: 1 - 0.04 * _exit.value, child: child),
          ),
        ),
      ),
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: card),
    );
  }
}
