import 'package:intl/intl.dart';

/// Formatting in the phone's local time zone (Sydney for Jason).
abstract final class Fmt {
  static DateTime local(int ms) => DateTime.fromMillisecondsSinceEpoch(ms).toLocal();

  static String duration(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60;
    if (h == 0) return '$m min';
    return m == 0 ? '$h h' : '$h h $m m';
  }

  static String distance(double m) {
    if (m < 1000) return '${m.round()} m';
    final km = m / 1000;
    return km < 100 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
  }

  static String speed(double? kmh) => kmh == null ? '–' : '${kmh.toStringAsFixed(1)} km/h';

  static String time(DateTime t) => DateFormat('h:mm a').format(t.toLocal()).toLowerCase();

  static String timeMs(int ms) => time(local(ms));

  static String dayLong(DateTime t) => DateFormat('EEEE d MMMM').format(t.toLocal());

  static String dayShort(DateTime t) => DateFormat('EEE d MMM').format(t.toLocal());

  /// Like [dayShort], with the year when it isn't this year: "Sun 9 Nov 2025".
  static String date(DateTime t, {DateTime? now}) {
    final l = t.toLocal();
    return l.year == (now ?? DateTime.now()).year ? dayShort(l) : DateFormat('EEE d MMM y').format(l);
  }

  static String month(DateTime t) => DateFormat('MMMM y').format(t.toLocal());

  /// "Morning trip", "Evening trip"... from the local start time.
  static String tripName(int startMs) {
    final h = local(startMs).hour;
    if (h < 4) return 'Night trip';
    if (h < 11) return 'Morning trip';
    if (h < 14) return 'Midday trip';
    if (h < 17) return 'Afternoon trip';
    if (h < 21) return 'Evening trip';
    return 'Night trip';
  }

  static String ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    if (d.inDays < 7) return '${d.inDays} d ago';
    return dayShort(t);
  }

  static String bytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1048576) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1048576).toStringAsFixed(2)} MB';
  }

  /// "1 h 12 m after sunrise" style offsets.
  static String offset(Duration d) {
    final a = d.abs();
    if (a.inMinutes < 1) return 'now';
    return duration(a);
  }
}
