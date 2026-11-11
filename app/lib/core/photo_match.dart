/// Matches gallery photos to catches by timestamp.
///
/// People usually photograph a fish just after landing it, so a photo is
/// matched to a catch made up to [after] before it, or (less likely, for a
/// clock that's a little off) up to [before] after it. When two catches
/// qualify, the one that came just before the photo wins: time "before the
/// catch" counts double.
library;

class PhotoRef {
  const PhotoRef(this.id, this.takenMs);
  final String id;
  final int takenMs;
}

class CatchRef {
  const CatchRef(this.id, this.timeMs);
  final int id;
  final int timeMs;
}

class PhotoMatches {
  const PhotoMatches(this.byCatch, this.unmatched);

  /// Catch id -> photos for that catch, oldest first.
  final Map<int, List<PhotoRef>> byCatch;

  /// Photos taken during the trip that aren't near any catch.
  final List<PhotoRef> unmatched;
}

PhotoMatches matchPhotos(
  List<PhotoRef> photos,
  List<CatchRef> catches, {
  Duration after = const Duration(minutes: 20),
  Duration before = const Duration(minutes: 3),
}) {
  final byCatch = <int, List<PhotoRef>>{};
  final unmatched = <PhotoRef>[];
  final sortedPhotos = [...photos]..sort((a, b) => a.takenMs.compareTo(b.takenMs));

  for (final p in sortedPhotos) {
    CatchRef? best;
    var bestCost = double.infinity;
    for (final c in catches) {
      final dt = p.takenMs - c.timeMs; // > 0: photo after the catch
      final double cost;
      if (dt >= 0 && dt <= after.inMilliseconds) {
        cost = dt.toDouble();
      } else if (dt < 0 && -dt <= before.inMilliseconds) {
        cost = -dt * 2.0;
      } else {
        continue;
      }
      if (cost < bestCost) {
        bestCost = cost;
        best = c;
      }
    }
    if (best == null) {
      unmatched.add(p);
    } else {
      (byCatch[best.id] ??= []).add(p);
    }
  }
  return PhotoMatches(byCatch, unmatched);
}
