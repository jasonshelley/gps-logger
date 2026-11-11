import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/astro.dart';
import '../core/gpx.dart';
import '../data/repository.dart';
import '../main.dart';
import 'catch_card.dart';
import 'format.dart';
import 'theme.dart';
import 'trip_extras.dart';
import 'trip_map.dart';
import 'widgets.dart';

class TripScreen extends StatefulWidget {
  const TripScreen({super.key, required this.tripId});
  final int tripId;

  static Route<void> route(int id) => MaterialPageRoute(builder: (_) => TripScreen(tripId: id));

  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> with SingleTickerProviderStateMixin {
  TripData? _data;
  Object? _loadError;
  bool _loaded = false;
  final _mapKey = GlobalKey<TripMapState>();
  final _sheet = DraggableScrollableController();
  final _catchKeys = <int, GlobalKey>{};

  // Extras, loaded after the trip itself.
  TripPhotos? _photos;
  TripConditions? _conditions;
  bool _conditionsLoading = false;

  // Replay.
  late final Ticker _ticker = createTicker(_tick);
  Duration? _lastTick;
  int? _replayT; // null = not replaying
  bool _playing = false;
  int _speedIndex = 2;
  static const _speeds = [30, 60, 120, 300, 600, 1200];
  int _nextCatch = 0;
  StoredCatch? _moment;
  Timer? _momentTimer;

  static const _sheetInitial = 0.42;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _momentTimer?.cancel();
    _sheet.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final services = AppScope.of(context);
      final d = await services.repo.tripData(widget.tripId);
      if (!mounted) return;
      setState(() {
        _data = d;
        _loaded = true;
        if (d != null) _speedIndex = _defaultSpeed(d);
      });
      if (d != null) {
        unawaited(_loadPhotos());
        unawaited(_loadConditions());
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = e;
          _loaded = true;
        });
      }
    }
  }

  Future<void> _loadPhotos() async {
    final d = _data;
    if (d == null) return;
    try {
      final ph = await PhotoService.forTrip(d);
      if (mounted) setState(() => _photos = ph);
    } catch (_) {
      if (mounted) setState(() => _photos = const TripPhotos(PhotoAccess.denied, {}, []));
    }
  }

  Future<void> _loadConditions({bool refresh = false}) async {
    final d = _data;
    if (d == null || d.catches.every((c) => c.time == null)) return;
    setState(() => _conditionsLoading = true);
    try {
      final c = await loadConditions(AppScope.of(context), d, refresh: refresh);
      if (mounted) setState(() => _conditions = c);
    } catch (e) {
      if (mounted) setState(() => _conditions = null);
    } finally {
      if (mounted) setState(() => _conditionsLoading = false);
    }
  }

  /// Replays the trip in about 40 seconds.
  int _defaultSpeed(TripData d) {
    final secs = d.trip.stats.duration.inSeconds;
    var best = 0;
    for (var i = 0; i < _speeds.length; i++) {
      if ((secs / _speeds[i] - 40).abs() < (secs / _speeds[best] - 40).abs()) best = i;
    }
    return best;
  }

  // ---- Replay ----

  void _togglePlay() {
    final d = _data!;
    final s = d.trip.stats;
    HapticFeedback.selectionClick();
    if (_playing) {
      _ticker.stop();
      setState(() => _playing = false);
      return;
    }
    var t = _replayT ?? s.startMs;
    if (t >= s.endMs) t = s.startMs;
    _seek(t);
    _lastTick = null;
    _ticker.start();
    setState(() => _playing = true);
    if (_sheet.isAttached && _sheet.size > 0.36) {
      _sheet.animateTo(0.3, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic);
    }
  }

  void _stopReplay() {
    _ticker.stop();
    _momentTimer?.cancel();
    setState(() {
      _playing = false;
      _replayT = null;
      _moment = null;
    });
    _mapKey.currentState?.setReplayTime(null);
  }

  void _seek(int t) {
    final d = _data!;
    _replayT = t;
    _nextCatch = d.catches.indexWhere((c) => (c.event.t ?? 0) > t);
    if (_nextCatch < 0) _nextCatch = d.catches.length;
    _mapKey.currentState?.setReplayTime(t);
  }

  void _tick(Duration elapsed) {
    final d = _data!;
    final s = d.trip.stats;
    final dt = _lastTick == null ? Duration.zero : elapsed - _lastTick!;
    _lastTick = elapsed;
    var t = (_replayT ?? s.startMs) + dt.inMicroseconds * _speeds[_speedIndex] ~/ 1000;
    if (t >= s.endMs) {
      t = s.endMs;
      _ticker.stop();
      _playing = false;
    }
    // Catch moments.
    while (_nextCatch < d.catches.length && (d.catches[_nextCatch].event.t ?? 0) <= t) {
      final c = d.catches[_nextCatch++];
      if (c.event.t != null) _showMoment(c);
    }
    _replayT = t;
    _mapKey.currentState?.setReplayTime(t);
    setState(() {});
  }

  void _showMoment(StoredCatch c) {
    HapticFeedback.mediumImpact();
    _momentTimer?.cancel();
    setState(() => _moment = c);
    _momentTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _moment = null);
    });
  }

  // ---- Actions ----

  Future<void> _shareGpx() async {
    final d = _data!;
    final local = Fmt.local(d.trip.stats.startMs);
    String two(int n) => n.toString().padLeft(2, '0');
    final name = 'trip-${local.year}${two(local.month)}${two(local.day)}-${two(local.hour)}${two(local.minute)}';
    final gpx = buildGpx(
      name: '${Fmt.tripName(d.trip.stats.startMs)}, ${Fmt.dayShort(local)}',
      points: d.points,
      catches: [for (final c in d.catches) c.event],
    );
    final dir = await getTemporaryDirectory();
    final f = File(p.join(dir.path, '$name.gpx'));
    await f.writeAsString(gpx, flush: true);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(f.path, mimeType: 'application/gpx+xml')],
      subject: '${Fmt.tripName(d.trip.stats.startMs)}, ${Fmt.dayLong(local)}',
    ));
  }

  void _focusCatch(StoredCatch c) {
    HapticFeedback.selectionClick();
    if (_sheet.isAttached) {
      _sheet.animateTo(0.7, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
    }
    Future<void>.delayed(const Duration(milliseconds: 380), () {
      final ctx = _catchKeys[c.id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 400), alignment: 0.1);
      }
    });
  }

  Future<void> _askPhotos() async {
    final access = _photos?.access;
    if (access == PhotoAccess.denied) {
      await PhotoService.openSettings();
    } else if (access == PhotoAccess.limited) {
      await PhotoService.pickMore();
    } else {
      await PhotoService.request();
    }
    await _loadPhotos();
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: _loaded
              ? MessageView(
                  icon: Icons.error_outline_rounded,
                  title: 'Couldn\'t open this trip',
                  body: _loadError?.toString() ?? 'It may have been merged into another trip by a later sync.',
                )
              : const CircularProgressIndicator(),
        ),
      );
    }
    final h = MediaQuery.sizeOf(context).height;
    final cs = Theme.of(context).colorScheme;
    final top = MediaQuery.paddingOf(context).top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: Stack(children: [
          Positioned.fill(
            child: TripMap(
              key: _mapKey,
              data: d,
              bottomPadding: h * _sheetInitial,
              onCatchTap: _focusCatch,
            ),
          ),
          // Floating top bar.
          Positioned(
            top: top + 8,
            left: 12,
            right: 12,
            child: Row(children: [
              _RoundButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onTap: () => Navigator.of(context).pop()),
              const Spacer(),
              _RoundButton(
                  icon: Icons.center_focus_strong_rounded,
                  tooltip: 'Fit route',
                  onTap: () => _mapKey.currentState?.fitRoute()),
              const SizedBox(width: 8),
              _RoundButton(icon: Icons.ios_share_rounded, tooltip: 'Share GPX', onTap: _shareGpx),
            ]),
          ),
          // Catch moment banner during the replay.
          Positioned(
            top: top + 68,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0, -0.4), end: Offset.zero).animate(a),
                    child: child,
                  ),
                ),
                child: _moment == null ? const SizedBox.shrink() : _MomentBanner(key: ValueKey(_moment!.id), data: d, c: _moment!),
              ),
            ),
          ),
          DraggableScrollableSheet(
            controller: _sheet,
            initialChildSize: _sheetInitial,
            minChildSize: 0.2,
            maxChildSize: 0.94,
            snap: true,
            snapSizes: const [0.3, _sheetInitial, 0.94],
            builder: (context, scroll) => Material(
              color: cs.surface,
              elevation: 8,
              shadowColor: Colors.black54,
              surfaceTintColor: cs.surfaceTint,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              clipBehavior: Clip.antiAlias,
              child: CustomScrollView(controller: scroll, slivers: [
                SliverToBoxAdapter(child: _sheetHeader(d)),
                SliverToBoxAdapter(child: _replayBar(d)),
                SliverToBoxAdapter(child: _stats(d)),
                SliverToBoxAdapter(child: _catchesHeader(d)),
                if (_photos != null && _photos!.access != PhotoAccess.granted && d.catches.isNotEmpty)
                  SliverToBoxAdapter(child: _photoPrompt()),
                if (d.catches.isEmpty)
                  SliverToBoxAdapter(child: _noCatches())
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverList.separated(
                      itemCount: d.catches.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (_, i) {
                        final c = d.catches[i];
                        return CatchCard(
                          key: _catchKeys.putIfAbsent(c.id, GlobalKey.new),
                          catchItem: c,
                          number: d.catches.take(i + 1).where((x) => x.angler == c.angler).length,
                          tripStartMs: d.trip.stats.startMs,
                          photos: _photos?.byCatch[c.id] ?? const [],
                          conditions: c.time == null ? null : _conditions?.forCatch(c),
                          conditionsLoading: _conditionsLoading,
                          conditionsError: _conditions?.error,
                          onRetryConditions: () => _loadConditions(refresh: true),
                        );
                      },
                    ),
                  ),
                if ((_photos?.unmatched.length ?? 0) > 0)
                  SliverToBoxAdapter(child: _otherPhotos(_photos!.unmatched.length)),
                SliverToBoxAdapter(child: _footer(d)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _sheetHeader(TripData d) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final s = d.trip.stats;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(2)),
          ),
        ),
        const SizedBox(height: 14),
        Text(Fmt.dayLong(s.start).toUpperCase(),
            style: t.labelMedium?.copyWith(color: cs.primary, letterSpacing: 0.8, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Row(children: [
          Expanded(
            child: Text(Fmt.tripName(s.startMs), style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          ),
          Wrap(spacing: 6, children: [
            for (final e in {'Jase': 0, 'Matt': 0, ...s.catchesByAngler}.entries) AnglerCount(e.key, e.value),
          ]),
        ]),
        const SizedBox(height: 4),
        Text('${Fmt.timeMs(s.startMs)} – ${Fmt.timeMs(s.endMs)}',
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
      ]),
    );
  }

  Widget _replayBar(TripData d) {
    final s = d.trip.stats;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final now = _replayT ?? s.startMs;
    final canReplay = d.points.length > 1 && s.endMs > s.startMs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
        decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(22)),
        child: Row(children: [
          IconButton.filled(
            onPressed: canReplay ? _togglePlay : null,
            iconSize: 28,
            tooltip: _playing ? 'Pause' : 'Replay trip',
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(_playing)),
            ),
          ),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(overlayShape: SliderComponentShape.noOverlay),
                child: Slider(
                  value: now.clamp(s.startMs, s.endMs).toDouble(),
                  min: s.startMs.toDouble(),
                  max: (s.endMs > s.startMs ? s.endMs : s.startMs + 1).toDouble(),
                  onChanged: canReplay
                      ? (v) {
                          if (_playing) {
                            _ticker.stop();
                            _playing = false;
                          }
                          setState(() => _seek(v.round()));
                        }
                      : null,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  Text(
                    _replayT == null ? 'Replay' : Fmt.timeMs(now),
                    style: t.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                  const Spacer(),
                  if (_replayT != null)
                    GestureDetector(
                      onTap: _stopReplay,
                      child: Text('Show all', style: t.labelMedium?.copyWith(color: cs.primary)),
                    )
                  else
                    Text(Fmt.duration(s.duration), style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                ]),
              ),
            ]),
          ),
          TextButton(
            onPressed: () => setState(() => _speedIndex = (_speedIndex + 1) % _speeds.length),
            style: TextButton.styleFrom(minimumSize: const Size(56, 40)),
            child: Text('${_speeds[_speedIndex]}×',
                style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
          ),
        ]),
      ),
    );
  }

  Widget _stats(TripData d) {
    final s = d.trip.stats;
    final b = s.bounds;
    final sun = b == null ? null : sunTimes(s.start, b.centerLat, b.centerLon);
    final moon = moonIllumination(s.start);
    final tiles = [
      StatTile(label: 'Duration', value: Fmt.duration(s.duration), icon: Icons.schedule_rounded),
      StatTile(label: 'Distance', value: Fmt.distance(s.distanceM), icon: Icons.route_rounded),
      StatTile(label: 'Moving', value: Fmt.duration(Duration(seconds: s.movingS)), icon: Icons.directions_boat_rounded),
      StatTile(label: 'Max speed', value: Fmt.speed(s.maxSpeedKmh), icon: Icons.speed_rounded),
      if (sun?.sunrise != null && sun?.sunset != null)
        StatTile(
            label: 'Sunrise · sunset',
            value: '${Fmt.time(sun!.sunrise!)} · ${Fmt.time(sun.sunset!)}'.replaceAll(' am', 'a').replaceAll(' pm', 'p'),
            icon: Icons.wb_twilight_rounded),
      StatTile(label: 'Moon', value: '${moon.emoji} ${(moon.fraction * 100).round()}%', icon: Icons.dark_mode_rounded),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.3,
          children: tiles,
        ),
        const SizedBox(height: 12),
        const _SpeedLegend(),
      ]),
    );
  }

  Widget _catchesHeader(TripData d) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Row(children: [
        Text('Catches', style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Text('${d.catches.length}', style: t.titleLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const Spacer(),
        if (_conditionsLoading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      ]),
    );
  }

  Widget _photoPrompt() {
    final cs = Theme.of(context).colorScheme;
    final access = _photos!.access;
    final (title, body, button) = switch (access) {
      PhotoAccess.limited => (
          'Only some photos are shared',
          'Catch Log can only see the photos you picked. Pick more to match them to catches.',
          'Pick photos'
        ),
      PhotoAccess.denied => (
          'Photo access is off',
          'To put your photos on the right catch, allow Photos for Catch Log in Settings.',
          'Open Settings'
        ),
      _ => (
          'Add your photos',
          'Catch Log can find the photos you took on this trip and put each on the right catch, by time. '
              'Photos stay on your phone.',
          'Allow photo access'
        ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Card(
        color: cs.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.photo_library_rounded, color: cs.onSecondaryContainer),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700, color: cs.onSecondaryContainer)),
                const SizedBox(height: 4),
                Text(body, style: TextStyle(color: cs.onSecondaryContainer)),
                const SizedBox(height: 10),
                FilledButton.tonal(
                  onPressed: _askPhotos,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                  child: Text(button),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _noCatches() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text('No catches on this trip. Some days are like that.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  Widget _otherPhotos(int n) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Text('$n other ${n == 1 ? 'photo' : 'photos'} from this trip, not near a catch',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  Widget _footer(TripData d) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 24, 16, 24 + MediaQuery.paddingOf(context).bottom),
      child: Column(children: [
        OutlinedButton.icon(
          onPressed: _shareGpx,
          icon: const Icon(Icons.ios_share_rounded),
          label: const Text('Share as GPX'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: 12),
        Text('${d.points.length} track points · weather and marine data from Open-Meteo.com',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      elevation: 3,
      shadowColor: Colors.black38,
      child: IconButton(icon: Icon(icon), tooltip: tooltip, onPressed: onTap),
    );
  }
}

class _MomentBanner extends StatelessWidget {
  const _MomentBanner({super.key, required this.data, required this.c});
  final TripData data;
  final StoredCatch c;
  @override
  Widget build(BuildContext context) {
    final color = anglerColor(c.angler);
    final n = data.catches.takeWhile((x) => x.id != c.id).where((x) => x.angler == c.angler).length + 1;
    final t = Theme.of(context).textTheme;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(99),
      elevation: 6,
      shadowColor: color.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.phishing_rounded, color: Colors.white, size: 22),
          const SizedBox(width: 8),
          Text('${c.angler} catch #$n',
              style: t.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          Text(Fmt.time(c.time!), style: t.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.9))),
        ]),
      ),
    );
  }
}

class _SpeedLegend extends StatelessWidget {
  const _SpeedLegend();
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      Text('Slow', style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
      const SizedBox(width: 8),
      Expanded(
        child: Container(
          height: 6,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            gradient: LinearGradient(colors: [for (final (_, c) in speedRamp) c]),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Text('${speedRamp.last.$1.round()}+ km/h', style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
    ]);
  }
}
