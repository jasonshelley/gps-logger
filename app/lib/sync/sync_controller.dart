import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../ble/ble_link.dart';
import '../ble/protocol.dart';
import '../data/repository.dart';
import 'logger_session.dart';
import 'permissions.dart';

enum SyncPhase {
  idle,
  needsPermission, // explain, then ask
  permissionBlocked, // only Settings can fix it
  bluetoothOff,
  bluetoothUnsupported,
  scanning,
  notFound,
  connecting,
  listing,
  transferring,
  done,
  failed,
}

class FileProgress {
  FileProgress(this.name, this.size);
  final String name;
  final int size;
  int received = 0;
  FileState state = FileState.waiting;
  String? error;

  /// Stored by an earlier, interrupted sync; this run only confirmed it.
  bool alreadyHad = false;
}

enum FileState { waiting, downloading, saving, confirming, done, failed }

class SyncSummary {
  int files = 0;
  int alreadyHad = 0;
  int newPoints = 0;
  int newCatches = 0;
  int undatedCatches = 0;
  final Set<int> tripIds = {};
  final List<String> failures = [];
}

/// Runs one sync: permission, Bluetooth, scan, connect, then for each file
/// download, check CRC, store, and only then confirm to the logger.
class SyncController extends ChangeNotifier {
  SyncController(this.repo);

  final Repository repo;

  SyncPhase phase = SyncPhase.idle;
  String? deviceName;
  String? error;
  List<FileProgress> files = [];
  int currentIndex = -1;
  SyncSummary summary = SyncSummary();
  DateTime? _transferStart;
  int _bytesAtStart = 0;

  BleLoggerTransport? _transport;
  LoggerSession? _session;
  StreamSubscription<AvailabilityState>? _btSub;
  bool _cancelled = false;
  bool _running = false;

  bool get busy => _running;

  int get totalBytes => files.fold(0, (a, f) => a + f.size);
  int get receivedBytes => files.fold(0, (a, f) => a + (f.state == FileState.done ? f.size : f.received));

  /// Bytes per second over the current run.
  double? get speed {
    final s = _transferStart;
    if (s == null) return null;
    final secs = DateTime.now().difference(s).inMilliseconds / 1000;
    if (secs < 1) return null;
    return (receivedBytes - _bytesAtStart) / secs;
  }

  void _set(SyncPhase p, {String? err}) {
    debugPrint('[sync] ${p.name}${err != null ? ': $err' : ''}');
    phase = p;
    error = err;
    notifyListeners();
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _cancelled = false;
    summary = SyncSummary();
    files = [];
    currentIndex = -1;
    deviceName = null;
    try {
      await _run();
    } finally {
      _running = false;
      await _closeLink();
      notifyListeners();
    }
  }

  /// Called from the permission rationale screen's button.
  Future<void> requestPermission() async {
    final r = await BlePermissions.request();
    if (r == PermissionState.granted) {
      unawaited(start());
    } else {
      _set(r == PermissionState.blocked ? SyncPhase.permissionBlocked : SyncPhase.needsPermission);
    }
  }

  Future<void> enableBluetooth() async {
    try {
      await UniversalBle.enableBluetooth();
    } catch (_) {
      // Newer Android may refuse; the screen tells the person to use quick settings.
    }
  }

  Future<void> cancel() async {
    debugPrint('[sync] cancelled');
    _cancelled = true;
    await _teardown();
    if (phase != SyncPhase.done) _set(SyncPhase.idle);
  }

  Future<void> _teardown() async {
    await _btSub?.cancel();
    _btSub = null;
    await _closeLink();
  }

  Future<void> _closeLink() async {
    _session?.dispose();
    _session = null;
    final t = _transport;
    _transport = null;
    await t?.close();
  }

  Future<void> _run() async {
    // 1. Permission.
    if (!await BlePermissions.granted()) {
      _set(SyncPhase.needsPermission);
      return;
    }

    // 2. Bluetooth on?
    final state = await UniversalBle.getBluetoothAvailabilityState();
    if (state == AvailabilityState.unsupported) {
      _set(SyncPhase.bluetoothUnsupported);
      return;
    }
    if (state != AvailabilityState.poweredOn) {
      _set(SyncPhase.bluetoothOff);
      // Carry on by itself once Bluetooth comes on.
      _btSub = UniversalBle.availabilityStream.listen((s) {
        if (s == AvailabilityState.poweredOn && phase == SyncPhase.bluetoothOff) {
          _btSub?.cancel();
          _btSub = null;
          Future<void>.delayed(const Duration(milliseconds: 600), start);
        }
      });
      return;
    }

    // 3. Find the logger.
    _set(SyncPhase.scanning);
    final BleDevice? device;
    try {
      device = await LoggerScanner.findLogger();
    } catch (e) {
      _set(SyncPhase.failed, err: 'Bluetooth scan failed: $e');
      return;
    }
    if (_cancelled) return;
    if (device == null) {
      _set(SyncPhase.notFound);
      return;
    }
    deviceName = device.name ?? advertisedName;

    // 4. Connect and list.
    _set(SyncPhase.connecting);
    try {
      _transport = await BleLoggerTransport.connect(device.deviceId);
      _session = LoggerSession(_transport!);
      final hello = await _session!.hello();
      if (hello.version != protocolVersion) {
        debugPrint('Logger protocol v${hello.version}, app expects v$protocolVersion');
      }
      _set(SyncPhase.listing);
      final listed = await _session!.list();
      debugPrint('[sync] logger v${hello.version}, chunk ${hello.chunk}, ${listed.length} files: '
          '${listed.map((f) => '${f.name} ${f.size}').join(', ')}');
      // Oldest first: the names sort by date, with gpsnodate last.
      listed.sort((a, b) => a.name.compareTo(b.name));
      files = [for (final f in listed) FileProgress(f.name, f.size)];
    } catch (e) {
      if (_cancelled) return;
      _set(SyncPhase.failed, err: _friendly(e, 'Couldn\'t connect to the logger'));
      return;
    }

    // 5. Each file: download, check, store, confirm.
    _transferStart = DateTime.now();
    _bytesAtStart = 0;
    _set(SyncPhase.transferring);
    for (var i = 0; i < files.length; i++) {
      if (_cancelled) return;
      currentIndex = i;
      final f = files[i];
      try {
        f.state = FileState.downloading;
        notifyListeners();
        var lastNotify = DateTime.now();
        final got = await _session!.get(f.name, onProgress: (r, n) {
          f.received = r;
          final now = DateTime.now();
          if (now.difference(lastNotify).inMilliseconds > 100) {
            lastNotify = now;
            notifyListeners();
          }
        });
        f.state = FileState.saving;
        notifyListeners();
        final result = await repo.importLog(f.name, got.bytes, got.crc);
        summary.files++;
        if (result.alreadyHad) {
          summary.alreadyHad++;
          f.alreadyHad = true;
        }
        summary.newPoints += result.newPoints;
        summary.newCatches += result.newCatches;
        summary.undatedCatches += result.undatedCatches;
        summary.tripIds.addAll(result.tripIds);

        // Only now, with the data safely stored, may the logger move the file.
        f.state = FileState.confirming;
        notifyListeners();
        await _session!.confirm(f.name, got.crc);
        await repo.markConfirmed(f.name, got.crc);
        f.state = FileState.done;
        debugPrint('[sync] ${f.name}: ${got.bytes.length} bytes, CRC ${got.crc.toRadixString(16)}, '
            '${result.newPoints} points, ${result.newCatches} catches, confirmed');
        notifyListeners();
      } catch (e) {
        if (_cancelled) return;
        f.state = FileState.failed;
        f.error = _friendly(e, 'Failed');
        debugPrint('[sync] ${f.name} failed: $e');
        summary.failures.add('${f.name}: ${f.error}');
        notifyListeners();
        if (_transport == null || e is TransferException && e.message.contains('disconnected')) {
          _set(SyncPhase.failed,
              err: 'The connection to the logger dropped. Files already synced are safe; the rest are still on the logger.');
          return;
        }
      }
    }
    _set(SyncPhase.done);
  }

  String _friendly(Object e, String fallback) {
    if (e is TransferException) return e.message;
    final s = e.toString();
    if (s.contains('Timeout') || s.contains('timed out')) return '$fallback: it took too long to answer';
    return '$fallback: $s';
  }

  @override
  void dispose() {
    _cancelled = true;
    _teardown();
    super.dispose();
  }
}
