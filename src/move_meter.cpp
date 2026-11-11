#include "move_meter.h"

#include <math.h>

namespace movemeter {

static constexpr double kEarthRadiusM = 6371009.0;
static constexpr double kDegToRad = 0.017453292519943295;

double distanceM(double lat1, double lon1, double lat2, double lon2) {
  double delta = (lon1 - lon2) * kDegToRad;
  double sdlong = sin(delta);
  double cdlong = cos(delta);
  lat1 *= kDegToRad;
  lat2 *= kDegToRad;
  double slat1 = sin(lat1);
  double clat1 = cos(lat1);
  double slat2 = sin(lat2);
  double clat2 = cos(lat2);
  delta = (clat1 * slat2) - (slat1 * clat2 * cdlong);
  delta = delta * delta;
  delta += (clat2 * sdlong) * (clat2 * sdlong);
  delta = sqrt(delta);
  double denom = (slat1 * slat2) + (clat1 * clat2 * cdlong);
  return atan2(delta, denom) * kEarthRadiusM;
}

double thresholdM(double hdop) {
  double t = kMovePerHdopM * hdop;
  return t > kMoveMinM ? t : kMoveMinM;
}

void Meter::clear() { *this = Meter(); }

uint32_t Meter::waterS() const {
  return closedWaterS_ + (segMoved_ ? (uint32_t)(segLast_ - segFirst_) : 0);
}

double Meter::add(int64_t utc, double lat, double lon, double hdop) {
  if (!(hdop <= kMaxHdop)) return 0;  // also rejects NaN

  if (!havePoint_ || utc < lastUtc_ || utc - lastUtc_ > kSegmentGapS) {
    // New segment: close the old one, anchor here, add nothing.
    closedWaterS_ = waterS();
    segMoved_ = false;
    havePoint_ = true;
    lastUtc_ = utc;
    anchorLat_ = lat;
    anchorLon_ = lon;
    out_ = false;
    return 0;
  }
  lastUtc_ = utc;

  double d = movemeter::distanceM(anchorLat_, anchorLon_, lat, lon);
  if (d < thresholdM(hdop)) {
    out_ = false;
    return 0;
  }
  if (!out_) {
    out_ = true;
    outSince_ = utc;
  }
  if (utc - outSince_ < kConfirmS) return 0;

  // A move: count it and re-anchor here.
  distanceM_ += d;
  if (!segMoved_) {
    segMoved_ = true;
    segFirst_ = outSince_;
  }
  segLast_ = utc;
  anchorLat_ = lat;
  anchorLon_ = lon;
  out_ = false;
  return d;
}

}  // namespace movemeter
