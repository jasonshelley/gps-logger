import 'package:catch_log/core/photo_match.dart';
import 'package:flutter_test/flutter_test.dart';

const min = 60000;

void main() {
  final catches = [const CatchRef(1, 0), const CatchRef(2, 30 * min), const CatchRef(3, 35 * min)];

  test('a photo goes to the catch just before it', () {
    final m = matchPhotos([const PhotoRef('a', 2 * min), const PhotoRef('b', 31 * min)], catches);
    expect(m.byCatch[1]!.map((p) => p.id), ['a']);
    expect(m.byCatch[2]!.map((p) => p.id), ['b']);
    expect(m.unmatched, isEmpty);
  });

  test('after a second catch, photos go to the newer one', () {
    // 36 min: 6 min after catch 2, 1 min after catch 3.
    final m = matchPhotos([const PhotoRef('c', 36 * min)], catches);
    expect(m.byCatch.keys, [3]);
  });

  test('a photo a little before a catch still matches (clock skew)', () {
    final m = matchPhotos([const PhotoRef('d', -2 * min)], catches);
    expect(m.byCatch[1]!.single.id, 'd');
  });

  test('a photo just before a catch prefers that catch over one long before', () {
    // 29 min: 29 min after catch 1 (outside 20), 1 min before catch 2.
    final m = matchPhotos([const PhotoRef('e', 29 * min)], catches);
    expect(m.byCatch.keys, [2]);
  });

  test('before-time counts double when two catches qualify', () {
    // Catches at 0 and 10 min. Photo at 7 min: 7 min after #1, 3 min before #2 (cost 6) -> #2.
    // Photo at 9.5? no: at 4 min: 4 after #1, 6 before #2 (outside 3) -> #1.
    final cs = [const CatchRef(1, 0), const CatchRef(2, 10 * min)];
    final m = matchPhotos(
        [const PhotoRef('x', 4 * min), const PhotoRef('y', 8 * min)], cs,
        before: const Duration(minutes: 3));
    expect(m.byCatch[1]!.single.id, 'x');
    expect(m.byCatch[2]!.single.id, 'y'); // 8 after #1 vs 2 before #2 (cost 4)
  });

  test('photos far from any catch are unmatched, and order is by time', () {
    final m = matchPhotos(
        [const PhotoRef('late', 100 * min), const PhotoRef('p2', 5 * min), const PhotoRef('p1', 1 * min)],
        catches);
    expect(m.unmatched.single.id, 'late');
    expect(m.byCatch[1]!.map((p) => p.id), ['p1', 'p2']);
  });

  test('no catches: everything is unmatched', () {
    final m = matchPhotos([const PhotoRef('a', 0)], const []);
    expect(m.byCatch, isEmpty);
    expect(m.unmatched, hasLength(1));
  });
}
