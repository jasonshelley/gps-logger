import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../main.dart';

/// A small drawing of a trip's route, for the trip list.
class RouteThumbnail extends StatefulWidget {
  const RouteThumbnail({super.key, required this.trip, this.size = 84});
  final Trip trip;
  final double size;

  @override
  State<RouteThumbnail> createState() => _RouteThumbnailState();
}

class _RouteThumbnailState extends State<RouteThumbnail> {
  Future<List<(double, double)>>? _pts;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pts ??= AppScope.of(context).repo.routePreview(widget.trip);
  }

  @override
  void didUpdateWidget(RouteThumbnail old) {
    super.didUpdateWidget(old);
    if (old.trip.stats.endMs != widget.trip.stats.endMs) {
      _pts = AppScope.of(context).repo.routePreview(widget.trip);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: FutureBuilder(
        future: _pts,
        builder: (context, snap) {
          final pts = snap.data;
          if (pts == null || pts.length < 2) {
            return Icon(Icons.route_rounded, color: cs.onSurfaceVariant.withValues(alpha: 0.5));
          }
          return CustomPaint(painter: _RoutePainter(pts, cs.primary));
        },
      ),
    );
  }
}

class _RoutePainter extends CustomPainter {
  _RoutePainter(this.pts, this.color);
  final List<(double, double)> pts;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    var minLat = double.infinity, maxLat = -double.infinity;
    var minLon = double.infinity, maxLon = -double.infinity;
    for (final (lat, lon) in pts) {
      minLat = math.min(minLat, lat);
      maxLat = math.max(maxLat, lat);
      minLon = math.min(minLon, lon);
      maxLon = math.max(maxLon, lon);
    }
    // Equirectangular projection, corrected for latitude so shapes aren't squashed.
    final k = math.cos((minLat + maxLat) / 2 * math.pi / 180);
    final w = math.max((maxLon - minLon) * k, 1e-9), h = math.max(maxLat - minLat, 1e-9);
    const pad = 12.0;
    final scale = math.min((size.width - 2 * pad) / w, (size.height - 2 * pad) / h);
    final ox = (size.width - w * scale) / 2, oy = (size.height - h * scale) / 2;
    Offset map((double, double) p) => Offset(ox + (p.$2 - minLon) * k * scale, oy + (maxLat - p.$1) * scale);

    final path = Path()..moveTo(map(pts.first).dx, map(pts.first).dy);
    for (final p in pts.skip(1)) {
      final o = map(p);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round);
    canvas.drawCircle(map(pts.first), 3.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RoutePainter old) => old.pts != pts || old.color != color;
}
