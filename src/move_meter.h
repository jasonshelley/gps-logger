#pragma once
// Movement, distance and time on the water from a stream of track points.
//
// This is the rule in docs/metrics.md. The trip meter, today's distance and
// the log rule all use it, and so does the phone app, which must give the same
// numbers for the same rows. tools/metrics.py is the reference implementation.
// Plain C++ with no Arduino or SD code, so the native unit tests can run it
// (pio test -e native).
//
// In short: only points with HDOP <= 5 count. The meter keeps an anchor, the
// last counted position. A point is "out" when it's at least
// max(25 m, 30 m x its HDOP) from the anchor. When the position has stayed out
// for at least 30 s, that's a move: add the distance from the anchor to the
// point and move the anchor there. A gap of more than 15 min between counted
// points starts a new segment, which re-anchors without adding distance. Time
// on the water is, per segment, from when its first move started to its last
// move, so time at anchor between moves counts.

#include <stdint.h>

namespace movemeter {

constexpr double kMaxHdop = 5.0;        // points with a higher HDOP are ignored
constexpr double kMoveMinM = 25.0;      // the movement threshold is at least this ...
constexpr double kMovePerHdopM = 30.0;  // ... and grows with HDOP: max(25, 30 x HDOP)
constexpr int64_t kConfirmS = 30;       // a move counts once the position has stayed out this long
constexpr int64_t kSegmentGapS = 900;   // a longer gap between counted points starts a new segment

// Great-circle distance in metres. The same formula and Earth radius
// (6371009 m) as TinyGPSPlus::distanceBetween.
double distanceM(double lat1, double lon1, double lat2, double lon2);

// The movement threshold for a point with this HDOP.
double thresholdM(double hdop);

class Meter {
 public:
  // Starts again from nothing.
  void clear();

  // Feeds one track point (UTC seconds). Feed points in time order. A point
  // that goes back in time starts a new segment. Returns the metres added by
  // this point: more than 0 only when it completes a move.
  double add(int64_t utc, double lat, double lon, double hdop);

  double distanceM() const { return distanceM_; }
  uint32_t waterS() const;

 private:
  double distanceM_ = 0;
  uint32_t closedWaterS_ = 0;  // finished segments
  bool havePoint_ = false;
  int64_t lastUtc_ = 0;        // the last counted point
  double anchorLat_ = 0, anchorLon_ = 0;
  bool out_ = false;           // the position has left the anchor's circle ...
  int64_t outSince_ = 0;       // ... since this time
  bool segMoved_ = false;      // this segment has had a move
  int64_t segFirst_ = 0;       // when its first move started
  int64_t segLast_ = 0;        // when its last move was counted
};

}  // namespace movemeter
