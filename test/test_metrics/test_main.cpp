// Native unit tests for the movement rule (src/move_meter.cpp, docs/metrics.md).
//   pio test -e native
// Needs a host C++ compiler (gcc or clang) on the PATH. Run from the project
// folder, so the tests can find test-data/.

#define _USE_MATH_DEFINES  // M_PI on Windows compilers
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unity.h>

#include "move_meter.h"

using movemeter::Meter;

// ---- Helpers ----

static const double kLat0 = -37.0, kLon0 = 158.0;
static const double kMetresPerDegLat = 6371009.0 * M_PI / 180.0;  // along a meridian on this sphere
static const int64_t kT0 = 1794168000;  // 2026-11-08T20:00:00Z

// A position 'north' and 'east' metres from (kLat0, kLon0).
static void at(double north, double east, double& lat, double& lon) {
  lat = kLat0 + north / kMetresPerDegLat;
  lon = kLon0 + east / (kMetresPerDegLat * cos(kLat0 * M_PI / 180.0));
}

static double addAt(Meter& m, int64_t t, double north, double east, double hdop = 1.0) {
  double lat, lon;
  at(north, east, lat, lon);
  return m.add(kT0 + t, lat, lon, hdop);
}

// "2026-11-11T01:30:17Z" -> UTC seconds, or 0 if it doesn't parse.
static int64_t parseIso(const char* s) {
  int y, mo, d, h, mi, se;
  if (sscanf(s, "%4d-%2d-%2dT%2d:%2d:%2dZ", &y, &mo, &d, &h, &mi, &se) != 6) return 0;
  // Days from 1970-01-01 (Howard Hinnant's days_from_civil).
  y -= mo <= 2;
  int64_t era = (y >= 0 ? y : y - 399) / 400;
  int64_t yoe = y - era * 400;
  int64_t doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  int64_t days = era * 146097 + doe - 719468;
  return days * 86400 + h * 3600 + mi * 60 + se;
}

struct FileResult {
  bool opened = false;
  int points = 0;
  double distanceM = 0;
  uint32_t waterS = 0;
};

// Feeds a log CSV's track rows through a meter, as the trip meter's rebuild does.
static FileResult runFile(const char* name) {
  FileResult r;
  const char* dirs[] = {"test-data/", "../test-data/", "../../test-data/", "../../../test-data/"};
  FILE* f = nullptr;
  for (const char* dir : dirs) {
    char path[256];
    snprintf(path, sizeof(path), "%s%s", dir, name);
    if ((f = fopen(path, "r")) != nullptr) break;
  }
  if (!f) return r;
  r.opened = true;
  Meter m;
  char line[512];
  while (fgets(line, sizeof(line), f)) {
    char* fields[14] = {nullptr};
    int n = 0;
    char* p = line;
    fields[n++] = p;
    while (*p && n < 14) {
      if (*p == ',') {
        *p = 0;
        fields[n++] = p + 1;
      } else if (*p == '\n' || *p == '\r') {
        *p = 0;
        break;
      }
      p++;
    }
    if (n < 14 || strcmp(fields[0], "track") != 0) continue;  // header, catches
    if (!*fields[1] || !*fields[2] || !*fields[3] || !*fields[7]) continue;
    int64_t t = parseIso(fields[1]);
    if (t == 0) continue;
    m.add(t, atof(fields[2]), atof(fields[3]), atof(fields[7]));
    r.points++;
  }
  fclose(f);
  r.distanceM = m.distanceM();
  r.waterS = m.waterS();
  return r;
}

// ---- Rule details ----

void test_distance_formula() {
  // One degree along a meridian on a sphere of radius 6371009 m.
  TEST_ASSERT_DOUBLE_WITHIN(0.01, 111195.08, movemeter::distanceM(-37, 158, -36, 158));
  TEST_ASSERT_DOUBLE_WITHIN(1e-9, 0.0, movemeter::distanceM(-37, 158, -37, 158));
}

void test_threshold_grows_with_hdop() {
  TEST_ASSERT_DOUBLE_WITHIN(1e-9, 25.0, movemeter::thresholdM(0.5));
  TEST_ASSERT_DOUBLE_WITHIN(1e-9, 30.0, movemeter::thresholdM(1.0));
  TEST_ASSERT_DOUBLE_WITHIN(1e-9, 105.0, movemeter::thresholdM(3.5));
}

void test_jitter_inside_threshold_adds_nothing() {
  Meter m;
  for (int i = 0; i < 600; i++) addAt(m, i * 5, 20.0 * sin(i * 0.7), 20.0 * cos(i * 1.3));
  TEST_ASSERT_EQUAL_DOUBLE(0.0, m.distanceM());
  TEST_ASSERT_EQUAL_UINT32(0, m.waterS());
}

void test_move_needs_30_s_outside() {
  Meter m;
  addAt(m, 0, 0, 0);
  TEST_ASSERT_EQUAL_DOUBLE(0.0, addAt(m, 10, 50, 0));   // out at t=10
  TEST_ASSERT_EQUAL_DOUBLE(0.0, addAt(m, 35, 52, 0));   // 25 s out: not yet
  TEST_ASSERT_DOUBLE_WITHIN(0.01, 51.0, addAt(m, 40, 51, 0));  // 30 s out: a move
  TEST_ASSERT_EQUAL_UINT32(30, m.waterS());             // from t=10 to t=40
}

void test_coming_back_inside_cancels() {
  Meter m;
  addAt(m, 0, 0, 0);
  addAt(m, 10, 60, 0);
  addAt(m, 20, 10, 0);  // back inside: the excursion is forgotten
  TEST_ASSERT_EQUAL_DOUBLE(0.0, addAt(m, 40, 60, 0));  // out again from t=40
  TEST_ASSERT_EQUAL_DOUBLE(0.0, m.distanceM());
}

void test_hdop_sets_the_threshold() {
  Meter a, b;
  addAt(a, 0, 0, 0, 1.0);
  addAt(a, 10, 40, 0, 1.0);
  addAt(a, 40, 40, 0, 1.0);  // 40 m >= 30 m: a move
  TEST_ASSERT_DOUBLE_WITHIN(0.01, 40.0, a.distanceM());
  addAt(b, 0, 0, 0, 2.0);
  addAt(b, 10, 40, 0, 2.0);
  addAt(b, 40, 40, 0, 2.0);  // 40 m < 60 m: not a move
  TEST_ASSERT_EQUAL_DOUBLE(0.0, b.distanceM());
}

void test_points_over_hdop_5_are_ignored() {
  Meter m;
  addAt(m, 0, 0, 0);
  addAt(m, 10, 500, 0, 5.1);
  addAt(m, 60, 500, 0, 9.9);
  TEST_ASSERT_EQUAL_DOUBLE(0.0, m.distanceM());
  // ...and don't count as points either: this one is 20 min after the last counted point.
  addAt(m, 1200, 500, 0, 1.0);
  addAt(m, 1260, 500, 0, 1.0);
  TEST_ASSERT_EQUAL_DOUBLE(0.0, m.distanceM());
}

void test_gap_starts_a_new_segment() {
  Meter m;
  addAt(m, 0, 0, 0);
  addAt(m, 60, 100, 0);
  addAt(m, 120, 200, 0);  // moves at t=120 (out since t=60)
  TEST_ASSERT_DOUBLE_WITHIN(0.01, 200.0, m.distanceM());
  TEST_ASSERT_EQUAL_UINT32(60, m.waterS());
  // 16 minutes later, 1 km away: re-anchors without adding the jump.
  TEST_ASSERT_EQUAL_DOUBLE(0.0, addAt(m, 120 + 960, 1200, 0));
  addAt(m, 1140, 1300, 0);
  addAt(m, 1200, 1400, 0);  // a move of 200 m, out since t=1140
  TEST_ASSERT_DOUBLE_WITHIN(0.01, 400.0, m.distanceM());
  TEST_ASSERT_EQUAL_UINT32(60 + 60, m.waterS());
}

void test_going_back_in_time_starts_a_new_segment() {
  Meter m;
  addAt(m, 600, 0, 0);
  TEST_ASSERT_EQUAL_DOUBLE(0.0, addAt(m, 0, 500, 0));
  TEST_ASSERT_EQUAL_DOUBLE(0.0, m.distanceM());
}

void test_slow_drift_counts() {
  // 1 km/h for an hour, a point a minute.
  Meter m;
  for (int i = 0; i <= 60; i++) addAt(m, i * 60, i * 1000.0 / 60.0, 0);
  TEST_ASSERT_DOUBLE_WITHIN(50.0, 1000.0, m.distanceM());
  TEST_ASSERT_TRUE(m.waterS() >= 3300);
}

void test_time_at_anchor_between_moves_counts() {
  Meter m;
  for (int i = 0; i <= 60; i++) addAt(m, i * 5, i * 7.0, 0);  // 5 min at 5 km/h
  double x = 60 * 7.0;
  for (int i = 1; i <= 60; i++) addAt(m, 300 + i * 60, x, 0);  // an hour at anchor
  for (int i = 1; i <= 60; i++) addAt(m, 3900 + i * 5, x + i * 7.0, 0);  // 5 min more
  TEST_ASSERT_DOUBLE_WITHIN(60.0, 840.0, m.distanceM());
  TEST_ASSERT_TRUE(m.waterS() >= 4000);  // the hour at anchor is in
  TEST_ASSERT_TRUE(m.waterS() <= 4200);
}

void test_clear_starts_again() {
  Meter m;
  addAt(m, 0, 0, 0);
  addAt(m, 60, 100, 0);
  addAt(m, 120, 200, 0);
  m.clear();
  TEST_ASSERT_EQUAL_DOUBLE(0.0, m.distanceM());
  TEST_ASSERT_EQUAL_UINT32(0, m.waterS());
}

// ---- The fixtures in test-data/ (see test-data/README.md) ----

void test_desk_log_is_stationary() {
  FileResult r = runFile("stationary-desk.csv");
  TEST_ASSERT_TRUE_MESSAGE(r.opened, "test-data/stationary-desk.csv not found; run from the project folder");
  TEST_ASSERT_EQUAL_INT(313, r.points);
  TEST_ASSERT_TRUE(r.distanceM < 50.0);  // the requirement
  TEST_ASSERT_TRUE(r.waterS <= 60);      // "about 0"
  TEST_ASSERT_EQUAL_DOUBLE(0.0, r.distanceM);  // what the rule gives today (tools/metrics.py)
  TEST_ASSERT_EQUAL_UINT32(0, r.waterS);
}

void test_moving_track_is_within_5_percent() {
  FileResult r = runFile("moving-noisy.csv");
  TEST_ASSERT_TRUE_MESSAGE(r.opened, "test-data/moving-noisy.csv not found; run from the project folder");
  const double trueM = 6831.0;    // from tools/make_fixtures.py
  TEST_ASSERT_DOUBLE_WITHIN(trueM * 0.05, trueM, r.distanceM);
  // Time on the water: 3 h from leaving to the end of motoring back (the hour
  // at anchor included), plus 10 min after the gap. Moves start and end a
  // little late, so allow 5 minutes.
  TEST_ASSERT_UINT32_WITHIN(300, 11400, r.waterS);
  // The same numbers as the reference implementation, tools/metrics.py.
  TEST_ASSERT_DOUBLE_WITHIN(0.5, 6666.6, r.distanceM);
  TEST_ASSERT_EQUAL_UINT32(11205, r.waterS);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_distance_formula);
  RUN_TEST(test_threshold_grows_with_hdop);
  RUN_TEST(test_jitter_inside_threshold_adds_nothing);
  RUN_TEST(test_move_needs_30_s_outside);
  RUN_TEST(test_coming_back_inside_cancels);
  RUN_TEST(test_hdop_sets_the_threshold);
  RUN_TEST(test_points_over_hdop_5_are_ignored);
  RUN_TEST(test_gap_starts_a_new_segment);
  RUN_TEST(test_going_back_in_time_starts_a_new_segment);
  RUN_TEST(test_slow_drift_counts);
  RUN_TEST(test_time_at_anchor_between_moves_counts);
  RUN_TEST(test_clear_starts_again);
  RUN_TEST(test_desk_log_is_stationary);
  RUN_TEST(test_moving_track_is_within_5_percent);
  return UNITY_END();
}
