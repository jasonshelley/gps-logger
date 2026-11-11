import 'package:flutter/material.dart';

import '../core/meter.dart';
import '../sync/logger_meter.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets.dart';

/// The anglers always shown, in this order, even before their first catch.
const _anglers = ['Jase', 'Matt'];

Map<String, int> _withAnglers(Map<String, int> m) => {for (final a in _anglers) a: 0, ...m};

/// Like a car's trip meter: catches per angler, distance and time on the
/// water since the last reset. The hero of the home screen, kept compact:
/// a header line, then the two catch counts with distance and time beside them.
class TripMeterCard extends StatelessWidget {
  const TripMeterCard({
    super.key,
    required this.reading,
    required this.since,
    required this.resetQueued,
    required this.onReset,
  });

  final MeterReading reading;

  /// The last reset, or null if the meter has never been reset.
  final DateTime? since;

  /// The reset hasn't reached the logger yet.
  final bool resetQueued;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final on = cs.onPrimaryContainer;
    final soft = on.withValues(alpha: 0.75);
    final since = this.since;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 8, 6, 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs.primaryContainer, cs.tertiaryContainer],
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('TRIP METER',
                      style: t.labelLarge?.copyWith(color: on, letterSpacing: 1.1, fontWeight: FontWeight.w800)),
                  Text(
                    since == null ? 'Since the first trip' : 'Since ${Fmt.date(since)}, ${Fmt.time(since)}',
                    style: t.labelMedium?.copyWith(color: soft),
                  ),
                ]),
              ),
            ),
            TextButton.icon(
              onPressed: onReset,
              style: TextButton.styleFrom(foregroundColor: on, visualDensity: VisualDensity.compact),
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Reset'),
            ),
          ]),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            // One row when it fits, metrics at the right; with large text the
            // metrics drop below.
            child: _SpreadRow(
              children: [
                Wrap(spacing: 28, runSpacing: 8, children: [
                  for (final e in _withAnglers(reading.catchesByAngler).entries)
                    _BigCount(angler: e.key, count: e.value),
                ]),
                Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  _Metric(icon: Icons.route_rounded, value: Fmt.distance(reading.distanceM), color: on),
                  const SizedBox(height: 4),
                  _Metric(icon: Icons.schedule_rounded, value: Fmt.duration(reading.onWater), color: on),
                ]),
              ],
            ),
          ),
          if (resetQueued) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.sync_rounded, size: 14, color: soft),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('The logger\'s meter resets at the next sync',
                      style: t.labelMedium?.copyWith(color: soft)),
                ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

class _BigCount extends StatelessWidget {
  const _BigCount({required this.angler, required this.count});
  final String angler;
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final on = Theme.of(context).colorScheme.onPrimaryContainer;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: anglerColor(angler), shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Flexible(child: Text(angler, style: t.labelLarge?.copyWith(color: on, fontWeight: FontWeight.w700))),
      ]),
      Text('$count',
          style: t.displaySmall?.copyWith(
              color: on, fontWeight: FontWeight.w800, height: 1.1, fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.value, required this.color});
  final IconData icon;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: color.withValues(alpha: 0.8)),
      const SizedBox(width: 6),
      Flexible(child: Text(value, style: t.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w800))),
    ]);
  }
}

/// Two groups on one line, pushed to the left and right edges; the second
/// wraps below the first when they don't fit side by side.
class _SpreadRow extends StatelessWidget {
  const _SpreadRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 16,
          runSpacing: 12,
          children: children,
        ),
      );
}

/// Everything ever logged: catches per angler, trips, distance and time on
/// the water. A tonal card that pairs with the trip meter above it.
class TotalsCard extends StatelessWidget {
  const TotalsCard({super.key, required this.reading, this.firstTrip});
  final MeterReading reading;
  final DateTime? firstTrip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final on = cs.onSecondaryContainer;
    final first = firstTrip;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(24)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: 'ALL TIME',
                  style: t.labelLarge?.copyWith(color: on, letterSpacing: 1.1, fontWeight: FontWeight.w800)),
              if (first != null)
                TextSpan(
                    text: '  ·  since ${Fmt.date(first)}',
                    style: t.labelMedium?.copyWith(color: on.withValues(alpha: 0.75))),
            ]),
          ),
          const SizedBox(height: 10),
          _SpreadRow(children: [
            Wrap(spacing: 22, runSpacing: 8, children: [
              for (final e in _withAnglers(reading.catchesByAngler).entries)
                _MiniStat(value: '${e.value}', label: e.key, dot: anglerColor(e.key), color: on),
              _MiniStat(value: '${reading.trips}', label: reading.trips == 1 ? 'trip' : 'trips', color: on),
            ]),
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              _Metric(icon: Icons.route_rounded, value: Fmt.distance(reading.distanceM), color: on),
              const SizedBox(height: 4),
              _Metric(icon: Icons.schedule_rounded, value: Fmt.duration(reading.onWater), color: on),
            ]),
          ]),
        ]),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.value, required this.label, required this.color, this.dot});
  final String value;
  final String label;
  final Color color;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(value,
          style: t.titleMedium?.copyWith(
              color: color, fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()])),
      Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot != null) ...[
          Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 4),
        ],
        Flexible(child: Text(label, style: t.labelMedium?.copyWith(color: color.withValues(alpha: 0.75)))),
      ]),
    ]);
  }
}

/// After a sync: the logger's own trip meter, and whether it matches the phone's.
class LoggerMeterPanel extends StatelessWidget {
  const LoggerMeterPanel({super.key, required this.result, this.comparison});
  final MeterSyncResult result;
  final MeterComparison? comparison;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final r = result;
    final c = comparison;
    final logger = r.logger;
    // An older logger with nothing queued: nothing worth saying.
    if (r.outcome == MeterSyncOutcome.unsupported && !r.queued) return const SizedBox.shrink();

    final notes = <String>[
      if (r.outcome == MeterSyncOutcome.sent) 'Your trip meter reset reached the logger.',
      if (r.outcome == MeterSyncOutcome.realigned)
        'The logger was counting from a different time, so it now counts from the phone\'s last reset.',
      if (r.outcome == MeterSyncOutcome.adopted && logger?.resetAt != null)
        'The phone now counts from the logger\'s last reset, ${Fmt.date(logger!.resetAt!)}, ${Fmt.time(logger.resetAt!)}.',
      if (r.outcome == MeterSyncOutcome.unsupported)
        'The logger\'s firmware has no trip meter yet. Your reset is kept and sent once it does.',
      if (r.outcome == MeterSyncOutcome.failed)
        'Couldn\'t reach the logger\'s trip meter (${r.error}).${r.queued ? ' Your reset is kept for the next sync.' : ''}',
      if (logger != null && logger.incomplete) 'The logger couldn\'t read its whole card, so its numbers may be low.',
      if (logger != null && logger.clockNotSet)
        'The logger hasn\'t had GPS time since it started, so new catches may not count yet.',
      if (c != null && !c.agrees)
        'A difference is expected if a file is still on the logger, or if catches were logged before the GPS had the time.',
    ];

    final (IconData icon, Color color, String headline) = switch ((logger, c?.agrees)) {
      (_, true) => (Icons.check_circle_rounded, cs.primary, 'Logger\'s trip meter matches'),
      (_, false) => (Icons.error_outline_rounded, cs.tertiary, 'Logger\'s trip meter differs'),
      _ => (Icons.speed_rounded, cs.onSurfaceVariant, 'Logger\'s trip meter'),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(headline, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
        ]),
        if (logger != null) ...[
          const SizedBox(height: 10),
          _MeterLine(
            label: c != null && !c.agrees ? 'Logger' : null,
            jase: logger.jase,
            matt: logger.matt,
            distanceM: logger.distanceM.toDouble(),
            water: Duration(seconds: logger.waterS),
          ),
          if (c != null && !c.agrees) ...[
            const SizedBox(height: 6),
            _MeterLine(
              label: 'Phone',
              jase: c.phoneJase,
              matt: c.phoneMatt,
              distanceM: c.phone.distanceM,
              water: c.phone.onWater,
            ),
          ],
        ],
        for (final n in notes)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(n, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ),
      ]),
    );
  }
}

class _MeterLine extends StatelessWidget {
  const _MeterLine({this.label, required this.jase, required this.matt, required this.distanceM, required this.water});
  final String? label;
  final int jase, matt;
  final double distanceM;
  final Duration water;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (label != null)
        SizedBox(width: 56, child: Text(label!, style: t.labelLarge?.copyWith(color: cs.onSurfaceVariant))),
      AnglerCount('Jase', jase, dense: true),
      AnglerCount('Matt', matt, dense: true),
      Text(Fmt.distance(distanceM), style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      Text(Fmt.duration(water), style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
    ]);
  }
}
