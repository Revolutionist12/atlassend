import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme_provider.dart';
import 'package:localsend_app/atlassend/ui/atlas_widgets.dart';
import 'package:logging/logging.dart';

final _logger = Logger('LiquidGlassBar');

/// One entry of a [LiquidGlassBar].
class LiquidGlassItem {
  final String label;
  final IconData? icon;

  const LiquidGlassItem(this.label, {this.icon});
}

/// A capsule bar whose selection is a "liquid glass" lens: while pressed or
/// dragged a glass drop appears, follows the finger on springs, stretches with
/// speed, refracts and disperses the labels under its rim, and settles on the
/// nearest item when released.
///
/// Port of the user's "Liquid Glass Tab Bar" design. The bar is rendered into
/// an image every animated frame and the lens is a fragment shader over it
/// (shaders/liquid_glass.frag), exactly like the original WebGL version.
class LiquidGlassBar extends StatefulWidget {
  final List<LiquidGlassItem> items;
  final int selected;
  final ValueChanged<int> onSelect;

  /// Floating tab bar (icon above a small label, frosted body) or an inline
  /// segmented control (text only, solid body).
  final bool floating;

  const LiquidGlassBar({
    required this.items,
    required this.selected,
    required this.onSelect,
    this.floating = true,
    super.key,
  });

  /// Height of the floating bar, for content insets.
  static const floatingHeight = 64.0;

  @override
  State<LiquidGlassBar> createState() => _LiquidGlassBarState();
}

/// Margin around the bar inside the painted area, so the lens and its shadow can overflow.
const _m = 26.0;
const _padX = 5.0;

class _Spring {
  double v;
  double vel = 0;
  double t;

  _Spring(this.v) : t = v;

  void step(double k, double d, double dt) {
    vel += (-k * (v - t) - d * vel) * dt;
    v += vel * dt;
  }

  bool get settled => (v - t).abs() < 0.01 && vel.abs() < 0.01;
}

class _LiquidGlassBarState extends State<LiquidGlassBar> with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram?>? _program;

  ui.FragmentShader? _shader;
  late final Ticker _ticker = createTicker(_onTick);
  Duration? _lastTick;

  final _cx = _Spring(0);
  final _w = _Spring(0);
  final _bx = _Spring(0);
  final _bw = _Spring(0);
  final _press = _Spring(0);
  final _stretch = _Spring(0);
  double _breath = 0;

  bool _dragging = false;
  bool _moved = false;
  double _downX = 0;
  double _px = 0;
  int? _pending; // selection chosen by the user, shown until the parent confirms it

  double _barWidth = 0;
  bool _initialized = false;

  double get _h => widget.floating ? LiquidGlassBar.floatingHeight : 40.0;

  @override
  void initState() {
    super.initState();
    _program ??= ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag').then<ui.FragmentProgram?>((p) => p).catchError((Object e) {
      _logger.warning('Liquid glass shader unavailable, using the plain lens', e);
      return null;
    });
    // ignore: discarded_futures
    _program!.then((program) {
      if (mounted && program != null) {
        setState(() => _shader = program.fragmentShader());
      }
    });
  }

  @override
  void didUpdateWidget(LiquidGlassBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected && !_dragging) {
      _pending = null;
      _snap(widget.selected);
      _ensureTicking();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _shader?.dispose();
    super.dispose();
  }

  // --- geometry (bar-local coordinates, origin at the bar's top left) -------

  double get _itemWidth => (_barWidth - 2 * _padX) / widget.items.length;

  double _center(int i) => _padX + _itemWidth * (i + 0.5);

  int _nearest(double x) => ((x - _padX) / _itemWidth).floor().clamp(0, widget.items.length - 1);

  double _clampX(double x, double w) => x.clamp(_padX + w / 2 - 8, _barWidth - _padX - w / 2 + 8);

  void _snap(int i) {
    _cx.t = _bx.t = _center(i);
    _w.t = _bw.t = _itemWidth;
  }

  void _layout(double width) {
    if (width == _barWidth && _initialized) {
      return;
    }
    _barWidth = width;
    _snap(_pending ?? widget.selected);
    _cx.v = _cx.t;
    _bx.v = _bx.t;
    _w.v = _w.t;
    _bw.v = _bw.t;
    _initialized = true;
  }

  /// Bar transform while pressed: the bar swells and leans toward the finger.
  ({double s, double sy, double tx}) get _transform {
    final p = math.max(0.0, _press.v);
    final lean = (_cx.v - _barWidth / 2) / (_barWidth / 2);
    return (s: 1 + 0.03 * p, sy: 1 + 0.045 * p, tx: lean * 7 * p);
  }

  double _toBarX(double canvasX) {
    final t = _transform;
    return (canvasX - _m - _barWidth / 2 - t.tx) / t.s + _barWidth / 2;
  }

  // --- input ------------------------------------------------------------------

  void _onDown(PointerDownEvent e) {
    _dragging = true;
    _moved = false;
    _downX = _px = _toBarX(e.localPosition.dx);
    _press.t = 1;
    final i = _nearest(_px);
    _cx.t = _bx.t = _center(i);
    _w.t = _bw.t = _itemWidth;
    _ensureTicking();
  }

  void _onMove(PointerMoveEvent e) {
    if (!_dragging) {
      return;
    }
    _px = _toBarX(e.localPosition.dx);
    if ((_px - _downX).abs() > 4) {
      _moved = true;
    }
    if (_moved) {
      _cx.t = _clampX(_px, _w.v);
      _w.t = _itemWidth;
      _bx.t = _cx.t;
      _bw.t = _w.t;
    }
  }

  void _onUp() {
    if (!_dragging) {
      return;
    }
    _dragging = false;
    final i = _nearest(_moved ? _cx.v : _px);
    _press.t = 0;
    _snap(i);
    if (i != (_pending ?? widget.selected)) {
      // ignore: discarded_futures
      HapticFeedback.selectionClick();
      _pending = i;
      widget.onSelect(i);
    }
    _ensureTicking();
  }

  // --- animation --------------------------------------------------------------

  void _ensureTicking() {
    if (!_ticker.isActive) {
      _lastTick = null;
      // ignore: discarded_futures
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final last = _lastTick ?? elapsed;
    _lastTick = elapsed;
    final frame = math.min(0.033, (elapsed - last).inMicroseconds / 1e6);
    final dt = frame / 4;
    for (var k = 0; k < 4; k++) {
      _cx.step(_dragging ? 700 : 340, _dragging ? 46 : 29, dt);
      _w.step(380, 32, dt);
      _bx.step(_dragging ? 260 : 300, 30, dt); // the colored track lags the glass a little
      _bw.step(300, 30, dt);
      _press.step(_press.t > 0 ? 480 : 230, _press.t > 0 ? 30 : 25, dt);
      _stretch.t = math.min(0.55, _cx.vel.abs() / 1500); // faster -> longer
      _stretch.step(160, 11, dt); // under-damped: stretches, then wobbles back
    }
    _breath += frame;
    setState(() {});

    final settled = !_dragging && [_cx, _w, _bx, _bw, _press, _stretch].every((s) => s.settled);
    if (settled) {
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    final palette = _BarPalette(
      body: widget.floating ? theme.surface.withValues(alpha: theme.isDark ? 0.82 : 0.86) : theme.surface,
      highlight: theme.isDark ? const Color(0x09FFFFFF) : const Color(0x00FFFFFF),
      rim: theme.isDark ? const Color(0x21FFFFFF) : const Color(0x14000000),
      pill: theme.isDark ? Color.alphaBlend(const Color(0x99000000), theme.surface) : const Color(0x12000000),
      text: theme.text,
      selected: theme.accent.computeLuminance() > 0.85 && theme.isDark ? AppleColors.blue : theme.accent,
      glassFill: theme.isDark ? const Color(0x14FFFFFF) : const Color(0x22FFFFFF),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        _layout(constraints.maxWidth);
        final h = _h;
        final t = _transform;
        final p = math.max(0.0, _press.v);
        final pc = math.min(1.0, p);
        final br = _dragging ? math.sin(_breath * math.pi * 2 / 2.2) * 0.014 * pc : 0.0;
        final lw = (_w.v + 18 * p) * (1 + _stretch.v) * (1 + br) * t.s;
        final lh = ((h - 8) + 22 * p) * (1 - _stretch.v * 0.32) * (1 + br * 0.7) * t.sy;
        final lens = Rect.fromCenter(
          center: Offset(_m + _barWidth / 2 + (_cx.v - _barWidth / 2) * t.s + t.tx, _m + h / 2),
          width: lw,
          height: lh,
        );

        final painter = _LiquidGlassPainter(
          items: widget.items,
          floating: widget.floating,
          barWidth: _barWidth,
          height: h,
          cx: _cx.v,
          w: _w.v,
          bx: _bx.v,
          bw: _bw.v,
          pressed: pc,
          transform: t,
          lens: lens,
          shader: _shader,
          palette: palette,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );

        final paint = Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: (_) => _onUp(),
          onPointerCancel: (_) => _onUp(),
          child: CustomPaint(size: Size(_barWidth + 2 * _m, h + 2 * _m), painter: painter),
        );

        return SizedBox(
          width: _barWidth,
          height: h,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (widget.floating)
                // Frosted body: whatever scrolls behind the bar is blurred.
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(h / 2),
                    child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22), child: const SizedBox.expand()),
                  ),
                ),
              Positioned(left: -_m, top: -_m, child: paint),
            ],
          ),
        );
      },
    );
  }
}

class _BarPalette {
  final Color body;
  final Color highlight;
  final Color rim;
  final Color pill;
  final Color text;
  final Color selected;
  final Color glassFill;

  const _BarPalette({
    required this.body,
    required this.highlight,
    required this.rim,
    required this.pill,
    required this.text,
    required this.selected,
    required this.glassFill,
  });
}

class _LiquidGlassPainter extends CustomPainter {
  final List<LiquidGlassItem> items;
  final bool floating;
  final double barWidth;
  final double height;
  final double cx;
  final double w;
  final double bx;
  final double bw;
  final double pressed;
  final ({double s, double sy, double tx}) transform;
  final Rect lens;
  final ui.FragmentShader? shader;
  final _BarPalette palette;
  final double devicePixelRatio;

  _LiquidGlassPainter({
    required this.items,
    required this.floating,
    required this.barWidth,
    required this.height,
    required this.cx,
    required this.w,
    required this.bx,
    required this.bw,
    required this.pressed,
    required this.transform,
    required this.lens,
    required this.shader,
    required this.palette,
    required this.devicePixelRatio,
  });

  RRect _pillRect(double center, double width) =>
      RRect.fromRectAndRadius(Rect.fromLTWH(center - width / 2, 4, width, height - 8), Radius.circular((height - 8) / 2));

  void _labels(Canvas c, Color color) {
    final itemW = (barWidth - 2 * _padX) / items.length;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final mx = _padX + itemW * (i + 0.5);
      if (floating && item.icon != null) {
        final icon = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(item.icon!.codePoint),
            style: TextStyle(fontFamily: item.icon!.fontFamily, package: item.icon!.fontPackage, fontSize: 25, color: color, height: 1),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        icon.paint(c, Offset(mx - icon.width / 2, height / 2 - 8 - icon.height / 2));
        final label = TextPainter(
          text: TextSpan(
            text: item.label,
            style: TextStyle(fontFamily: 'Inter', fontSize: 10.5, fontWeight: FontWeight.w500, color: color, letterSpacing: -0.1),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout(maxWidth: itemW - 8);
        label.paint(c, Offset(mx - label.width / 2, height / 2 + 17 - label.height / 2));
      } else {
        final label = TextPainter(
          text: TextSpan(
            text: item.label,
            style: TextStyle(fontFamily: 'Inter', fontSize: 13.5, fontWeight: FontWeight.w600, color: color, letterSpacing: -0.2),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: itemW - 12);
        label.paint(c, Offset(mx - label.width / 2, height / 2 - label.height / 2));
      }
    }
  }

  /// The bar without the lens, in painted-area coordinates.
  void _scene(Canvas c) {
    final t = transform;
    c.save();
    c.translate(_m + barWidth / 2 + t.tx, _m + height / 2);
    c.scale(t.s, t.sy);
    c.translate(-barWidth / 2, -height / 2);

    final body = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, barWidth, height), Radius.circular(height / 2));
    c.drawRRect(body, Paint()..color = palette.body);
    c.save();
    c.clipRRect(body);
    c.drawRect(
      Rect.fromLTWH(0, 0, barWidth, height),
      Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(0, height), [palette.highlight, palette.highlight.withValues(alpha: 0)]),
    );
    c.restore();
    c.drawRRect(
      body.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = palette.rim,
    );

    // Resting pill, fading out as the glass takes over.
    if (pressed < 1) {
      c.drawRRect(_pillRect(cx, w), Paint()..color = palette.pill.withValues(alpha: palette.pill.a * (1 - pressed)));
    }

    _labels(c, palette.text);
    // Selected color, clipped to the (lagging) selection track.
    c.save();
    c.clipRRect(_pillRect(bx, bw));
    _labels(c, palette.selected);
    c.restore();
    c.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final shader = this.shader;
    if (pressed <= 0.001) {
      _scene(canvas);
      return;
    }
    if (shader == null) {
      // No shader support: a plain translucent drop instead of refraction.
      _scene(canvas);
      final r = RRect.fromRectAndRadius(lens, Radius.circular(math.min(lens.width, lens.height) / 2));
      canvas.drawRRect(r, Paint()..color = palette.glassFill.withValues(alpha: palette.glassFill.a * pressed));
      canvas.drawRRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = const Color(0x40FFFFFF).withValues(alpha: 0.25 * pressed),
      );
      return;
    }

    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder)..scale(devicePixelRatio);
    _scene(c);
    final image = recorder.endRecording().toImageSync(
      (size.width * devicePixelRatio).ceil(),
      (size.height * devicePixelRatio).ceil(),
    );

    final t = transform;
    final fill = palette.glassFill;
    const rim = Color(0xFF808080);
    var i = 0;
    void f(double v) => shader.setFloat(i++, v);
    f(size.width); // res
    f(size.height);
    f(lens.center.dx); // lc
    f(lens.center.dy);
    f(lens.width / 2); // lb
    f(lens.height / 2);
    f(math.min(lens.width, lens.height) / 2); // lr
    f(pressed); // a
    f(_m + barWidth / 2 + t.tx); // bc
    f(_m + height / 2);
    f(barWidth / 2 * t.s); // bb
    f(height / 2 * t.sy);
    f(height / 2 * math.min(t.s, t.sy)); // br
    f(fill.r * fill.a); // fill (premultiplied)
    f(fill.g * fill.a);
    f(fill.b * fill.a);
    f(fill.a);
    f(rim.r); // rimCol
    f(rim.g);
    f(rim.b);
    f(1);
    shader.setImageSampler(0, image);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    image.dispose();
  }

  @override
  bool shouldRepaint(_LiquidGlassPainter old) => true;
}
