import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../sync/permissions.dart';
import '../sync/sync_controller.dart';
import 'format.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  /// Pops with a trip id when the person taps "View trip".
  static Route<int> route() => PageRouteBuilder<int>(
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, _, _) => const SyncScreen(),
        transitionsBuilder: (_, a, _, child) {
          final curved = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
          return SlideTransition(
            position: Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(curved),
            child: FadeTransition(opacity: curved, child: child),
          );
        },
      );

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late SyncController _sync;
  bool _started = false;
  SyncPhase? _lastPhase;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync = AppScope.of(context).sync;
    if (!_started) {
      _started = true;
      _sync.addListener(_onChange);
      if (!_sync.busy) _sync.start();
    }
  }

  void _onChange() {
    if (_sync.phase != _lastPhase) {
      if (_sync.phase == SyncPhase.done && _sync.summary.files > 0) HapticFeedback.mediumImpact();
      _lastPhase = _sync.phase;
    }
  }

  @override
  void dispose() {
    _sync.removeListener(_onChange);
    if (_sync.busy && _sync.phase != SyncPhase.transferring) _sync.cancel();
    super.dispose();
  }

  Future<bool> _confirmLeave() async {
    if (_sync.phase != SyncPhase.transferring) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop syncing?'),
        content: const Text('Files already synced are safe. The file being downloaded stays on the logger '
            'and comes across next time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep going')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop')),
        ],
      ),
    );
    if (leave == true) await _sync.cancel();
    return leave == true;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _sync,
      builder: (context, _) => PopScope(
        canPop: _sync.phase != SyncPhase.transferring,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          if (await _confirmLeave() && context.mounted) Navigator.of(context).pop();
        },
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            title: const Text('Sync logger'),
          ),
          body: SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              switchInCurve: Curves.easeOutCubic,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(a), child: child),
              ),
              child: KeyedSubtree(key: ValueKey(_phaseKey()), child: _body(context)),
            ),
          ),
        ),
      ),
    );
  }

  /// Groups phases that share a layout, so the visual doesn't flash between them.
  String _phaseKey() => switch (_sync.phase) {
        SyncPhase.idle || SyncPhase.scanning || SyncPhase.connecting || SyncPhase.listing => 'search',
        final p => p.name,
      };

  Widget _body(BuildContext context) {
    final s = _sync;
    switch (s.phase) {
      case SyncPhase.idle:
      case SyncPhase.scanning:
      case SyncPhase.connecting:
      case SyncPhase.listing:
        final (title, body) = switch (s.phase) {
          SyncPhase.connecting => ('Connecting…', 'Found ${s.deviceName ?? 'the logger'}.'),
          SyncPhase.listing => ('Checking for new files…', 'Connected to ${s.deviceName ?? 'the logger'}.'),
          _ => (
              'Looking for your logger…',
              'Put its switch on Transfer and keep the phone within a few metres.'
            ),
        };
        return _Centered(
          visual: const _Radar(),
          title: title,
          body: body,
        );

      case SyncPhase.needsPermission:
        return _Centered(
          visual: const _IconBubble(Icons.bluetooth_rounded),
          title: 'Allow Nearby devices',
          body: 'Catch Log uses Bluetooth to download trips from your logger. '
              'Android calls this "Nearby devices". It doesn\'t use your location.',
          actions: [FilledButton(onPressed: s.requestPermission, child: const Text('Allow'))],
        );

      case SyncPhase.permissionBlocked:
        return _Centered(
          visual: const _IconBubble(Icons.bluetooth_disabled_rounded, error: true),
          title: 'Bluetooth permission is off',
          body: 'Open Settings, tap Permissions, and allow Nearby devices for Catch Log. Then come back here.',
          actions: [
            FilledButton(onPressed: BlePermissions.openSettings, child: const Text('Open Settings')),
            OutlinedButton(onPressed: s.start, child: const Text('I\'ve allowed it')),
          ],
        );

      case SyncPhase.bluetoothOff:
        return _Centered(
          visual: const _IconBubble(Icons.bluetooth_disabled_rounded),
          title: 'Bluetooth is off',
          body: 'Turn on Bluetooth to reach the logger. Syncing starts as soon as it\'s on.',
          actions: [FilledButton(onPressed: s.enableBluetooth, child: const Text('Turn on Bluetooth'))],
        );

      case SyncPhase.bluetoothUnsupported:
        return const _Centered(
          visual: _IconBubble(Icons.bluetooth_disabled_rounded, error: true),
          title: 'No Bluetooth LE',
          body: 'This phone can\'t talk to the logger.',
        );

      case SyncPhase.notFound:
        return _Centered(
          visual: const _IconBubble(Icons.search_off_rounded),
          title: 'Logger not found',
          body: '',
          bodyWidget: const _Tips([
            'Put the logger\'s switch on Transfer. Its screen says "Waiting for phone".',
            'Keep the phone within a few metres of it.',
            'Only one phone can connect at a time. Close the web page on any other phone.',
          ]),
          actions: [FilledButton(onPressed: s.start, child: const Text('Try again'))],
        );

      case SyncPhase.transferring:
        return _Transferring(sync: s);

      case SyncPhase.done:
        return _Done(sync: s);

      case SyncPhase.failed:
        return _Centered(
          visual: const _IconBubble(Icons.sync_problem_rounded, error: true),
          title: s.files.any((f) => f.state == FileState.done) ? 'Sync interrupted' : 'Sync failed',
          body: s.error ?? 'Something went wrong.',
          bodyWidget: s.files.isEmpty ? null : _FileList(files: s.files),
          actions: [
            FilledButton(onPressed: s.start, child: const Text('Try again')),
          ],
        );
    }
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.visual, required this.title, required this.body, this.bodyWidget, this.actions = const []});
  final Widget visual;
  final String title;
  final String body;
  final Widget? bodyWidget;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight - 32),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            SizedBox(height: 200, child: Center(child: visual)),
            const SizedBox(height: 24),
            Text(title, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700), textAlign: TextAlign.center),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(body,
                  textAlign: TextAlign.center,
                  style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant, height: 1.4)),
            ],
            if (bodyWidget != null) ...[const SizedBox(height: 16), bodyWidget!],
            if (actions.isNotEmpty) const SizedBox(height: 32),
            for (final a in actions) Padding(padding: const EdgeInsets.only(bottom: 10), child: SizedBox(width: double.infinity, child: a)),
          ]),
        ),
      ),
    );
  }
}

class _IconBubble extends StatelessWidget {
  const _IconBubble(this.icon, {this.error = false});
  final IconData icon;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.6, end: 1),
      duration: const Duration(milliseconds: 500),
      curve: Curves.elasticOut,
      builder: (_, v, child) => Transform.scale(scale: v, child: child),
      child: Container(
        width: 128,
        height: 128,
        decoration: BoxDecoration(
            color: error ? cs.errorContainer : cs.secondaryContainer, shape: BoxShape.circle),
        child: Icon(icon, size: 60, color: error ? cs.onErrorContainer : cs.onSecondaryContainer),
      ),
    );
  }
}

/// Pulsing rings around a Bluetooth icon while scanning.
class _Radar extends StatefulWidget {
  const _Radar();
  @override
  State<_Radar> createState() => _RadarState();
}

class _RadarState extends State<_Radar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => CustomPaint(
        size: const Size(200, 200),
        painter: _RadarPainter(_c.value, cs.primary),
        child: SizedBox(
          width: 200,
          height: 200,
          child: Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle, boxShadow: [
                BoxShadow(color: cs.primary.withValues(alpha: 0.35), blurRadius: 24, spreadRadius: 2),
              ]),
              child: Icon(Icons.bluetooth_searching_rounded, color: cs.onPrimary, size: 40),
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.t, this.color);
  final double t;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final r = 42 + p * 58;
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..color = color.withValues(alpha: (1 - p) * 0.35)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5);
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.t != t;
}

class _Tips extends StatelessWidget {
  const _Tips(this.tips);
  final List<String> tips;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(children: [
        for (final (i, tip) in tips.indexed)
          Padding(
            padding: EdgeInsets.only(bottom: i == tips.length - 1 ? 0 : 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(
                radius: 11,
                backgroundColor: cs.primaryContainer,
                child: Text('${i + 1}', style: t.labelSmall?.copyWith(color: cs.onPrimaryContainer)),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(tip, style: t.bodyMedium?.copyWith(height: 1.35))),
            ]),
          ),
      ]),
    );
  }
}

class _Transferring extends StatelessWidget {
  const _Transferring({required this.sync});
  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final total = sync.totalBytes, got = sync.receivedBytes;
    final frac = total == 0 ? 0.0 : got / total;
    final speed = sync.speed;
    final eta = speed != null && speed > 0 ? Duration(seconds: ((total - got) / speed).round()) : null;
    final idx = sync.currentIndex;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
      child: Column(children: [
        const SizedBox(height: 12),
        SizedBox(
          width: 200,
          height: 200,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: frac),
            duration: const Duration(milliseconds: 250),
            builder: (_, v, _) => CustomPaint(
              painter: _RingPainter(v, cs.primary, cs.surfaceContainerHighest),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${(v * 100).floor()}%',
                      style: t.displaySmall?.copyWith(
                          fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()])),
                  Text(Fmt.bytes(got), style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ]),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('Downloading ${idx + 1} of ${sync.files.length}',
            style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(
          [
            if (speed != null) '${Fmt.bytes(speed.round())}/s',
            if (eta != null) '${eta.inMinutes > 0 ? '${eta.inMinutes} min ' : ''}${eta.inSeconds % 60} s left',
          ].join(' · ').ifEmpty('Starting…'),
          style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        _FileList(files: sync.files),
        const SizedBox(height: 16),
        Text('Keep the phone near the logger. Each file is checked, saved, and only then removed from the logger.',
            textAlign: TextAlign.center, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.v, this.color, this.track);
  final double v;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = rect.deflate(10);
    canvas.drawArc(r, 0, math.pi * 2, false,
        Paint()
          ..color = track
          ..style = PaintingStyle.stroke
          ..strokeWidth = 14);
    canvas.drawArc(r, -math.pi / 2, math.pi * 2 * v, false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 14);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.v != v || old.color != color;
}

class _FileList extends StatelessWidget {
  const _FileList({required this.files});
  final List<FileProgress> files;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(children: [
        for (final f in files)
          ListTile(
            dense: true,
            leading: switch (f.state) {
              FileState.done => Icon(Icons.check_circle_rounded, color: cs.primary),
              FileState.failed => Icon(Icons.error_rounded, color: cs.error),
              FileState.waiting => Icon(Icons.schedule_rounded, color: cs.onSurfaceVariant),
              _ => const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            },
            title: Text(_label(f.name), style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text(switch (f.state) {
              FileState.waiting => Fmt.bytes(f.size),
              FileState.downloading => '${Fmt.bytes(f.received)} of ${Fmt.bytes(f.size)}',
              FileState.saving => 'Saving…',
              FileState.confirming => 'Removing from the logger…',
              FileState.done => f.alreadyHad
                  ? 'Already on this phone · removed from the logger'
                  : 'Synced · ${Fmt.bytes(f.size)}',
              FileState.failed => f.error ?? 'Failed',
            }),
          ),
      ]),
    );
  }

  /// gps20261108.csv -> Sat 8 Nov
  String _label(String name) {
    final m = RegExp(r'gps(\d{4})(\d{2})(\d{2})\.csv').firstMatch(name);
    if (m == null) return name == 'gpsnodate.csv' ? 'Catches without a date' : name;
    return Fmt.dayShort(DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)));
  }
}

class _Done extends StatelessWidget {
  const _Done({required this.sync});
  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final s = sync.summary;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    if (s.files == 0 && s.failures.isEmpty) {
      return _Centered(
        visual: const _IconBubble(Icons.check_rounded),
        title: 'All caught up',
        body: 'The logger has no new files. You can put its switch back on Logging.',
        actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
      );
    }
    final trips = s.tripIds.toList()..sort();
    return _Centered(
      visual: const _IconBubble(Icons.check_rounded),
      title: s.failures.isEmpty ? 'Synced' : 'Synced, with problems',
      body: [
        '${s.files} ${s.files == 1 ? 'file' : 'files'}',
        if (trips.isNotEmpty) '${trips.length} ${trips.length == 1 ? 'trip' : 'trips'}',
        '${s.newCatches} new ${s.newCatches == 1 ? 'catch' : 'catches'}',
      ].join(' · '),
      bodyWidget: Column(children: [
        if (s.undatedCatches > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
                '${s.undatedCatches} ${s.undatedCatches == 1 ? 'catch was' : 'catches were'} made before the GPS knew the date.',
                textAlign: TextAlign.center,
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          ),
        _FileList(files: sync.files),
      ]),
      actions: [
        if (trips.isNotEmpty)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(trips.last),
            child: Text(trips.length == 1 ? 'View trip' : 'View latest trip'),
          ),
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      ],
    );
  }
}
