import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/conditions.dart';
import '../data/repository.dart';
import 'format.dart';
import 'theme.dart';

/// One catch: who, when, where in the trip, its photos and its conditions.
class CatchCard extends StatelessWidget {
  const CatchCard({
    super.key,
    required this.catchItem,
    required this.number,
    required this.tripStartMs,
    required this.photos,
    required this.conditions,
    required this.conditionsLoading,
    required this.conditionsError,
    required this.onRetryConditions,
  });

  final StoredCatch catchItem;
  final int number; // this angler's nth catch of the trip
  final int tripStartMs;
  final List<AssetEntity> photos;
  final CatchConditions? conditions;
  final bool conditionsLoading;
  final String? conditionsError;
  final VoidCallback onRetryConditions;

  @override
  Widget build(BuildContext context) {
    final c = catchItem;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final color = anglerColor(c.angler);
    final time = c.time;
    final age = c.event.fixAgeS ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text('$number',
                  style: t.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${c.angler}\'s ${_ordinal(number)} catch',
                    style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text(
                  time == null
                      ? 'Time unknown'
                      : '${Fmt.time(time)} · ${Fmt.duration(Duration(milliseconds: time.millisecondsSinceEpoch - tripStartMs))} in',
                  style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ]),
            ),
          ]),
          if (!c.event.hasPosition)
            _note(context, Icons.location_off_rounded, 'No position: the GPS had no fix yet')
          else if (age > 60)
            _note(context, Icons.history_rounded, 'Position from a fix ${Fmt.duration(Duration(seconds: age))} old'),
          if (photos.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: photos.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => _PhotoThumb(asset: photos[i], all: photos, index: i),
              ),
            ),
          ],
          if (time != null) ...[
            const SizedBox(height: 12),
            _ConditionsRow(
              c: conditions,
              loading: conditionsLoading,
              error: conditionsError,
              onRetry: onRetryConditions,
            ),
          ],
        ]),
      ),
    );
  }

  static String _ordinal(int n) {
    if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
    return switch (n % 10) { 1 => '${n}st', 2 => '${n}nd', 3 => '${n}rd', _ => '${n}th' };
  }

  Widget _note(BuildContext context, IconData icon, String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(children: [
        Icon(icon, size: 16, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13))),
      ]),
    );
  }
}

class _ConditionsRow extends StatelessWidget {
  const _ConditionsRow({required this.c, required this.loading, required this.error, required this.onRetry});
  final CatchConditions? c;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = this.c;
    final chips = <Widget>[];
    if (c != null) {
      chips.add(_Chip(Icons.wb_sunny_rounded, _sunPhrase(c)));
      chips.add(_Chip(null, '${c.moon.emoji} ${c.moon.name} · ${(c.moon.fraction * 100).round()}%'));
      if (c.windKn != null) {
        final dir = c.windDirDeg == null ? '' : ' ${compassPoint(c.windDirDeg!)}';
        final gust = c.gustKn == null ? '' : ', gusts ${c.gustKn!.round()}';
        chips.add(_Chip(Icons.air_rounded, '${c.windKn!.round()} kn$dir$gust'));
      }
      if (c.waveM != null) {
        final per = c.wavePeriodS == null ? '' : ' · ${c.wavePeriodS!.round()} s';
        chips.add(_Chip(Icons.waves_rounded, '${c.waveM!.toStringAsFixed(1)} m$per'));
      }
      if (c.seaTempC != null) chips.add(_Chip(Icons.thermostat_rounded, '${c.seaTempC!.toStringAsFixed(1)} °C water'));
      if (c.pressureHpa != null) {
        final arrow = switch (c.pressureTrend) {
          PressureTrend.rising => ' ↑ rising',
          PressureTrend.falling => ' ↓ falling',
          PressureTrend.steady => ' → steady',
          null => '',
        };
        chips.add(_Chip(Icons.compress_rounded, '${c.pressureHpa!.round()} hPa$arrow'));
      }
      if (c.airTempC != null) chips.add(_Chip(Icons.device_thermostat_rounded, '${c.airTempC!.round()} °C air'));
    }
    final missingWeather = c != null && !c.hasWeather;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 6, runSpacing: 6, children: chips),
      if (c == null && loading)
        const Padding(padding: EdgeInsets.only(top: 2), child: Text('Loading conditions…'))
      else if (missingWeather || c == null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            Expanded(
              child: Text(
                error != null && error!.contains('Socket')
                    ? 'Weather needs an internet connection the first time.'
                    : 'No weather data for this time yet.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
              ),
            ),
            if (!loading) TextButton(onPressed: onRetry, child: const Text('Retry')),
          ]),
        ),
    ]);
  }

  /// "40 min after sunrise", "1 h 10 m before sunset", or Daylight / Night.
  static String _sunPhrase(CatchConditions c) {
    final rise = c.sun.sunrise, set = c.sun.sunset;
    if (rise == null || set == null) return 'Sun ${c.sunAltitudeDeg.round()}°';
    final toRise = c.at.difference(rise), toSet = c.at.difference(set);
    final nearRise = toRise.abs() <= toSet.abs();
    final d = nearRise ? toRise : toSet;
    if (d.abs() > const Duration(hours: 3)) return c.sunAltitudeDeg > 0 ? 'Daylight' : 'Night';
    return '${Fmt.offset(d)} ${d.isNegative ? 'before' : 'after'} ${nearRise ? 'sunrise' : 'sunset'}';
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.icon, this.label);
  final IconData? icon;
  final String label;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 15, color: cs.primary), const SizedBox(width: 5)],
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ]),
    );
  }
}

class _PhotoThumb extends StatefulWidget {
  const _PhotoThumb({required this.asset, required this.all, required this.index});
  final AssetEntity asset;
  final List<AssetEntity> all;
  final int index;
  @override
  State<_PhotoThumb> createState() => _PhotoThumbState();
}

class _PhotoThumbState extends State<_PhotoThumb> {
  late final Future<Uint8List?> _thumb = widget.asset.thumbnailDataWithSize(const ThumbnailSize.square(240));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(PhotoViewer.route(widget.all, widget.index)),
      child: Hero(
        tag: 'photo-${widget.asset.id}',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 96,
            height: 96,
            color: cs.surfaceContainerHighest,
            child: FutureBuilder(
              future: _thumb,
              builder: (_, s) => s.data == null
                  ? const SizedBox.shrink()
                  : Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen photo viewer with swipe between a catch's photos.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.assets, required this.initial});
  final List<AssetEntity> assets;
  final int initial;

  static Route<void> route(List<AssetEntity> a, int i) => PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, _, _) => PhotoViewer(assets: a, initial: i),
        transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: anim, child: child),
      );

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late final _page = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.assets[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(Fmt.time(a.createDateTime), style: const TextStyle(color: Colors.white)),
      ),
      extendBodyBehindAppBar: true,
      body: PageView.builder(
        controller: _page,
        itemCount: widget.assets.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => _FullPhoto(asset: widget.assets[i]),
      ),
    );
  }
}

class _FullPhoto extends StatefulWidget {
  const _FullPhoto({required this.asset});
  final AssetEntity asset;
  @override
  State<_FullPhoto> createState() => _FullPhotoState();
}

class _FullPhotoState extends State<_FullPhoto> {
  late final Future<Uint8List?> _bytes =
      widget.asset.thumbnailDataWithSize(const ThumbnailSize(1600, 1600), quality: 90);

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: 'photo-${widget.asset.id}',
      child: InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: FutureBuilder(
            future: _bytes,
            builder: (_, s) => s.data == null
                ? const CircularProgressIndicator(color: Colors.white)
                : Image.memory(s.data!, fit: BoxFit.contain, gaplessPlayback: true),
          ),
        ),
      ),
    );
  }
}
