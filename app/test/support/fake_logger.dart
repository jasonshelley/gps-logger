import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catch_log/ble/protocol.dart';
import 'package:catch_log/core/crc32.dart';
import 'package:catch_log/sync/logger_session.dart';

/// A pretend logger implementing docs/ble-protocol.md, for tests.
class FakeLogger implements LoggerTransport {
  FakeLogger(Map<String, List<int>> files, {this.chunk = 239})
      : files = {for (final e in files.entries) e.key: Uint8List.fromList(e.value)};

  final Map<String, Uint8List> files;
  final Map<String, Uint8List> uploaded = {};
  final int chunk;

  /// Fault injection.
  int? dropChunkAt; // skip the DATA message at this offset
  int? corruptByteAt; // flip a byte in the data sent (CRC in END stays right)
  int? disconnectAfterBytes;
  bool silentAfterBegin = false;

  final _tx = StreamController<Uint8List>.broadcast();
  final _disconnected = Completer<void>();
  final sent = <int>[]; // opcodes received, for assertions

  @override
  Stream<Uint8List> get notifications => _tx.stream;

  @override
  Future<void> get disconnected => _disconnected.future;

  void disconnect() {
    if (!_disconnected.isCompleted) _disconnected.complete();
  }

  void _emit(List<int> b) => scheduleMicrotask(() => _tx.add(Uint8List.fromList(b)));

  Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
  Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);

  @override
  Future<void> write(Uint8List data) async {
    if (_disconnected.isCompleted) throw StateError('not connected');
    final op = data[0];
    sent.add(op);
    final name = ascii.decode(data.sublist(op == Cmd.confirm ? 5 : 1));
    switch (op) {
      case Cmd.hello:
        _emit([Evt.hello, protocolVersion, ..._u16(chunk)]);
      case Cmd.list:
        final names = files.keys.toList()..sort();
        for (final n in names) {
          _emit([Evt.file, ..._u32(files[n]!.length), ...ascii.encode(n)]);
        }
        _emit([Evt.listEnd, ..._u16(names.length)]);
      case Cmd.get:
        final f = files[name];
        if (f == null) {
          _emit([Evt.error, 3, ...ascii.encode('not found')]);
          return;
        }
        _emit([Evt.begin, ..._u32(f.length), ...ascii.encode(name)]);
        if (silentAfterBegin) return;
        for (var off = 0; off < f.length; off += chunk) {
          if (disconnectAfterBytes != null && off >= disconnectAfterBytes!) {
            scheduleMicrotask(disconnect);
            return;
          }
          if (off == dropChunkAt) continue;
          final end = off + chunk > f.length ? f.length : off + chunk;
          final payload = Uint8List.fromList(f.sublist(off, end));
          if (corruptByteAt != null && corruptByteAt! >= off && corruptByteAt! < end) {
            payload[corruptByteAt! - off] ^= 0xFF;
          }
          _emit([Evt.data, ..._u32(off), ...payload]);
        }
        _emit([Evt.end, ..._u32(f.length), ..._u32(Crc32.of(f))]);
      case Cmd.confirm:
        final crc = ByteData.sublistView(data).getUint32(1, Endian.little);
        final f = files[name];
        if (f == null) {
          _emit([Evt.error, 3, ...ascii.encode('not found')]);
        } else if (Crc32.of(f) != crc) {
          _emit([Evt.error, 7, ...ascii.encode('crc mismatch')]);
        } else {
          uploaded[name] = files.remove(name)!;
          _emit([Evt.confirmed, ...ascii.encode(name)]);
        }
      case Cmd.abort:
        break;
      default:
        _emit([Evt.error, 1, ...ascii.encode('unknown')]);
    }
  }
}
