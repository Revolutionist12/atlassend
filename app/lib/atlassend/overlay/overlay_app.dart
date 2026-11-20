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

/// Card width in logical pixels (the overlay window covers the whole primary monitor).
const _cardWidth = 400.0;

/// Space around a card that stays inside the window region, so the glow is not cut off.
const _glowMargin = 40.0;

/// How far the screen edge glow reaches into the screen (logical pixels). While it plays,
/// this band along all four edges is part of the window region.
const _edgeBand = 240.0;

/// One run of the screen edge glow: it lights up along the edges, travels inward and fades.
const _edgeDuration = Duration(milliseconds: 2200);

const _doneLifetime = Duration(seconds: 4);
const _failedLifetime = Duration(seconds: 7);

/// After a click the card shows "opening" for this long, so the user sees it reacted
/// while the target application starts (Photos needs about a second).
const _openingLinger = Duration(milliseconds: 900);

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
  final String openingLabel;

  const _Palette({
    required this.surface,
    required this.text,
    required this.muted,
    required this.accent,
    required this.frame,
    required this.doneLabel,
    required this.failedLabel,
    required this.openingLabel,
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
    openingLabel: 'Opening…',
  );

  static const error = Color(0xFFE5484D);

  /// The colors of the screen edge glow: the frame color plus three hues around it,
  /// so every theme gets its own harmonic "few colors".
  List<Color> get edgeColors {
    final base = HSLColor.fromColor(frame);
    final saturation = base.saturation < 0.15 ? base.saturation : base.saturation.clamp(0.7, 1.0);
    HSLColor shifted(double degrees, double lightness) => HSLColor.fromAHSL(1, (base.hue + degrees) % 360, saturation, lightness);
    return [
      frame,
      shifted(40, 0.62).toColor(),
      shifted(-50, 0.60).toColor(),
      shifted(175, 0.62).toColor(),
    ];
  }
}

class _OverlayApp extends StatefulWidget {
  const _OverlayApp();

  @override
  State<_OverlayApp> createState() => _OverlayAppState();
}

class _OverlayAppState extends State<_OverlayApp> with TickerProviderStateMixin {
  static const _window = MethodChannel(kOverlayWindowChannel);

  final _port = ReceivePort();
  final _cards = <_CardModel>[];
  SendPort? _mainPort;
  _Palette _palette = _Palette.fallback;

  /// Slow "breathing" of the frame glow. Only runs while something is being received,
  /// so a finished card costs no frames while it waits to disappear.
  late final AnimationController _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  /// The multi-color glow along the screen edges that greets an incoming transfer.
  late final AnimationController _edge = AnimationController(vsync: this, duration: _edgeDuration)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        // Shrink the window region back to the cards (or to nothing).
        _lastRegion = const [];
        if (_cards.isEmpty) {
          // ignore: discarded_futures
          _window.invokeMethod<void>('setRegion', {'rects': const <int>[]});
        } else {
          SchedulerBinding.instance.scheduleFrame();
        }
      }
    });

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
            openingLabel: message.length > 9 ? message[9] as String : _Palette.fallback.openingLabel,
          );
        });
      case kMsgAdd:
        if (!_edge.isAnimating) {
          // ignore: discarded_futures
          _edge.forward(from: 0);
        }
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
    if (_cards.isEmpty && !_edge.isAnimating) {
      _lastRegion = const [];
      _visible = false;
      // ignore: discarded_futures
      _window.invokeMethod<void>('setRegion', {'rects': const <int>[]});
      _mainPort?.send([kMsgIdle]);
    }
  }

  /// Keeps the window region equal to the cards (plus their glow, plus the edge
  /// band while the edge glow plays): the rest of the overlay window is neither
  /// painted nor clickable.
  void _updateRegion() {
    if (_cards.isEmpty && !_edge.isAnimating) {
      return;
    }
    final view = PlatformDispatcher.instance.views.first;
    final dpr = view.devicePixelRatio;
    final region = <int>[];
    if (_edge.isAnimating) {
      final w = view.physicalSize.width.round();
      final h = view.physicalSize.height.round();
      final band = (_edgeBand * dpr).round();
      region.addAll([0, 0, w, band, 0, h - band, w, h, 0, 0, band, h, w - band, 0, w, h]);
    }
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
    _edge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(
        style: TextStyle(
          fontFamily: 'Inter',
          fontFamilyFallback: const ['Segoe UI'],
          color: _palette.text,
          fontSize: 14,
          letterSpacing: -0.1,
          decoration: TextDecoration.none,
        ),
        // Everything outside the cards (and the edge glow) stays fully transparent.
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(painter: _EdgeGlowPainter(_edge, _palette.edgeColors)),
                ),
              ),
            ),
            Center(
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
          ],
        ),
      ),
    );
  }
}

/// The greeting of an incoming transfer: a few colors light up along all four
/// screen edges, rotate slowly, then travel inward and dissolve.
class _EdgeGlowPainter extends CustomPainter {
  final Animation<double> progress;
  final List<Color> colors;

  _EdgeGlowPainter(this.progress, this.colors) : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0 || t >= 1) {
      return;
    }

    // 0..0.15 light up, 0.15..0.40 hold at the edge, 0.40..1 move inward while fading.
    final fadeIn = Curves.easeOut.transform((t / 0.15).clamp(0.0, 1.0));
    final travel = Curves.easeInOutCubic.transform(((t - 0.40) / 0.60).clamp(0.0, 1.0));
    final opacity = fadeIn * (1 - travel);
    if (opacity <= 0.001) {
      return;
    }

    final inset = 6 + 120 * travel;
    final rect = (Offset.zero & size).deflate(inset);
    final shader = SweepGradient(
      colors: [...colors, colors.first].map((c) => c.withValues(alpha: c.a * opacity)).toList(),
      transform: GradientRotation(t * 2.4),
    ).createShader(Offset.zero & size);

    // Wide, soft band: the glow that fades toward the middle of the screen.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 46 + 30 * travel
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 34),
    );
  }

  @override
  bool shouldRepaint(_EdgeGlowPainter oldDelegate) => !listEquals(oldDelegate.colors, colors);
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

  /// The card was clicked and the file is being opened.
  bool _opening = false;

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
    if (_opening) {
      return;
    }
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
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: -0.3),
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
              _ when _opening => Row(
                children: [
                  Icon(Icons.open_in_new_rounded, size: 16, color: palette.accent),
                  const SizedBox(width: 6),
                  Text(
                    palette.openingLabel,
                    style: TextStyle(color: palette.accent, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
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
          if (_opening) {
            return;
          }
          widget.onOpen();
          // Immediate feedback: the card presses in and says "opening" while the
          // target application starts, then goes away.
          _dismissTimer?.cancel();
          setState(() => _opening = true);
          _dismissTimer = Timer(_openingLinger, dismiss);
        },
        onSecondaryTap: widget.onReveal,
        child: AnimatedScale(
          scale: _opening ? 0.97 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
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
