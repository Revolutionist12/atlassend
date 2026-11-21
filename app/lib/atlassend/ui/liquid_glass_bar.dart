import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:localsend_app/atlassend/theme/atlas_theme_provider.dart';
import 'package:localsend_app/atlassend/ui/atlas_widgets.dart';
import 'package:logging/logging.dart';

final _logger = Logger('LiquidGlassBar');

/// One entry of a [LiquidGlassBar]: a label and, in the floating bar, an icon above it.
class LiquidGlassItem {
  final String label;
  final IconData? icon;

  const LiquidGlassItem(this.label, {this.icon});
}

/// iOS 26 style tab bar whose selection is a "liquid glass" lens.
///
/// Port of the AtlasSend liquid glass study (C:\dev\liquid-glass-tabbar, index.html),
/// which was tuned frame by frame against a screen recording of the iOS 26 App Store bar:
/// - rest: dark capsule, the selected tab sits on a darker pill, its icon and label in the accent color;
/// - press: the bar swells (x 1.03, y 1.045) and leans toward the finger, the pill turns into a
///   glass lens 18 px wider and 22 px taller than the tab, overflowing the bar above and below;
/// - drag: the lens follows the finger on springs, its width eases between the tabs, it stretches
///   with speed and wobbles back, and "breathes" slowly while held; the accent layer lags behind;
/// - release: the lens snaps to the nearest tab and fades back into the pill.
///
/// The floating bar never leaves the screen: swell and lean are limited by [edgeRoom].
/// The inline variant ([floating] false) is a slim segmented control that does not swell.
class LiquidGlassBar extends StatefulWidget {
  final List<LiquidGlassItem> items;
  final int selected;
  final ValueChanged<int> onSelect;

  /// Floating tab bar (icon + label, swells) or an inline segmented control (text, still).
  final bool floating;

  /// Stretch the tabs to the available width instead of sizing them to their labels.
  final bool expand;

  /// Free space between the bar and the screen edge; nothing the bar draws may cross it.
  final double edgeRoom;

  const LiquidGlassBar({
    required this.items,
    required this.selected,
    required this.onSelect,
    this.floating = true,
    this.expand = false,
    this.edgeRoom = 14,
    super.key,
  });

  /// Height of the floating bar, for content insets.
  static const floatingHeight = 64.0;

  @override
  State<LiquidGlassBar> createState() => _LiquidGlassBarState();
}

/// Margin around the bar inside the painted area, so the lens and its shadow can overflow.
const _m = 34.0;
const _padX = 5.0;

// Floating bar typography (from the study): label 11 px, shrinking in 0.25 px steps to 9 px.
const _labelMax = 11.0;
const _labelMin = 9.0;
const _side = 24.0; // air beside a label inside its tab
const _sideMin = 18.0;
const _icon = 24.0;
const _iconGap = 3.5;

/// How far the glass may poke past the bar ends (study: <= 8, recording: about 3-5).
const _over = 6.0;

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

/// Bar transform while pressed: swell and lean toward the finger.
class _BarTransform {
  final double s;
  final double sy;
  final double tx;

  const _BarTransform(this.s, this.sy, this.tx);

  static const identity = _BarTransform(1, 1, 0);
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
  double _labelPx = _labelMax;
  String _layoutKey = '';
  _BarTransform _t = _BarTransform.identity;

  bool get _floating => widget.floating;

  double get _h => _floating ? LiquidGlassBar.floatingHeight : 40.0;

  TextStyle _labelStyle(double px) => TextStyle(
    fontFamily: 'Inter',
    fontSize: px,
    fontWeight: FontWeight.w500,
    letterSpacing: px * 0.01,
    height: 1.0,
  );

  TextStyle get _style => _floating ? _labelStyle(_labelPx) : _labelStyle(14.5).copyWith(letterSpacing: -0.1);

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

  double _measure(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  void _layout(double maxWidth) {
    final key = '${widget.items.map((i) => i.label).join('|')}/$_floating/${widget.expand}/${maxWidth.round()}';
    if (key == _layoutKey) {
      return;
    }
    _layoutKey = key;
    final avail = maxWidth - 2 * _padX;
    List<double> ws;
    if (_floating) {
      // Shrink the label until every tab fits, then take air from beside the labels.
      var px = _labelMax;
      var side = _side;
      List<double> need;
      for (;;) {
        final style = _labelStyle(px);
        need = [for (final item in widget.items) _measure(item.label, style).ceilToDouble() + side];
        if (need.fold(0.0, (a, b) => a + b) <= avail) {
          break;
        }
        if (px > _labelMin) {
          px -= 0.25;
        } else if (side > _sideMin) {
          side -= 1;
        } else {
          break;
        }
      }
      _labelPx = px;
      final sum = need.fold(0.0, (a, b) => a + b);
      final extra = widget.expand ? math.max(0.0, avail - sum) / need.length : 0.0; // leftover shared equally
      ws = [for (final n in need) n + extra];
    } else {
      const itemPad = 18.0;
      final style = _style;
      ws = [for (final item in widget.items) (_measure(item.label, style) + itemPad * 2).roundToDouble()];
      final sum = ws.fold(0.0, (a, b) => a + b);
      if (widget.expand || sum > avail) {
        ws = widget.expand ? [for (final _ in ws) avail / ws.length] : [for (final w in ws) w * avail / sum];
      }
    }
    var x = _padX;
    _xs = [];
    for (final w in ws) {
      _xs.add(x);
      x += w;
    }
    _ws = ws;
    _barWidth = math.min(maxWidth, x + _padX);
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

  double get _extraW => _floating ? 18 : 6;

  /// Past the end tabs the finger is rubber-banded, so the glass pokes past the bar
  /// ends by at most [_over].
  double _clampX(double x, double w) {
    final half = (w + _extraW) / 2;
    final lo = _padX + w / 2;
    final hi = _barWidth - _padX - w / 2;
    final give = math.max(0.0, _over - (half - w / 2 - _padX));
    double rub(double e) => give * (1 - math.exp(-e / 40));
    if (x < lo) {
      return lo - rub(lo - x);
    }
    if (x > hi) {
      return hi + rub(x - hi);
    }
    return x;
  }

  void _snap(int i) {
    _cx.t = _bx.t = _center(i);
    _w.t = _bw.t = _ws[i];
  }

  // --- input ------------------------------------------------------------------

  /// Pointer (painted-area coordinates) -> bar-local x, undoing the swell and lean.
  double _toBarX(double canvasX) => (canvasX - _m - _barWidth / 2 - _t.tx) / _t.s + _barWidth / 2;

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
      _bx.step(_dragging ? 260 : 300, 30, dt); // the accent layer lags the glass
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

  /// Swell and lean, limited so that the bar plus the overhanging glass stay [LiquidGlassBar.edgeRoom] - 2 px
  /// inside the screen edge.
  _BarTransform _transform(double p) {
    if (!_floating || p <= 0) {
      return _BarTransform.identity;
    }
    final room = math.max(0.0, widget.edgeRoom - 2 - _over);
    var s = 1 + 0.03 * p;
    if (_barWidth * (s - 1) / 2 > room) {
      s = 1 + 2 * room / _barWidth;
    }
    final txMax = math.max(0.0, room - _barWidth * (s - 1) / 2);
    final lean = ((_cx.v - _barWidth / 2) / (_barWidth / 2)).clamp(-1.0, 1.0);
    final tx = (lean * 7 * p).clamp(-txMax, txMax);
    return _BarTransform(s, 1 + 0.045 * p, tx);
  }

  @override
  Widget build(BuildContext context) {
    final theme = atlasOf(context);
    final dark = theme.isDark;
    final palette = _BarPalette(
      // Translucent: what lies behind the bar shows through, softly blurred (iOS chrome).
      body: dark ? const Color(0xA61D1D1D) : const Color(0xB8F7F7F7),
      lift: dark ? const Color(0x0DFFFFFF) : const Color(0x0A000000),
      rimTop: dark ? const Color(0x3DFFFFFF) : const Color(0x1F000000),
      rimBottom: dark ? const Color(0x36FFFFFF) : const Color(0x17000000),
      pill: dark ? const Color(0xCC0C0C0C) : const Color(0x1A000000),
      pillRim: dark ? const Color(0x0FFFFFFF) : const Color(0x0A000000),
      text: dark ? const Color(0xFFF7F7F7) : theme.text,
      selected: theme.accent.computeLuminance() > 0.85 && dark ? AppleColors.blue : theme.accent,
      // Where the glass hangs past the bar it shows a darkened band, like the recording.
      outside: dark ? const Color(0x66000000) : const Color(0x26000000),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        _layout(constraints.maxWidth.isFinite ? constraints.maxWidth : 600);
        final h = _h;
        final p = math.max(0.0, _press.v);
        final pc = math.min(1.0, p);
        _t = _transform(p);
        final t = _t;
        final br = _dragging ? math.sin(_breath * math.pi * 2 / 2.2) : 0.0; // slow breathing while held
        final double lw;
        final double lh;
        if (_floating) {
          lw = (_w.v + 18 * p) * (1 + _stretch.v) * (1 + 0.014 * br * pc) * t.s;
          lh = ((h - 8) + 22 * p) * (1 - _stretch.v * 0.32) * (1 + 0.010 * br * pc) * t.sy;
        } else {
          lw = (_w.v + 6 * p) * (1 + _stretch.v * 0.7) * (1 + 0.012 * br * pc);
          lh = ((h - 10) + 6 * p) * (1 - _stretch.v * 0.3) * (1 + 0.008 * br * pc);
        }
        final lens = Rect.fromCenter(
          center: Offset(_m + _barWidth / 2 + (_cx.v - _barWidth / 2) * t.s + t.tx, _m + h / 2),
          width: lw,
          height: lh,
        );

        final painter = _LiquidGlassPainter(
          items: widget.items,
          style: _style,
          floating: _floating,
          xs: _xs,
          ws: _ws,
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

        return SizedBox(
          width: _barWidth,
          height: h,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Frosted backdrop under the capsule, following the swell and lean.
              Positioned.fill(
                child: IgnorePointer(
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.translationValues(t.tx, 0, 0)..scaleByDouble(t.s, t.sy, 1.0, 1.0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(h / 2),
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
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
  final Color lift;
  final Color rimTop;
  final Color rimBottom;
  final Color pill;
  final Color pillRim;
  final Color text;
  final Color selected;
  final Color outside;

  const _BarPalette({
    required this.body,
    required this.lift,
    required this.rimTop,
    required this.rimBottom,
    required this.pill,
    required this.pillRim,
    required this.text,
    required this.selected,
    required this.outside,
  });
}

class _LiquidGlassPainter extends CustomPainter {
  final List<LiquidGlassItem> items;
  final TextStyle style;
  final bool floating;
  final List<double> xs;
  final List<double> ws;
  final double barWidth;
  final double height;
  final double cx;
  final double w;
  final double bx;
  final double bw;
  final double pressed;
  final _BarTransform transform;
  final Rect lens;
  final ui.FragmentShader? shader;
  final _BarPalette palette;
  final double devicePixelRatio;

  _LiquidGlassPainter({
    required this.items,
    required this.style,
    required this.floating,
    required this.xs,
    required this.ws,
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

  double _snapPx(double v) => (v * devicePixelRatio).roundToDouble() / devicePixelRatio;

  RRect _pillRect(double center, double width) =>
      RRect.fromRectAndRadius(Rect.fromLTWH(center - width / 2, 4, width, height - 8), Radius.circular((height - 8) / 2));

  TextPainter _text(String text, TextStyle style, double maxWidth) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: math.max(0, maxWidth));

  void _content(Canvas c, Color color) {
    final labelStyle = style.copyWith(color: color);
    if (!floating) {
      for (var i = 0; i < items.length; i++) {
        final tp = _text(items[i].label, labelStyle, ws[i] - 8);
        tp.paint(c, Offset(_snapPx(xs[i] + ws[i] / 2 - tp.width / 2), _snapPx(height / 2 - tp.height / 2 + 1)));
      }
      return;
    }
    // Icon on top, small label below, the pair centered vertically.
    final labelH = style.fontSize ?? _labelMax;
    final top = (height - (_icon + _iconGap + labelH)) / 2;
    for (var i = 0; i < items.length; i++) {
      final mx = xs[i] + ws[i] / 2;
      final icon = items[i].icon;
      if (icon != null) {
        final ip = _text(
          String.fromCharCode(icon.codePoint),
          TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: _icon, height: 1.0, color: color),
          _icon * 2,
        );
        ip.paint(c, Offset(_snapPx(mx - ip.width / 2), _snapPx(top)));
      }
      final tp = _text(items[i].label, labelStyle, ws[i] - 8);
      tp.paint(c, Offset(_snapPx(mx - tp.width / 2), _snapPx(top + _icon + _iconGap)));
    }
  }

  /// The bar without the lens, in painted-area coordinates.
  void _scene(Canvas c) {
    c.save();
    c.translate(_m + barWidth / 2 + transform.tx, _m + height / 2);
    c.scale(transform.s, transform.sy);
    c.translate(-barWidth / 2, -height / 2);

    final body = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, barWidth, height), Radius.circular(height / 2));
    c.drawRRect(body, Paint()..color = palette.body);
    if (pressed > 0) {
      // While held the bar lifts toward the light (recording: grey 30 -> 41).
      c.drawRRect(body, Paint()..color = palette.lift.withValues(alpha: palette.lift.a * pressed));
    }
    // Hairline rim, one device pixel, brighter at the top.
    final hl = 1 / devicePixelRatio;
    c.drawRRect(
      body.deflate(hl / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = hl
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, height), [palette.rimTop, palette.rimBottom]),
    );

    // Resting pill, fading out as the glass takes over.
    if (pressed < 1) {
      final pill = _pillRect(cx, w);
      c.drawRRect(pill, Paint()..color = palette.pill.withValues(alpha: palette.pill.a * (1 - pressed)));
      c.drawRRect(
        pill,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = hl
          ..color = palette.pillRim.withValues(alpha: palette.pillRim.a * (1 - pressed)),
      );
    }

    _content(c, palette.text);
    // Accent color, clipped to the (lagging) selection track.
    c.save();
    c.clipRRect(_pillRect(bx, bw));
    _content(c, palette.selected);
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
      canvas.drawRRect(r, Paint()..color = const Color(0x14FFFFFF).withValues(alpha: 0.08 * pressed));
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

    final fill = palette.outside;
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
    f(_m + barWidth / 2 + transform.tx); // bc
    f(_m + height / 2);
    f(barWidth / 2 * transform.s); // bb
    f(height / 2 * transform.sy);
    f(height / 2 * math.min(transform.s, transform.sy)); // br
    f(fill.r * fill.a); // fill (premultiplied)
    f(fill.g * fill.a);
    f(fill.b * fill.a);
    f(fill.a);
    f(rim.r); // rimCol
    f(rim.g);
    f(rim.b);
    f(1);
    f(floating ? 18 : 10); // band: flat top/bottom (Ev)
    f(floating ? 14 : 10); //       rounded ends (Eh)
    shader.setImageSampler(0, image);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    image.dispose();
  }

  @override
  bool shouldRepaint(_LiquidGlassPainter old) => true;
}
