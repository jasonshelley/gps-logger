import 'package:flutter/material.dart';

import '../core/meter.dart';
import '../data/repository.dart';
import '../main.dart';
import 'format.dart';
import 'meter_cards.dart';
import 'route_thumbnail.dart';
import 'samples.dart';
import 'sync_screen.dart';
import 'trip_screen.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeData {
  const _HomeData({
    required this.trips,
    required this.undated,
    required this.lastSync,
    required this.hasSamples,
    required this.meter,
    required this.meterSince,
    required this.meterResetQueued,
    required this.totals,
  });
  final List<Trip> trips;
  final List<StoredCatch> undated;
  final DateTime? lastSync;
  final bool hasSamples;
  final MeterReading meter;
  final DateTime? meterSince;
  final bool meterResetQueued;
  final MeterReading totals;
}

class _HomeScreenState extends State<HomeScreen> {
  late Repository _repo;
  Future<_HomeData>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _repo = AppScope.of(context).repo;
    _repo.removeListener(_reload);
    _repo.addListener(_reload);
    _data ??= _load();
  }

  @override
  void dispose() {
    _repo.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    // A block body: an arrow would hand setState the Future, which it rejects.
    if (mounted) {
      setState(() {
        _data = _load();
      });
    }
  }

  Future<_HomeData> _load() async => _HomeData(
        trips: await _repo.trips(),
        undated: await _repo.undatedCatches(),
        lastSync: await _repo.lastSync(),
        hasSamples: await _repo.hasSamples(),
        meter: await _repo.meter(),
        meterSince: await _repo.meterResetAt(),
        meterResetQueued: await _repo.pendingMeterReset() != null,
        totals: await _repo.totals(),
      );

  Future<void> _resetMeter() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.restart_alt_rounded),
        title: const Text('Reset the trip meter?'),
        content: const Text('Catches, distance and time on the water start again from zero. '
            'Your trips and all-time totals are kept.\n\n'
            "The logger's meter resets too, the next time you sync."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok == true) await _repo.resetMeter();
  }

  Future<void> _openSync() async {
    final tripId = await Navigator.of(context).push<int>(SyncScreen.route());
    if (tripId != null && mounted) _openTrip(tripId);
  }

  void _openTrip(int id) => Navigator.of(context).push(TripScreen.route(id));

  Future<void> _loadSamples() async {
    final messenger = ScaffoldMessenger.of(context);
    final n = await loadSampleTrips(_repo);
    messenger.showSnackBar(SnackBar(content: Text(n > 0 ? 'Added $n sample trips' : 'Sample trips are already here')));
  }

  Future<void> _removeSamples() async {
    await _repo.removeSamples();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sample trips removed')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HomeData>(
      future: _data,
      builder: (context, snap) {
        final data = snap.data;
        final empty = data != null && data.trips.isEmpty;
        return Scaffold(
          floatingActionButton: data == null || empty
              ? null
              : FloatingActionButton.extended(
                  onPressed: _openSync,
                  icon: const Icon(Icons.bluetooth_searching_rounded),
                  label: const Text('Sync'),
                ),
          body: CustomScrollView(slivers: [
            SliverAppBar.large(
              title: const Text('Catch Log'),
              actions: [
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'samples') _loadSamples();
                    if (v == 'remove') _removeSamples();
                    if (v == 'about') _showAbout();
                  },
                  itemBuilder: (_) => [
                    if (data?.hasSamples != true)
                      const PopupMenuItem(value: 'samples', child: Text('Add sample trips')),
                    if (data?.hasSamples == true)
                      const PopupMenuItem(value: 'remove', child: Text('Remove sample trips')),
                    const PopupMenuItem(value: 'about', child: Text('About')),
                  ],
                ),
              ],
            ),
            if (data == null)
              const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
            else if (empty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: MessageView(
                    icon: Icons.phishing_rounded,
                    title: 'No trips yet',
                    body: 'Put the logger\'s switch on Transfer, then sync. '
                        'Each trip shows up here, mapped, with every catch.',
                    actions: [
                      FilledButton.icon(
                        onPressed: _openSync,
                        icon: const Icon(Icons.bluetooth_searching_rounded),
                        label: const Text('Sync logger'),
                      ),
                      TextButton(onPressed: _loadSamples, child: const Text('Try it with sample trips')),
                    ],
                  ),
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: TripMeterCard(
                  reading: data.meter,
                  since: data.meterSince,
                  resetQueued: data.meterResetQueued,
                  onReset: _resetMeter,
                ),
              ),
              SliverToBoxAdapter(
                child: TotalsCard(reading: data.totals, firstTrip: data.trips.lastOrNull?.stats.start),
              ),
              if (data.undated.isNotEmpty) SliverToBoxAdapter(child: _UndatedCard(data.undated)),
              ..._tripSlivers(data.trips),
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          ]),
        );
      },
    );
  }

  List<Widget> _tripSlivers(List<Trip> trips) {
    final out = <Widget>[];
    String? month;
    final group = <Trip>[];
    void flush() {
      if (group.isEmpty) return;
      final items = List.of(group);
      out.add(SliverToBoxAdapter(child: _MonthHeader(month!)));
      out.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList.separated(
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, i) => TripCard(trip: items[i], onTap: () => _openTrip(items[i].id)),
        ),
      ));
      group.clear();
    }

    for (final t in trips) {
      final m = Fmt.month(t.stats.start);
      if (m != month) {
        flush();
        month = m;
      }
      group.add(t);
    }
    flush();
    return out;
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'Catch Log',
      applicationVersion: '0.1.0',
      applicationIcon: const Icon(Icons.phishing_rounded, size: 40),
      children: const [
        Text('A fishing diary for the GPS logger. Everything stays on this phone.\n\n'
            'Maps © OpenFreeMap, © OpenMapTiles, data © OpenStreetMap contributors. '
            'Weather and marine data from Open-Meteo.com (CC BY 4.0).'),
      ],
    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 10),
      child: Text(label.toUpperCase(),
          style: t.labelLarge?.copyWith(
              letterSpacing: 1.2, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
    );
  }
}

class _UndatedCard extends StatelessWidget {
  const _UndatedCard(this.catches);
  final List<StoredCatch> catches;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final names = <String, int>{};
    for (final c in catches) {
      names[c.angler] = (names[c.angler] ?? 0) + 1;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        color: cs.secondaryContainer.withValues(alpha: 0.5),
        child: ListTile(
          leading: const Icon(Icons.event_busy_rounded),
          title: Text('${catches.length} ${catches.length == 1 ? 'catch' : 'catches'} without a date'),
          subtitle: Text('${names.entries.map((e) => '${e.key} ${e.value}').join(', ')} · '
              'pressed before the GPS had ever had a fix, so they can\'t go in a trip'),
        ),
      ),
    );
  }
}

class TripCard extends StatelessWidget {
  const TripCard({super.key, required this.trip, required this.onTap});
  final Trip trip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = trip.stats;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final start = Fmt.local(s.startMs);
    final anglers = {'Jase': 0, 'Matt': 0, ...s.catchesByAngler};
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            RouteThumbnail(trip: trip, size: 84),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(Fmt.dayShort(start).toUpperCase(),
                    style: t.labelMedium?.copyWith(color: cs.primary, letterSpacing: 0.8, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(Fmt.tripName(s.startMs), style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('${Fmt.timeMs(s.startMs)} · ${Fmt.duration(s.duration)} · ${Fmt.distance(s.distanceM)}',
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final e in anglers.entries) AnglerCount(e.key, e.value, dense: true),
                ]),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}
