import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme_provider.dart';
import 'package:localsend_app/atlassend/ui/atlas_widgets.dart';
import 'package:logging/logging.dart';

final _logger = Logger('LiquidGlassBar');

/// One text entry of a [LiquidGlassBar].
class LiquidGlassItem {
  final String label;

  const LiquidGlassItem(this.label);
}

/// A capsule with text tabs whose selection is a "liquid glass" lens: while
/// pressed or dragged a glass drop appears, follows the finger on springs,
/// stretches with speed, refracts and disperses the labels under its rim, and
/// settles on the nearest tab when released. The capsule itself stays still.
///
/// Port of the user's "Liquid Glass Tab Bar" design (Liquid Glass Tab Bar.html):
/// same layout (width follows the labels), same spring model, same lens shader
/// (shaders/liquid_glass.frag, with a thinner rim). The bar is rendered into an
/// image every animated frame and the lens is a fragment shader over it.
class LiquidGlassBar extends StatefulWidget {
  final List<LiquidGlassItem> items;
  final int selected;
  final ValueChanged<int> onSelect;

  /// Floating bar (large labels, as in the design) or an inline control (smaller).
  final bool floating;

  /// Stretch the tabs to the available width instead of sizing them to their labels.
  final bool expand;

  const LiquidGlassBar({
    required this.items,
    required this.selected,
    required this.onSelect,
    this.floating = true,
    this.expand = false,
    super.key,
  });

  /// Height of the floating bar, for content insets.
  static const floatingHeight = 56.0;

  @override
  State<LiquidGlassBar> createState() => _LiquidGlassBarState();
}

/// Margin around the bar inside the painted area, so the lens and its shadow can overflow.
const _m = 22.0;
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

  // Layout (bar-local coordinates, origin at the bar's top left).
  List<double> _xs = const [];
  List<double> _ws = const [];
  double _barWidth = 0;
  String _layoutKey = '';

  double get _h => widget.floating ? LiquidGlassBar.floatingHeight : 40.0;

  TextStyle get _style => TextStyle(
    fontFamily: 'Inter',
    fontSize: widget.floating ? 19.5 : 14.5,
    fontWeight: FontWeight.w500,
    letterSpacing: widget.floating ? -0.2 : -0.1,
  );

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

  // --- layout -----------------------------------------------------------------

  double _measure(String text) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: _style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  void _layout(double maxWidth) {
    final key = '${widget.items.map((i) => i.label).join('|')}/${widget.floating}/${widget.expand}/${maxWidth.round()}';
    if (key == _layoutKey) {
      return;
    }
    _layoutKey = key;
    const itemPad = 18.0;
    var ws = [for (final item in widget.items) (_measure(item.label) + itemPad * 2).roundToDouble()];
    var total = ws.fold(0.0, (a, b) => a + b) + 2 * _padX;
    if (widget.expand || total > maxWidth) {
      final avail = maxWidth - 2 * _padX;
      final sum = ws.fold(0.0, (a, b) => a + b);
      ws = widget.expand ? [for (final _ in ws) avail / ws.length] : [for (final w in ws) w * avail / sum];
      total = maxWidth;
    }
    var x = _padX;
    _xs = [];
    for (final w in ws) {
      _xs.add(x);
      x += w;
    }
    _ws = ws;
    _barWidth = total;
    _snap(_pending ?? widget.selected);
    _cx.v = _cx.t;
    _bx.v = _bx.t;
    _w.v = _w.t;
    _bw.v = _bw.t;
  }

  double _center(int i) => _xs[i] + _ws[i] / 2;

  int _nearest(double x) {
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < _xs.length; i++) {
      final d = (_center(i) - x).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best;
  }

  /// Width of the lens at [x]: eased between the neighbouring tab widths.
  double _widthAt(double x) {
    if (x <= _center(0)) {
      return _ws.first;
    }
    for (var i = 0; i < _ws.length - 1; i++) {
      final a = _center(i);
      final b = _center(i + 1);
      if (x <= b) {
        var t = (x - a) / (b - a);
        t = t * t * (3 - 2 * t);
        return _ws[i] + (_ws[i + 1] - _ws[i]) * t;
      }
    }
    return _ws.last;
  }

  double _clampX(double x, double w) => x.clamp(_padX + w / 2 - 8, _barWidth - _padX - w / 2 + 8);

  void _snap(int i) {
    _cx.t = _bx.t = _center(i);
    _w.t = _bw.t = _ws[i];
  }

  // --- input ------------------------------------------------------------------

  /// Pointer (painted-area coordinates) -> bar-local x. The bar never moves.
  double _toBarX(double canvasX) => canvasX - _m;

  void _onDown(PointerDownEvent e) {
    _dragging = true;
    _moved = false;
    _downX = _px = _toBarX(e.localPosition.dx);
    _press.t = 1;
    final i = _nearest(_px);
    _cx.t = _bx.t = _center(i);
    _w.t = _bw.t = _ws[i];
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
      _w.t = _widthAt(_cx.t);
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
      _stretch.t = math.min(0.4, _cx.vel.abs() / 1800); // faster -> longer
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
      // Nearly clear: whatever lies behind the bar stays readable.
      body: theme.isDark ? const Color(0x2E1C1C1E) : const Color(0x33FFFFFF),
      rim: theme.isDark ? const Color(0x2EFFFFFF) : const Color(0x1F000000),
      pill: theme.isDark ? const Color(0x24FFFFFF) : const Color(0x14000000),
      text: theme.text,
      selected: theme.accent.computeLuminance() > 0.85 && theme.isDark ? AppleColors.blue : theme.accent,
      glassFill: theme.isDark ? const Color(0x0CFFFFFF) : const Color(0x14FFFFFF),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        _layout(constraints.maxWidth.isFinite ? constraints.maxWidth : 600);
        final h = _h;
        final p = math.max(0.0, _press.v);
        final pc = math.min(1.0, p);
        final br = _dragging ? math.sin(_breath * math.pi * 2 / 2.2) * 0.012 * pc : 0.0;
        // Slim drop: barely taller than the tabs' own pill.
        final lw = (_w.v + 6 * p) * (1 + _stretch.v) * (1 + br);
        final lh = ((h - 10) + 6 * p) * (1 - _stretch.v * 0.3) * (1 + br * 0.7);
        final lens = Rect.fromCenter(center: Offset(_m + _cx.v, _m + h / 2), width: lw, height: lh);

        final painter = _LiquidGlassPainter(
          items: widget.items,
          style: _style,
          xs: _xs,
          ws: _ws,
          barWidth: _barWidth,
          height: h,
          cx: _cx.v,
          w: _w.v,
          bx: _bx.v,
          bw: _bw.v,
          pressed: pc,
          lens: lens,
          shader: _shader,
          palette: palette,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );

        return SizedBox(
          width: _barWidth,
          height: h,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: -_m,
                top: -_m,
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _onDown,
                  onPointerMove: _onMove,
                  onPointerUp: (_) => _onUp(),
                  onPointerCancel: (_) => _onUp(),
                  child: CustomPaint(size: Size(_barWidth + 2 * _m, h + 2 * _m), painter: painter),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BarPalette {
  final Color body;
  final Color rim;
  final Color pill;
  final Color text;
  final Color selected;
  final Color glassFill;

  const _BarPalette({
    required this.body,
    required this.rim,
    required this.pill,
    required this.text,
    required this.selected,
    required this.glassFill,
  });
}

class _LiquidGlassPainter extends CustomPainter {
  final List<LiquidGlassItem> items;
  final TextStyle style;
  final List<double> xs;
  final List<double> ws;
  final double barWidth;
  final double height;
  final double cx;
  final double w;
  final double bx;
  final double bw;
  final double pressed;
  final Rect lens;
  final ui.FragmentShader? shader;
  final _BarPalette palette;
  final double devicePixelRatio;

  _LiquidGlassPainter({
    required this.items,
    required this.style,
    required this.xs,
    required this.ws,
    required this.barWidth,
    required this.height,
    required this.cx,
    required this.w,
    required this.bx,
    required this.bw,
    required this.pressed,
    required this.lens,
    required this.shader,
    required this.palette,
    required this.devicePixelRatio,
  });

  RRect _pillRect(double center, double width) =>
      RRect.fromRectAndRadius(Rect.fromLTWH(center - width / 2, 4, width, height - 8), Radius.circular((height - 8) / 2));

  void _labels(Canvas c, Color color) {
    for (var i = 0; i < items.length; i++) {
      final tp = TextPainter(
        text: TextSpan(
          text: items[i].label,
          style: style.copyWith(color: color),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: ws[i] - 8);
      tp.paint(c, Offset(xs[i] + ws[i] / 2 - tp.width / 2, height / 2 - tp.height / 2 + 1));
    }
  }

  /// The bar without the lens, in painted-area coordinates.
  void _scene(Canvas c) {
    c.save();
    c.translate(_m, _m);

    final body = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, barWidth, height), Radius.circular(height / 2));
    c.drawRRect(body, Paint()..color = palette.body);
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
    f(_m + barWidth / 2); // bc
    f(_m + height / 2);
    f(barWidth / 2); // bb
    f(height / 2);
    f(height / 2); // br
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
