/// The logger's Bluetooth LE transfer protocol, version 1.
/// See `docs/ble-protocol.md` in the repo root.
library;

import 'dart:convert';
import 'dart:typed_data';

const String serviceUuid = '1f5f0001-56c8-49fb-9d0c-055269d0a2e3';
const String rxCharUuid = '1f5f0002-56c8-49fb-9d0c-055269d0a2e3'; // phone -> logger
const String txCharUuid = '1f5f0003-56c8-49fb-9d0c-055269d0a2e3'; // logger -> phone
const String advertisedName = 'GPS Logger';
/// The newest protocol version the app speaks. Older loggers still work:
/// version 2 added the trip meter and version 3 ERASE_LOGS, and nothing
/// earlier changed.
const int protocolVersion = 3;

/// The first version with the trip meter (METER, METER_RESET).
const int meterProtocolVersion = 2;

abstract final class Cmd {
  static const hello = 0x01;
  static const list = 0x02;
  static const get = 0x03;
  static const confirm = 0x04;
  static const abort = 0x05;
  static const meter = 0x06; // v2
  static const meterReset = 0x07; // v2: reset u32 (UTC seconds)
  static const eraseLogs = 0x08; // v3: the 4 ASCII bytes "ERAS"
}

abstract final class Evt {
  static const hello = 0x81;
  static const file = 0x82;
  static const listEnd = 0x83;
  static const begin = 0x84;
  static const end = 0x85;
  static const confirmed = 0x86;
  static const meter = 0x87; // v2
  static const erased = 0x88; // v3
  static const data = 0x90;
  static const error = 0xEE;
}

/// Error codes from the logger, with wording for people.
String describeLoggerError(int code, String text) {
  switch (code) {
    case 2:
      return 'The logger refused the file name';
    case 3:
      return 'The file is no longer on the logger';
    case 4:
      return 'The logger is busy sending another file';
    case 1:
      return 'The logger doesn\'t know that command (its firmware is older than this app)';
    case 5:
      return 'The logger can\'t read or write its SD card';
    case 6:
      return 'The logger hit a read error on its SD card';
    case 7:
      return 'The file changed on the logger, so it was kept there';
    case 8:
      return 'The logger couldn\'t move the file to /uploaded, so it was kept';
    case 9:
      return 'The logger got a message that was too short';
    case 10:
      return 'The logger refused the erase because the command arrived damaged. Nothing was erased';
    default:
      return text.isNotEmpty ? text : 'Logger error $code';
  }
}

// ---- Commands ----

Uint8List encodeHello() => Uint8List.fromList([Cmd.hello]);
Uint8List encodeList() => Uint8List.fromList([Cmd.list]);
Uint8List encodeAbort() => Uint8List.fromList([Cmd.abort]);
Uint8List encodeMeter() => Uint8List.fromList([Cmd.meter]);

/// ERASE_LOGS (v3), with the guard bytes "ERAS" so a stray or damaged write
/// can't erase anything.
Uint8List encodeEraseLogs() => Uint8List.fromList([Cmd.eraseLogs, ...ascii.encode('ERAS')]);

/// METER_RESET: count from [resetUtcSeconds] (0 = count everything).
Uint8List encodeMeterReset(int resetUtcSeconds) {
  final b = Uint8List(5);
  b[0] = Cmd.meterReset;
  ByteData.sublistView(b).setUint32(1, resetUtcSeconds, Endian.little);
  return b;
}

Uint8List encodeGet(String name) =>
    Uint8List.fromList([Cmd.get, ...ascii.encode(name)]);

Uint8List encodeConfirm(int crc, String name) {
  final n = ascii.encode(name);
  final b = Uint8List(5 + n.length);
  b[0] = Cmd.confirm;
  ByteData.sublistView(b).setUint32(1, crc, Endian.little);
  b.setRange(5, b.length, n);
  return b;
}

// ---- Events ----

sealed class LoggerEvent {
  const LoggerEvent();
}

class HelloEvent extends LoggerEvent {
  const HelloEvent(this.version, this.chunk);
  final int version;
  final int chunk;
}

class FileEvent extends LoggerEvent {
  const FileEvent(this.size, this.name);
  final int size;
  final String name;
}

class ListEndEvent extends LoggerEvent {
  const ListEndEvent(this.count);
  final int count;
}

class BeginEvent extends LoggerEvent {
  const BeginEvent(this.size, this.name);
  final int size;
  final String name;
}

class DataEvent extends LoggerEvent {
  const DataEvent(this.offset, this.bytes);
  final int offset;
  final Uint8List bytes;
}

class EndEvent extends LoggerEvent {
  const EndEvent(this.size, this.crc);
  final int size;
  final int crc;
}

class ConfirmedEvent extends LoggerEvent {
  const ConfirmedEvent(this.name);
  final String name;
}

/// The logger's own trip meter (v2).
class MeterEvent extends LoggerEvent {
  const MeterEvent({
    required this.resetUtcSeconds,
    required this.jase,
    required this.matt,
    required this.distanceM,
    required this.waterS,
    required this.flags,
  });

  /// The reset in force; 0 means never reset.
  final int resetUtcSeconds;
  final int jase;
  final int matt;
  final int distanceM;
  final int waterS;
  final int flags;

  /// The card couldn't be read for the last rebuild, so the numbers may be low.
  bool get incomplete => flags & 0x01 != 0;

  /// The logger hasn't had GPS time since it started.
  bool get clockNotSet => flags & 0x02 != 0;

  DateTime? get resetAt =>
      resetUtcSeconds == 0 ? null : DateTime.fromMillisecondsSinceEpoch(resetUtcSeconds * 1000, isUtc: true);
}

/// The logger erased its log files (v3). A METER event at zero follows.
class ErasedEvent extends LoggerEvent {
  const ErasedEvent({required this.deleted, required this.failed, required this.flags});

  /// Log files deleted.
  final int deleted;

  /// Log files that couldn't be deleted: still on the card, and in the next LIST.
  final int failed;
  final int flags;

  /// `/trip.txt` couldn't be written: after a restart the logger would count
  /// from its old reset time.
  bool get resetNotSaved => flags & 0x01 != 0;
}

class ErrorEvent extends LoggerEvent {
  const ErrorEvent(this.code, this.text);
  final int code;
  final String text;
  String get message => describeLoggerError(code, text);
}

class UnknownEvent extends LoggerEvent {
  const UnknownEvent(this.op);
  final int op;
}

class ProtocolException implements Exception {
  ProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}

String _name(Uint8List b, int from) =>
    from >= b.length ? '' : latin1.decode(b.sublist(from));

/// Decodes one TX notification. Throws [ProtocolException] if it's too short.
LoggerEvent decodeEvent(Uint8List b) {
  if (b.isEmpty) throw ProtocolException('Empty message');
  final d = ByteData.sublistView(b);
  void need(int n) {
    if (b.length < n) {
      throw ProtocolException('Message 0x${b[0].toRadixString(16)} too short (${b.length} bytes)');
    }
  }

  switch (b[0]) {
    case Evt.hello:
      need(4);
      return HelloEvent(b[1], d.getUint16(2, Endian.little));
    case Evt.file:
      need(5);
      return FileEvent(d.getUint32(1, Endian.little), _name(b, 5));
    case Evt.listEnd:
      need(3);
      return ListEndEvent(d.getUint16(1, Endian.little));
    case Evt.begin:
      need(5);
      return BeginEvent(d.getUint32(1, Endian.little), _name(b, 5));
    case Evt.data:
      need(5);
      return DataEvent(d.getUint32(1, Endian.little), Uint8List.sublistView(b, 5));
    case Evt.end:
      need(9);
      return EndEvent(d.getUint32(1, Endian.little), d.getUint32(5, Endian.little));
    case Evt.confirmed:
      return ConfirmedEvent(_name(b, 1));
    case Evt.meter:
      need(18);
      return MeterEvent(
        resetUtcSeconds: d.getUint32(1, Endian.little),
        jase: d.getUint16(5, Endian.little),
        matt: d.getUint16(7, Endian.little),
        distanceM: d.getUint32(9, Endian.little),
        waterS: d.getUint32(13, Endian.little),
        flags: b[17],
      );
    case Evt.erased:
      need(6);
      return ErasedEvent(
          deleted: d.getUint16(1, Endian.little), failed: d.getUint16(3, Endian.little), flags: b[5]);
    case Evt.error:
      need(2);
      return ErrorEvent(b[1], _name(b, 2));
    default:
      return UnknownEvent(b[0]);
  }
}
