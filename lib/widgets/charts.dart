/// Small dependency-free charts (CustomPaint) used by Progress and the habit
/// detail screen.
///
/// * [LineChart]: values over time (e.g. words/min per practice session),
///   with min/max labels and first/last dates.
/// * [DailyBarChart]: one bar per day (e.g. minutes practised), with an
///   optional dashed target line.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

class ChartPoint {
  final DateTime at;
  final num value;
  const ChartPoint(this.at, this.value);
}

String formatChartValue(num v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

class LineChart extends StatelessWidget {
  final List<ChartPoint> points;
  final double height;
  final Color? color;
  const LineChart({super.key, required this.points, this.height = 120, this.color});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final sorted = [...points]..sort((a, b) => a.at.compareTo(b.at));
    final style = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final f = DateFormat('d MMM');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: height,
        child: CustomPaint(
          painter: _LinePainter(
            sorted,
            color ?? t.colorScheme.primary,
            t.colorScheme.outlineVariant,
            style ?? const TextStyle(fontSize: 11),
          ),
        ),
      ),
      if (sorted.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4, left: _LinePainter.axisWidth),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(f.format(sorted.first.at), style: style),
            if (sorted.length > 1) Text(f.format(sorted.last.at), style: style),
          ]),
        ),
    ]);
  }
}

class _LinePainter extends CustomPainter {
  static const axisWidth = 36.0;
  final List<ChartPoint> points;
  final Color color;
  final Color grid;
  final TextStyle labelStyle;
  _LinePainter(this.points, this.color, this.grid, this.labelStyle);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final lo = points.map((p) => p.value).reduce(math.min).toDouble();
    final hi = points.map((p) => p.value).reduce(math.max).toDouble();
    final span = hi - lo == 0 ? 1.0 : hi - lo;
    final chart = Rect.fromLTRB(axisWidth, 6, size.width - 6, size.height - 6);

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final y in [chart.top, chart.center.dy, chart.bottom]) {
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
    }
    _label(canvas, formatChartValue(hi), chart.top);
    if (hi != lo) _label(canvas, formatChartValue(lo), chart.bottom);

    final t0 = points.first.at.millisecondsSinceEpoch.toDouble();
    final tSpan = points.last.at.millisecondsSinceEpoch - t0;
    Offset at(ChartPoint p) => Offset(
          points.length == 1 || tSpan == 0
              ? chart.center.dx
              : chart.left + chart.width * (p.at.millisecondsSinceEpoch - t0) / tSpan,
          hi == lo ? chart.center.dy : chart.bottom - chart.height * (p.value - lo) / span,
        );
    final offsets = points.map(at).toList();
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    if (offsets.length > 1) canvas.drawPath(Path()..addPolygon(offsets, false), line);
    final dot = Paint()..color = color;
    for (final o in offsets) {
      canvas.drawCircle(o, 3, dot);
    }
  }

  void _label(Canvas canvas, String text, double y) {
    final tp = TextPainter(text: TextSpan(text: text, style: labelStyle), textDirection: TextDirection.ltr)
      ..layout(maxWidth: axisWidth - 4);
    tp.paint(canvas, Offset(axisWidth - 4 - tp.width, y - tp.height / 2));
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.points != points || old.color != color || old.grid != grid || old.labelStyle != labelStyle;
}

class DailyBarChart extends StatelessWidget {
  /// Oldest first, null where nothing was logged.
  final List<num?> values;
  final num? target;
  final double height;
  const DailyBarChart({super.key, required this.values, this.target, this.height = 80});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: CustomPaint(painter: _BarPainter(values, target, cs.primary, cs.outline), size: Size.infinite),
    );
  }
}

class _BarPainter extends CustomPainter {
  final List<num?> values;
  final num? target;
  final Color color;
  final Color targetColor;
  _BarPainter(this.values, this.target, this.color, this.targetColor);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final top = [...values.whereType<num>(), target ?? 0].fold<num>(0, math.max).toDouble();
    if (top <= 0) return;
    final slot = size.width / values.length;
    final bar = Paint()..color = color;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null || v <= 0) continue;
      final h = size.height * v / top;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * slot + slot * 0.15, size.height - h, slot * 0.7, h),
          const Radius.circular(2),
        ),
        bar,
      );
    }
    final goal = target;
    if (goal != null && goal > 0) {
      final y = size.height - size.height * goal / top;
      final dash = Paint()
        ..color = targetColor
        ..strokeWidth = 1;
      for (var x = 0.0; x < size.width; x += 8) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 4, size.width), y), dash);
      }
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.values != values || old.target != target || old.color != color || old.targetColor != targetColor;
}
