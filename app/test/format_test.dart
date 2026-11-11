import 'package:catch_log/ui/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dates show the year only when it isn\'t this year', () {
    final now = DateTime(2026, 11, 11, 12);
    expect(Fmt.date(DateTime(2026, 11, 9, 12), now: now), 'Mon 9 Nov');
    expect(Fmt.date(DateTime(2025, 11, 9, 12), now: now), 'Sun 9 Nov 2025');
  });
}
