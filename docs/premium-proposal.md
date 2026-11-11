# From logger to "wow": a premium proposal

Status: proposal, 2026-11-11. These are ideas for discussion, not a plan we've agreed to.

## The idea in one line

Today the logger records where you went and where you caught fish, and you have to dig the file out afterwards. The premium version should feel like a **fishing diary that writes itself**. You press a button when you catch something. By the time you're back at the ramp, the trip is already on your phone: mapped, with photos, conditions and insights attached.

## What a day with it would feel like

1. **Leaving the ramp.** You don't touch the device. It notices the boat is moving and starts a trip on its own. The screen, readable in full sun, shows speed, heading and the time since you left.
2. **A fish.** Matt presses his button. The device buzzes, flashes "Matt catch #3" and shows the tally. Matt takes a photo on his phone as usual.
3. **Back to the hotspot.** The bite went quiet, so you drift off and look around. The device shows an arrow and a distance: "Last catch 340 m, bearing 212°". Doing that on a chart plotter takes several taps.
4. **Home.** The phone buzzes as you pull up: "Trip synced: 4 h 12 m, 23 km, 6 fish". Nobody pressed sync.
5. **On the couch.** The app replays the trip as an animation along the route, with a pin dropping at each catch. Matt's photo is already attached to his third catch, matched by its timestamp. Every catch shows that moment's tide, moon phase, water temperature and barometric pressure trend.
6. **A month later.** The app points out a pattern: "Your best catches at this spot came on the run-out tide, within 2 h of sunrise." It also says Saturday looks good.

The "wow" doesn't come from any one feature. It comes from nothing needing to be done by hand.

## What I'd build

### 1. A real phone app (the biggest jump)

The Web Bluetooth page was the right first step, but it's Android-only and it's a utility. A premium experience needs a proper app on **iPhone and Android**.

| Area | What it does | How |
|---|---|---|
| Automatic sync | Syncs trips in the background whenever the phone is near the device. | Background Bluetooth LE: state restoration on iOS, a companion device / foreground service on Android. It reuses the transfer protocol we already have. |
| Trip view | Map with the route, catch pins, speed shading and a trip summary. | MapLibre, with offline map packs for the water. |
| Trip replay | Animated playback of the trip along the route, with catch moments. | Time-scrubbed rendering of the track. |
| Photo matching | Puts photos taken during the trip onto the nearest catch. | Photo timestamps from the phone gallery, with permission. No camera needs to be built into the device. |
| Catch details | Species, length, released or kept, notes. Optional, added later. | Quick entry form after the trip. |
| Conditions | Tide, moon phase, sunrise and sunset, wind, waves, water temperature and pressure trend for every catch. | Sun and moon calculated on the phone. Open-Meteo (free, including marine data) for weather and water. Tides need a licensed source (see the risks). |
| Insights | Patterns over many trips, such as best tide, time and spot. Later, a forecast. | Simple statistics first; machine learning only if the simple version earns it. |
| Hotspots | Saved spots synced to the device, so it can guide you back. | Two-way sync over BLE. |
| Crew | Jase and Matt share trips and a combined tally. | Optional cloud sync. Works fully offline without an account. |
| Sharing | A good-looking trip card to send to mates. Exact positions are hidden by default. | Location fuzzing. Anglers guard their spots, so sharing must be private by default. |
| Firmware updates | Updates the device from the app. | OTA over BLE. The board has 8 MB of flash, so there's room. |

**Technology:** Flutter. One codebase for iOS and Android, good Bluetooth LE support, good maps, and smooth animation. Smooth animation matters for the "wow". Data stays local first (SQLite on the phone), and cloud sync is an opt-in extra.

### 2. Device v2: hardware that looks and feels premium

| Today | Premium | Why |
|---|---|---|
| Bare board, power bank | **Sealed, floating case** (IP67/68) in a bright colour, with a lanyard and a mount (RAM ball or magnetic). | It survives the boat, and it floats if it goes overboard. |
| USB-C cable for power | **Internal battery with wireless (Qi) charging**. No ports at all. | Truly sealed; just drop it on a charger. |
| 1.47" IPS LCD | **Screen readable in sunlight**: a Sharp Memory LCD or e-paper. | The current screen washes out in sun. Both options use very little power, which is good for battery life. |
| Small tactile buttons | **Big, glove-friendly sealed buttons**, one colour per angler. Optionally configurable for 1–4 anglers. | Usable with wet hands, without looking. |
| No feedback | **Haptic buzz plus a screen animation** on each catch. | You know it registered without looking. |
| Basic GPS module | **Multi-constellation GNSS** (for example u-blox M10) with a good antenna. | Faster fix, better accuracy, lower power. |
| Mode switch | **None**. Trips start and stop automatically (motion sensor plus GPS), and syncing just happens. | Nothing to forget. Fewer holes in the case. |
| — | **Barometer** | Pressure trend is a classic fishing factor and it's cheap to add. |
| — | **Back-to-hotspot arrow** on the device screen. | A killer feature that fits the hardware well. |

**Chip choice:** the ESP32-C6 is fine for development and a first version. For a product that runs for days on a small battery, a Nordic nRF52840 or nRF54 is the better Bluetooth LE chip: much lower power, with excellent background BLE behaviour on iPhones. I'd prototype v2 on the C6, then decide based on measured battery life.

### 3. Polish that gets noticed

- **Pairing:** the device shows a QR code. Scan it in the app and it's paired, with no Bluetooth menus.
- **Onboarding:** 30 seconds from opening the box to the first trip.
- **On-device UI:** large digits, a night mode in red to protect night vision, and a small celebration animation on every catch.
- **Brand:** a proper name, an icon, one consistent design across the device, the app and a simple website.
- **Reliability:** nothing is ever lost. Every catch is written to the card immediately, and the app shows what has and hasn't synced.

## What I wouldn't do

- **Compete with chart plotters.** There'd be no full navigation, autopilot or sonar. Stay the best catch diary.
- **Build a social network.** Sharing is private and between mates, not a public feed of everyone's spots.
- **Make an account compulsory.** Everything works offline, and the cloud is an optional extra.

## Suggested phases

| Phase | Scope | Size | Result |
|---|---|---|---|
| 0. Polish today's device | Hold both buttons to enter Transfer, catch buzz/animation, back-to-last-catch arrow, OTA updates. | Small | The current hardware feels much better, and it's ready for a sealed case. |
| 1. App MVP | Flutter app for iOS and Android with automatic sync, trip map and replay, photo matching, sun/moon/weather/water conditions. | Medium to large | The "fishing diary that writes itself" moment. This is the most important phase. |
| 2. Device v2 | Sealed floating case, wireless charging, sunlight-readable screen, GNSS module, barometer, haptics, automatic trips. | Large, needs hardware design and prototypes | It looks and feels like a product. |
| 3. Insights and crew | Patterns, a forecast, hotspot sync, crew sharing, private trip cards. | Medium | The reason to keep using it season after season. |

Phase 1 delivers most of the "wow" on the current hardware, so I'd do it before investing in new hardware.

## Decisions needed

1. **Personal showpiece, or something to sell?** This is the biggest fork:
   - **Selling** brings radio certification (RCM in Australia, FCC/CE elsewhere; pre-certified modules make it much cheaper), app store accounts, support, warranty and liability, and a pricing model (a device price, maybe plus a subscription for insights and cloud).
   - **Keeping it personal** means none of that.
2. **Is iPhone needed?** Mostly yes for "people", and that rules out the web page as the main app.
3. **Tide data.** Free sources are limited. In Australia the official predictions come from the Bureau of Meteorology and the port authorities, under licence terms. Commercial APIs (such as WorldTides or Stormglass) cost money per request. For personal use there are cheap options.
4. **Charts and depth.** Navionics and C-MAP charts need commercial licences. The free route is OpenSeaMap plus public bathymetry (state government survey data where it exists, GEBCO elsewhere). That's good enough for a diary, but not for navigation.
5. **Budget for hardware v2.** A custom sealed case and display mean prototype runs: 3D printing first, then possibly moulded parts.

## Risks

- **Background Bluetooth on iPhone** is the hardest technical piece. It works, but it has strict rules about what an app can do in the background. Prove it early in phase 1.
- **The screen in sunlight** is easy to underestimate. Test candidate displays outdoors before choosing.
- **Battery life** with GPS running all day needs measuring, not guessing. GNSS power-saving modes and a low-power display both help a lot.
- **Scope creep.** The diary idea is strong because it's focused. Each phase should stand on its own.
