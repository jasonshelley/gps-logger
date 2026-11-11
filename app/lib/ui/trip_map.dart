import 'dart:async';
import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../core/geo.dart';
import '../core/log_csv.dart';
import '../core/trips.dart';
import '../data/repository.dart';
import 'theme.dart';

/// OpenFreeMap: free vector tiles with no API key.
const _lightStyle = 'https://tiles.openfreemap.org/styles/positron';
const _darkStyle = 'https://tiles.openfreemap.org/styles/dark';

/// The trip map: speed-shaded route, start and end, catch pins per angler,
/// and the boat marker and reveal filters the replay drives.
class TripMap extends StatefulWidget {
  const TripMap({
    super.key,
    required this.data,
    required this.bottomPadding,
    this.onCatchTap,
  });

  final TripData data;

  /// Space covered by the bottom sheet, so the route fits above it.
  final double bottomPadding;
  final void Function(StoredCatch c)? onCatchTap;

  @override
  State<TripMap> createState() => TripMapState();
}

class TripMapState extends State<TripMap> {
  MapLibreMapController? _map;
  bool _styleReady = false;
  // Replay time wanted and last applied to the map; -1 means the whole trip.
  static const _whole = -1;
  int _want = _whole;
  int _have = _whole;
  bool _updating = false;

  static const _always = ['>=', ['get', 't'], 0];

  @override
  void dispose() {
    _map?.onFeatureTapped.clear();
    super.dispose();
  }

  // ---- GeoJSON ----

  Map<String, dynamic> _routeGeoJson() {
    final features = <Map<String, dynamic>>[];
    for (final seg in splitSegments(widget.data.points)) {
      // Runs of up to 8 legs with similar speed share one feature, which keeps
      // the feature count down while the replay can still reveal them smoothly.
      var run = <TrackPoint>[];
      int? bucket;
      void flush() {
        if (run.length < 2) return;
        final speeds = [for (final p in run) p.speedKmh ?? 0];
        final avg = speeds.reduce((a, b) => a + b) / speeds.length;
        features.add({
          'type': 'Feature',
          'properties': {'speed': avg, 't': run.last.t},
          'geometry': {
            'type': 'LineString',
            'coordinates': [for (final p in run) [p.lon, p.lat]],
          },
        });
      }

      for (final p in seg) {
        final b = ((p.speedKmh ?? 0) / 3).floor();
        if (run.isNotEmpty && (b != bucket || run.length >= 8)) {
          final last = run.last;
          flush();
          run = [last];
        }
        bucket = b;
        run.add(p);
      }
      flush();
    }
    return {'type': 'FeatureCollection', 'features': features};
  }

  Map<String, dynamic> _catchesGeoJson() => {
        'type': 'FeatureCollection',
        'features': [
          for (final c in widget.data.catches)
            if (c.event.hasPosition)
              {
                'type': 'Feature',
                'id': c.id,
                'properties': {
                  'id': c.id,
                  'angler': c.angler,
                  'color': colorHex(anglerColor(c.angler)),
                  't': c.event.t ?? 0,
                },
                'geometry': {
                  'type': 'Point',
                  'coordinates': [c.event.lon, c.event.lat],
                },
              }
        ],
      };

  Map<String, dynamic> _endsGeoJson() {
    final pts = widget.data.points;
    if (pts.isEmpty) return const {'type': 'FeatureCollection', 'features': []};
    Map<String, dynamic> f(TrackPoint p, String kind) => {
          'type': 'Feature',
          'properties': {'kind': kind},
          'geometry': {
            'type': 'Point',
            'coordinates': [p.lon, p.lat]
          },
        };
    return {
      'type': 'FeatureCollection',
      'features': [f(pts.first, 'start'), f(pts.last, 'end')],
    };
  }

  static Map<String, dynamic> _point(double lat, double lon) => {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': <String, dynamic>{},
            'geometry': {
              'type': 'Point',
              'coordinates': [lon, lat]
            },
          }
        ],
      };

  static const _empty = {'type': 'FeatureCollection', 'features': <dynamic>[]};

  // ---- Map setup ----

  LatLngBounds? _bounds() {
    final b = widget.data.trip.stats.bounds ??
        GeoBounds.of([for (final p in widget.data.points) (p.lat, p.lon)]);
    if (b == null) return null;
    // Pad a single-point trip so the camera has something to fit.
    const e = 0.002;
    return LatLngBounds(
      southwest: LatLng(b.minLat - (b.maxLat == b.minLat ? e : 0), b.minLon - (b.maxLon == b.minLon ? e : 0)),
      northeast: LatLng(b.maxLat + (b.maxLat == b.minLat ? e : 0), b.maxLon + (b.maxLon == b.minLon ? e : 0)),
    );
  }

  void fitRoute({bool animate = true}) {
    final m = _map, b = _bounds();
    if (m == null || b == null) return;
    final u = CameraUpdate.newLatLngBounds(b, left: 48, right: 48, top: 110, bottom: widget.bottomPadding + 32);
    animate ? m.animateCamera(u, duration: const Duration(milliseconds: 700)) : m.moveCamera(u);
  }

  Future<void> _onStyleLoaded() async {
    final m = _map;
    if (m == null) return;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final casing = dark ? '#0b0f14' : '#ffffff';

    await m.addGeoJsonSource('route', _routeGeoJson());
    await m.addGeoJsonSource('ends', _endsGeoJson());
    await m.addGeoJsonSource('catches', _catchesGeoJson());
    await m.addGeoJsonSource('boat', _empty);

    final speedColor = [
      'interpolate',
      ['linear'],
      ['get', 'speed'],
      for (final (kmh, c) in speedRamp) ...[kmh, colorHex(c)],
    ];

    // The whole route, faded, shown under the revealed part during a replay.
    await m.addLineLayer(
        'route',
        'route-ghost',
        LineLayerProperties(
          lineColor: dark ? '#9aa4b2' : '#64748b',
          lineWidth: 3.0,
          lineOpacity: 0.0,
          lineJoin: 'round',
          lineCap: 'round',
        ),
        enableInteraction: false);
    await m.addLineLayer(
        'route',
        'route-casing',
        LineLayerProperties(
            lineColor: casing, lineWidth: 8.0, lineOpacity: 0.9, lineJoin: 'round', lineCap: 'round'),
        filter: _always,
        enableInteraction: false);
    await m.addLineLayer(
        'route',
        'route-line',
        LineLayerProperties(lineColor: speedColor, lineWidth: 4.5, lineJoin: 'round', lineCap: 'round'),
        filter: _always,
        enableInteraction: false);
    await m.addCircleLayer(
        'ends',
        'ends',
        CircleLayerProperties(
          circleRadius: 6.0,
          circleColor: ['match', ['get', 'kind'], 'start', '#16a34a', '#dc2626'],
          circleStrokeColor: casing,
          circleStrokeWidth: 2.5,
        ),
        enableInteraction: false);
    await m.addCircleLayer(
        'catches',
        'catch-halo',
        CircleLayerProperties(circleRadius: 16.0, circleColor: ['get', 'color'], circleOpacity: 0.22),
        filter: _always,
        enableInteraction: false);
    await m.addCircleLayer(
        'catches',
        'catch-pin',
        CircleLayerProperties(
          circleRadius: 8.5,
          circleColor: ['get', 'color'],
          circleStrokeColor: '#ffffff',
          circleStrokeWidth: 2.5,
        ),
        filter: _always);
    await m.addCircleLayer(
        'boat',
        'boat-halo',
        CircleLayerProperties(circleRadius: 15.0, circleColor: colorHex(seedColor), circleOpacity: 0.25),
        enableInteraction: false);
    await m.addCircleLayer(
        'boat',
        'boat',
        const CircleLayerProperties(
          circleRadius: 7.0,
          circleColor: '#ffffff',
          circleStrokeColor: '#0e6e78',
          circleStrokeWidth: 3.5,
        ),
        enableInteraction: false);

    m.onFeatureTapped.add((_, _, id, layerId, _) {
      if (layerId != 'catch-pin') return;
      final cid = int.tryParse(id);
      for (final c in widget.data.catches) {
        if (c.id == cid) {
          widget.onCatchTap?.call(c);
          return;
        }
      }
    });

    _styleReady = true;
    fitRoute(animate: false);
    if (_want != _have) unawaited(_apply());
  }

  // ---- Replay ----

  /// Shows the trip up to [t] (ms), or the whole trip when null.
  void setReplayTime(int? t) {
    _want = t ?? _whole;
    if (_styleReady && !_updating) unawaited(_apply());
  }

  Future<void> _apply() async {
    final m = _map;
    if (m == null) return;
    _updating = true;
    try {
      // Platform calls are async; coalesce to the latest time while one runs.
      while (_have != _want) {
        final t = _want;
        final starting = _have == _whole;
        _have = t;
        if (t == _whole) {
          await m.setLayerFilter('route-line', _always);
          await m.setLayerFilter('route-casing', _always);
          await m.setLayerFilter('catch-pin', _always);
          await m.setLayerFilter('catch-halo', _always);
          await m.setLayerProperties('route-ghost', const LineLayerProperties(lineOpacity: 0.0));
          await m.setGeoJsonSource('boat', _empty);
        } else {
          final shown = ['<=', ['get', 't'], t];
          if (starting) {
            await m.setLayerProperties('route-ghost', const LineLayerProperties(lineOpacity: 0.45));
          }
          await m.setLayerFilter('route-line', shown);
          await m.setLayerFilter('route-casing', shown);
          await m.setLayerFilter('catch-pin', shown);
          await m.setLayerFilter('catch-halo', shown);
          final pos = positionAt(widget.data.points, t);
          if (pos != null) await m.setGeoJsonSource('boat', _point(pos.$1, pos.$2));
        }
      }
    } catch (_) {
      // The style can reload under us (theme change); it re-applies when ready.
    } finally {
      _updating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final b = widget.data.trip.stats.bounds;
    return MapLibreMap(
      key: ValueKey(dark),
      styleString: dark ? _darkStyle : _lightStyle,
      initialCameraPosition: CameraPosition(
        target: b == null ? const LatLng(-33.85, 151.25) : LatLng(b.centerLat, b.centerLon),
        zoom: 12,
      ),
      onMapCreated: (c) => _map = c,
      onStyleLoadedCallback: () {
        _styleReady = false;
        _have = _whole; // a fresh style shows the whole trip
        _onStyleLoaded();
      },
      compassEnabled: true,
      compassViewPosition: CompassViewPosition.topRight,
      compassViewMargins: const Point(16, 120),
      rotateGesturesEnabled: true,
      tiltGesturesEnabled: false,
      attributionButtonPosition: AttributionButtonPosition.bottomRight,
      attributionButtonMargins: Point(8, widget.bottomPadding + 8),
    );
  }
}
