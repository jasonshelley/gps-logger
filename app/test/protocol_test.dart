import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catch_log/ble/protocol.dart';
import 'package:catch_log/core/crc32.dart';
import 'package:catch_log/sync/logger_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_logger.dart';

void main() {
  group('CRC-32', () {
    test('matches the protocol doc example', () {
      expect(Crc32.of(ascii.encode('The quick brown fox jumps over the lazy dog')), 0x414fa339);
    });
    test('empty input and the standard check value', () {
      expect(Crc32.of(const []), 0);
      expect(Crc32.of(ascii.encode('123456789')), 0xCBF43926);
    });
    test('update in pieces equals one pass', () {
      final data = List<int>.generate(10000, (i) => (i * 31) & 0xFF);
      final whole = Crc32.of(data);
      final pieces = Crc32.update(Crc32.update(0, data.sublist(0, 4321)), data.sublist(4321));
      expect(pieces, whole);
    });
  });

  group('codec', () {
    test('CONFIRM is opcode, little-endian CRC, then name', () {
      final b = encodeConfirm(0x1c291ca3, 'gps20261110.csv');
      expect(b.sublist(0, 5), [0x04, 0xa3, 0x1c, 0x29, 0x1c]);
      expect(ascii.decode(b.sublist(5)), 'gps20261110.csv');
    });
    test('GET carries the name', () {
      expect(encodeGet('gps1.csv'), [0x03, ...ascii.encode('gps1.csv')]);
    });
    test('decodes HELLO, FILE, END, ERROR', () {
      final hello = decodeEvent(Uint8List.fromList([0x81, 1, 239, 0])) as HelloEvent;
      expect((hello.version, hello.chunk), (1, 239));
      final file = decodeEvent(Uint8List.fromList([0x82, 0x22, 0xC8, 0, 0, ...ascii.encode('gps20261110.csv')]))
          as FileEvent;
      expect((file.size, file.name), (51234, 'gps20261110.csv'));
      final end = decodeEvent(Uint8List.fromList([0x85, 0x22, 0xC8, 0, 0, 0xa3, 0x1c, 0x29, 0x1c])) as EndEvent;
      expect((end.size, end.crc), (51234, 0x1c291ca3));
      final err = decodeEvent(Uint8List.fromList([0xEE, 7, ...ascii.encode('crc')])) as ErrorEvent;
      expect(err.code, 7);
      expect(err.message, contains('kept'));
    });
    test('short messages throw', () {
      expect(() => decodeEvent(Uint8List.fromList([0x85, 1, 2])), throwsA(isA<ProtocolException>()));
      expect(() => decodeEvent(Uint8List(0)), throwsA(isA<ProtocolException>()));
    });
  });

  group('session against a fake logger', () {
    final csv = File('test/fixtures/gps20261108.csv').readAsBytesSync();

    test('hello, list, get, confirm moves the file', () async {
      final logger = FakeLogger({'gps20261108.csv': csv, 'gps20261109.csv': [1, 2, 3]});
      final s = LoggerSession(logger);
      final h = await s.hello();
      expect(h.chunk, 239);
      final files = await s.list();
      expect(files.map((f) => f.name), ['gps20261108.csv', 'gps20261109.csv']);
      var progressCalls = 0;
      final got = await s.get('gps20261108.csv', onProgress: (r, n) => progressCalls++);
      expect(got.bytes, csv);
      expect(got.crc, Crc32.of(csv));
      expect(progressCalls, greaterThan(100));
      await s.confirm(got.name, got.crc);
      expect(logger.uploaded.keys, ['gps20261108.csv']);
      expect(logger.files.keys, ['gps20261109.csv']);
      s.dispose();
    });

    test('works with the default 23-byte MTU (15-byte chunks)', () async {
      final logger = FakeLogger({'gps20261108.csv': csv}, chunk: 15);
      final s = LoggerSession(logger);
      await s.hello();
      final got = await s.get('gps20261108.csv');
      expect(got.bytes, csv);
      s.dispose();
    });

    test('a missing chunk fails and nothing is confirmed', () async {
      final logger = FakeLogger({'gps20261108.csv': csv})..dropChunkAt = 239 * 3;
      final s = LoggerSession(logger);
      await expectLater(s.get('gps20261108.csv'),
          throwsA(isA<TransferException>().having((e) => e.message, 'message', contains('out of order'))));
      expect(logger.sent.last, Cmd.abort);
      expect(logger.uploaded, isEmpty);
      s.dispose();
    });

    test('corrupted data fails the CRC check', () async {
      final logger = FakeLogger({'gps20261108.csv': csv})..corruptByteAt = 5000;
      final s = LoggerSession(logger);
      await expectLater(s.get('gps20261108.csv'),
          throwsA(isA<TransferException>().having((e) => e.message, 'message', contains('CRC mismatch'))));
      s.dispose();
    });

    test('a disconnect mid-file fails cleanly', () async {
      final logger = FakeLogger({'gps20261108.csv': csv})..disconnectAfterBytes = 2000;
      final s = LoggerSession(logger);
      await expectLater(s.get('gps20261108.csv'),
          throwsA(isA<TransferException>().having((e) => e.message, 'message', contains('disconnected'))));
      await expectLater(s.list(), throwsA(isA<TransferException>()));
      s.dispose();
    });

    test('a stalled transfer times out', () async {
      final logger = FakeLogger({'gps20261108.csv': csv})..silentAfterBegin = true;
      final s = LoggerSession(logger, stallTimeout: const Duration(milliseconds: 200));
      await expectLater(s.get('gps20261108.csv'),
          throwsA(isA<TransferException>().having((e) => e.message, 'message', contains('stalled'))));
      s.dispose();
    });

    test('logger errors are reported in plain words', () async {
      final logger = FakeLogger({});
      final s = LoggerSession(logger);
      await expectLater(s.get('gps20990101.csv'),
          throwsA(isA<TransferException>().having((e) => e.message, 'message', contains('no longer'))));
      await expectLater(s.confirm('gps20990101.csv', 1), throwsA(isA<TransferException>()));
      s.dispose();
    });

    test('CONFIRM with a wrong CRC keeps the file', () async {
      final logger = FakeLogger({'gps20261108.csv': csv});
      final s = LoggerSession(logger);
      await expectLater(s.confirm('gps20261108.csv', 0xdeadbeef), throwsA(isA<TransferException>()));
      expect(logger.files.keys, ['gps20261108.csv']);
      s.dispose();
    });
  });
}
