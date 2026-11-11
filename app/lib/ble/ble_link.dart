import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import '../sync/logger_session.dart';
import 'protocol.dart';

/// Finds the logger. It only advertises while its switch is on Transfer.
class LoggerScanner {
  /// Scans for up to [timeout] and returns the first logger seen (the
  /// strongest one if several turn up in the first second), or null.
  static Future<BleDevice?> findLogger({Duration timeout = const Duration(seconds: 12)}) async {
    final found = <BleDevice>[];
    final first = Completer<void>();
    final sub = UniversalBle.scanStream.listen((d) {
      final advertisesService = d.services.any((s) => s.toLowerCase() == serviceUuid);
      if (!advertisesService && d.name != advertisedName) return;
      found.removeWhere((x) => x.deviceId == d.deviceId);
      found.add(d);
      if (!first.isCompleted) first.complete();
    });
    try {
      await UniversalBle.startScan(scanFilter: ScanFilter(withServices: [serviceUuid]));
      await first.future.timeout(timeout, onTimeout: () {});
      if (found.isNotEmpty) {
        // Give a second logger nearby a moment to show up, then take the closest.
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    } finally {
      await sub.cancel();
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }
    if (found.isEmpty) return null;
    found.sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));
    return found.first;
  }
}

/// The logger's GATT service over Bluetooth LE.
class BleLoggerTransport implements LoggerTransport {
  BleLoggerTransport._(this.deviceId);

  final String deviceId;
  final _disconnected = Completer<void>();
  StreamSubscription<bool>? _connSub;
  int mtu = 23;

  static Future<BleLoggerTransport> connect(String deviceId) async {
    final t = BleLoggerTransport._(deviceId);
    await UniversalBle.connect(deviceId, timeout: const Duration(seconds: 15));
    t._connSub = UniversalBle.connectionStream(deviceId).listen((up) {
      if (!up && !t._disconnected.isCompleted) t._disconnected.complete();
    });
    try {
      await UniversalBle.discoverServices(deviceId);
      // The logger asks for 247 itself; asking too covers phones that wait for
      // the central. Chunks are MTU - 8 bytes, so this makes transfers ~15x faster.
      try {
        t.mtu = await UniversalBle.requestMtu(deviceId, 247);
      } catch (_) {}
      try {
        await UniversalBle.requestConnectionPriority(deviceId, BleConnectionPriority.highPerformance);
      } catch (_) {}
      await UniversalBle.subscribeNotifications(deviceId, serviceUuid, txCharUuid);
    } catch (e) {
      await t.close();
      rethrow;
    }
    return t;
  }

  @override
  Stream<Uint8List> get notifications => UniversalBle.characteristicValueStream(deviceId, txCharUuid);

  @override
  Future<void> get disconnected => _disconnected.future;

  @override
  Future<void> write(Uint8List data) =>
      UniversalBle.write(deviceId, serviceUuid, rxCharUuid, data, withoutResponse: false);

  Future<void> close() async {
    await _connSub?.cancel();
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (_) {}
    if (!_disconnected.isCompleted) _disconnected.complete();
  }
}
