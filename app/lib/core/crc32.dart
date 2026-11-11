import 'dart:typed_data';

/// Standard CRC-32 (zlib, PNG, Ethernet): reflected, polynomial 0xEDB88320,
/// initial value and final XOR 0xFFFFFFFF. The same as the logger firmware
/// (`src/crc32.cpp`) and the Web Bluetooth page.
class Crc32 {
  Crc32._();

  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final t = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      }
      t[i] = c;
    }
    return t;
  }

  /// CRC-32 of [bytes], as an unsigned 32-bit value.
  static int of(List<int> bytes) => update(0, bytes);

  /// Continues a CRC over more bytes. Start with `crc = 0`.
  static int update(int crc, List<int> bytes) {
    var c = crc ^ 0xFFFFFFFF;
    for (final b in bytes) {
      c = _table[(c ^ b) & 0xFF] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static String hex(int crc) => '0x${crc.toRadixString(16).padLeft(8, '0')}';
}
