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
/// water since the last reset.
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
    final since = this.since;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 20),
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
            Icon(Icons.speed_rounded, size: 18, color: on),
            const SizedBox(width: 8),
            Expanded(
              child: Text('TRIP METER',
                  style: t.labelLarge?.copyWith(color: on, letterSpacing: 1.2, fontWeight: FontWeight.w800)),
            ),
            TextButton.icon(
              onPressed: onReset,
              style: TextButton.styleFrom(foregroundColor: on),
              icon: const Icon(Icons.restart_alt_rounded, size: 20),
              label: const Text('Reset'),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              since == null ? 'Since your first trip' : 'Since ${Fmt.date(since)}, ${Fmt.time(since)}',
              style: t.bodyMedium?.copyWith(color: on.withValues(alpha: 0.8)),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(spacing: 32, runSpacing: 12, children: [
            for (final e in _withAnglers(reading.catchesByAngler).entries) _BigCount(angler: e.key, count: e.value),
          ]),
          const SizedBox(height: 18),
          Wrap(spacing: 28, runSpacing: 10, children: [
            _Metric(icon: Icons.route_rounded, value: Fmt.distance(reading.distanceM), label: 'distance'),
            _Metric(icon: Icons.schedule_rounded, value: Fmt.duration(reading.onWater), label: 'on the water'),
          ]),
          if (resetQueued) ...[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.sync_rounded, size: 16, color: on.withValues(alpha: 0.8)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('The logger\'s meter resets at the next sync',
                      style: t.bodySmall?.copyWith(color: on.withValues(alpha: 0.8))),
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
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: anglerColor(angler), shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(child: Text(angler, style: t.titleSmall?.copyWith(color: on, fontWeight: FontWeight.w700))),
      ]),
      Text('$count',
          style: t.displayMedium?.copyWith(
              color: on,
              fontWeight: FontWeight.w800,
              height: 1.05,
              fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.value, required this.label});
  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final on = Theme.of(context).colorScheme.onPrimaryContainer;
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
      Icon(icon, size: 20, color: on),
      const SizedBox(width: 8),
      Flexible(
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: value, style: t.titleLarge?.copyWith(color: on, fontWeight: FontWeight.w800)),
            TextSpan(text: '  $label', style: t.bodyMedium?.copyWith(color: on.withValues(alpha: 0.8))),
          ]),
        ),
      ),
    ]);
  }
}

/// Everything ever logged: catches per angler, distance, time and trips.
class TotalsCard extends StatelessWidget {
  const TotalsCard({super.key, required this.reading, this.firstTrip});
  final MeterReading reading;
  final DateTime? firstTrip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final first = firstTrip;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.emoji_events_rounded, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Text('ALL TIME',
                    style: t.labelLarge?.copyWith(color: cs.primary, letterSpacing: 1.2, fontWeight: FontWeight.w800)),
              ]),
              if (first != null)
                Text('since ${Fmt.date(first)}', style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
          StatGrid(children: [
            for (final e in _withAnglers(reading.catchesByAngler).entries)
              StatTile(
                label: e.key,
                value: '${e.value}',
                icon: Icons.phishing_rounded,
                iconColor: anglerColor(e.key),
              ),
            StatTile(label: 'Distance', value: Fmt.distance(reading.distanceM), icon: Icons.route_rounded),
            StatTile(label: 'On the water', value: Fmt.duration(reading.onWater), icon: Icons.schedule_rounded),
            StatTile(label: 'Trips', value: '${reading.trips}', icon: Icons.directions_boat_rounded),
            StatTile(label: 'Fish in all', value: '${reading.catches}', icon: Icons.set_meal_rounded),
          ]),
        ]),
      ),
    );
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
