import 'package:permission_handler/permission_handler.dart';
import 'package:universal_ble/universal_ble.dart';

enum PermissionState { granted, denied, blocked }

/// Bluetooth permissions. Android 12+ needs "Nearby devices" (BLUETOOTH_SCAN
/// and BLUETOOTH_CONNECT; the scan is declared neverForLocation). Android 11
/// and older need location to scan instead.
class BlePermissions {
  static Future<bool> granted() => UniversalBle.hasPermissions();

  /// Asks for whatever's missing. Returns [PermissionState.blocked] when
  /// Android won't show the prompt again (the person must use Settings).
  static Future<PermissionState> request() async {
    if (await granted()) return PermissionState.granted;
    final bt = await [Permission.bluetoothScan, Permission.bluetoothConnect].request();
    if (await granted()) return PermissionState.granted;
    if (bt.values.any((s) => s.isPermanentlyDenied)) return PermissionState.blocked;
    if (bt.values.every((s) => s.isGranted)) {
      // Older Android: the Bluetooth permissions are implied, location isn't.
      final loc = await Permission.locationWhenInUse.request();
      if (await granted()) return PermissionState.granted;
      if (loc.isPermanentlyDenied) return PermissionState.blocked;
    }
    return PermissionState.denied;
  }

  static Future<void> openSettings() => openAppSettings();
}
