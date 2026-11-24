# Battery proof of concept: two 18650 cells and USB-C charging

Status: proposal, 2026-11-24. Nothing here has been built yet.

This is the bench version of the power design in the sealed-box draft (`docs/hardware.md`, not yet committed). It skips the box, the magnetic port and the waterproof parts. The goal is just to run the logger from its own battery, charge it from a USB-C cable, and learn the real current draw and runtime.

## The short version

- **Two 18650 cells in parallel** (1S2P): one 3.7 V cell with double the capacity. Not series.
- **Charger: Adafruit bq24074 Universal USB/DC/Solar charger** (Adafruit 4755: about A$50 on Amazon AU, or A$28 from Core Electronics). It has USB-C on the board and load sharing, and it's the same charger the sealed box uses, so nothing is thrown away.
- **Protection:** a small 1S protection board between the cells and the charger. The bq24074 doesn't cut the battery off when it's flat.
- **Supply:** the charger's OUT goes through an on/off switch straight to the logger's **5V** header pin. No boost converter and no buck converter. The board's own 3.3 V regulator does the rest.
- **Runtime:** roughly 30–60 hours, against 12–20 h for the 2400 mAh LiPo in the box draft.
- **Battery level:** two 100 kΩ resistors from 5V to GPIO 0, so the firmware can read the battery voltage.

```
 USB-C cable ──► bq24074 charger (USB-C on board)
                   │ BAT                OUT (4.4 V on charge, else battery V)
                   │                     │
          1S protection board          switch
                   │                     │
     ┌─────────────┴────────┐            ├──► logger 5V   (header pin 10)
  18650 #1 ║ 18650 #2   (parallel)       │
     └──────────────────────┘          100k
                                         ├──► GPIO 0 (battery level), 100 nF to GND
                                       100k
                                         │
 all grounds ────────────────────────── GND ──► logger GND (pin 11)

 optional: charger PGOOD ──► GPIO 20 (low = cable attached)
```

## Why parallel, not series

The Waveshare board takes 5 V on USB-C or the header's 5V pin and makes 3.3 V with an ME6217 linear regulator. There's no battery input and no charger on the board.

| | Parallel (1S2P), 3.0–4.2 V | Series (2S), 6.0–8.4 V |
|---|---|---|
| Feeds the 5V pin directly | Yes | No. 8.4 V is over the ME6217's limit, so it needs a buck converter |
| Charges from plain USB-C 5 V | Yes, any single-cell charger | No. Needs a boost or USB-PD at 9 V, plus a 2S balance charger |
| Cell balancing | Not needed: the cells sit at the same voltage | Needed |
| Parts | Charger, protection, switch | Charger, BMS, balancer, buck |

Series only makes sense for loads that want more than 5 V. The logger wants 3.3 V, so parallel is simpler and wastes nothing.

## How the board gets its voltage

Same reasoning as the box draft:

- The bq24074's OUT is about 4.4 V while the cable is in, and the battery voltage (4.2 V down to about 3.0 V) when it isn't. That goes straight to the 5V pin.
- The ME6217 needs only about 0.1–0.2 V above 3.3 V at our current, so the 3.3 V rail is properly regulated down to a battery voltage of about 3.45 V. Below that it follows the battery down, and the ESP32-C6, screen and SD card keep working to about 3.0 V.
- A "5 V power bank" style module (charger plus boost to 5 V, such as IP5306 boards) would boost 3.7 V to 5 V only for the regulator to throw it away again. That wastes 25–35 % of the battery, and many of those modules switch off at the logger's low current.
- **Load sharing:** with the cable in, the bq24074 powers the logger from the cable and charges the cells separately, so charging still finishes with the logger running.

## Parts list

Everything except the cells can come from Amazon Australia. Prices are what amazon.com.au showed on 2026-11-24 (Sydney delivery) and will move, especially around sales. Most of these are multi-packs, so there are spares.

| # | Part | Amazon AU listing | ~A$ |
|---|---|---|---|
| 1 | Charger | **Adafruit bq24074 charger (Adafruit 4755)**: [B0929F5ZHW](https://www.amazon.com.au/dp/B0929F5ZHW). USB-C and a DC jack on the board, CHG and PGOOD LEDs, 2-pin JST battery socket. Ships from the US (about 1–2 weeks). | 50 |
| 2 | Cells ×2 | **Not from Amazon** (see below). Two identical **Samsung 35E** (3500 mAh, flat top, unprotected) from **Jaycar, cat. SB2630**, in store or online. | 30–40 |
| 3 | Protection | **1S 3.7 V 3 A protection board**, DW01-style, e.g. VGOL 6-pack: [B0D4YYPV8Z](https://www.amazon.com.au/dp/B0D4YYPV8Z). One board protects both parallel cells. | 15 |
| 4 | Holders | **Single-cell 18650 holders with wire leads**, e.g. DIANN 10-pack: [B0D9N7HL2Z](https://www.amazon.com.au/dp/B0D9N7HL2Z), or AIMALL 8-pack: [B0C1RD2NFL](https://www.amazon.com.au/dp/B0C1RD2NFL). Use two, wired in parallel yourself. | 9–21 |
| 5 | Battery lead | **JST-PH 2.0 2-pin pigtails**, male and female, 10 pairs: [B07NWD5NTN](https://www.amazon.com.au/dp/B07NWD5NTN). The male plug goes into the charger's battery socket. | 9 |
| 6 | Switch | **Mini panel slide switch, SS12F15**, ECSiNG 50-pack: [B0CB5KQVPW](https://www.amazon.com.au/dp/B0CB5KQVPW). It's rated 0.5 A; the logger draws under 0.3 A, so that's enough. | 16 |
| 7 | Battery level | **Resistor kit**, 600 pcs 1/4 W 1 % (has 100 kΩ): [B0G499DJZ4](https://www.amazon.com.au/dp/B0G499DJZ4). **100 nF (104) ceramic capacitors**, 100-pack: [B09532ZP1N](https://www.amazon.com.au/dp/B09532ZP1N). | 19 |
| 8 | Wire | **22 AWG silicone wire, red/black**, BNTECHGO 25 ft: [B077XBWX8V](https://www.amazon.com.au/dp/B077XBWX8V). Plus heat-shrink and a multimeter if you don't have them. | 16 |
| 9 | Meter (recommended) | **USB-C inline power meter**, 4–30 V, 0–6.5 A: [B0CKY57JL9](https://www.amazon.com.au/dp/B0CKY57JL9). For measuring the logger's real current draw. | 20 |

About A$185–200 all up from Amazon plus Jaycar, mostly because of the multi-packs and the imported charger. Without the meter and the spares it's under A$100.

These are search results, not tested parts: the cheap modules in particular vary between sellers. Read each listing before you buy, and check every module with the multimeter before it touches a cell.

**Why the cells aren't from Amazon.** Amazon AU doesn't seem to sell loose, name-brand 18650 cells: searches for Samsung, LG, Molicel, XTAR and Nitecore cells turn up chargers, battery packs with leads already soldered on, or NiMH cells mislabelled as 18650s. Fake and relabelled 18650s are common, and for cells you want a real Samsung or LG from a shop that sells them as such. Jaycar's SB2630 is a genuine Samsung 35E. Buy both at the same time so they're from the same batch.

**Charger, cheaper and faster.** The same Adafruit charger is about A$28 from Core Electronics (`ADA4755`) with delivery in a couple of days, against about A$50 and 1–2 weeks from Amazon. Worth it if the price or the wait matters.

> **Most "2 × 18650" holders are wired in series.** Amazon's "2 slot" 18650 holders, the SparkFun one Core sells (PRT-12900) and most cheap double holders join the cells end to end and give 7.4 V. Don't use one unless you've confirmed it's parallel. Two single holders wired + to + and − to − is the safe choice. Check before you connect anything: with both cells in, a parallel pack reads about 3.6–4.2 V across the leads, a series pack about 7–8.4 V.

### Cheaper option, with a catch

A **USB-C TP4056 module with protection** (for example HiLetgo 3-pack, [B07PKND8KG](https://www.amazon.com.au/dp/B07PKND8KG), about A$14) does charging and protection in one board, so it replaces both the Adafruit charger and the protection board. It works, but it has **no load sharing**: with the logger running, the logger's 100–170 mA keeps the charge current above the TP4056's 100 mA "full" threshold, so it never finishes and holds the cells at 4.2 V. If you use one, **switch the logger off while charging**, and expect to replace it with the bq24074 for the box. The bq24074 is recommended because it carries straight over.

## Wiring

| From | To | Notes |
|---|---|---|
| Cell holder 1 + and holder 2 + | Joined together → protection board **B+** | Parallel: + to +. |
| Cell holder 1 − and holder 2 − | Joined together → protection board **B−** | − to −. |
| Protection board **P+ / P−** | JST pigtail → bq24074 **battery socket** | **Check the JST polarity with a multimeter** before plugging in: the bq24074 has no reverse-battery protection. |
| bq24074 **OUT** | Switch → logger **5V** (header pin 10) | The switch breaks this wire. Off = logger off, cells still charge. |
| bq24074 **GND** | Logger **GND** (header pin 11) | |
| Logger 5V (logger side of the switch) → 100 kΩ → **GPIO 0** → 100 kΩ → GND, plus 100 nF from GPIO 0 to GND | | Halves the voltage: 4.4 V on charge reads 2.2 V, well inside the ADC's range. Draws about 20 µA, and nothing when switched off. GPIO 0 is on header U2 and is an ADC1 pin. |
| Optional: bq24074 **PGOOD** | **GPIO 20** | Open drain, low while a cable is attached. Not needed for the bench test (BOOT still switches modes), but it's what the box build uses for "on charge = Transfer". The ESP32's internal pull-up is enough. |
| GPS power | **3V3**, not 5V | So the GPS gets regulated 3.3 V, not the raw battery voltage. (The Keyestudio module takes 3.3–5 V.) |

Leave the charger's charge current at its **1.0 A** default to start. 1 A into two cells is 0.5 A each, which is gentle. You can bridge the 1.5 A jumper later for faster charging (about 0.75 A per cell, still fine for these cells).

> **Switch the logger off before plugging a USB-C cable into the board itself to flash it.** Otherwise the PC's 5 V and the charger's OUT are joined on the 5V pin. Charging through the charger's USB-C port is always fine.

## Safety

18650s hold a lot of energy and a short circuit can deliver well over 20 A. These rules matter more than anything else here:

1. **Match the cells before joining them.** Same model, same age, and charge both to within about 0.05 V of each other before they go in parallel (measure each one). Two cells at different voltages dump current into each other the moment they're connected.
2. **Check polarity on every cell, every time.** One cell in backwards in a parallel pair is a dead short between the two cells, and the protection board can't see it because it's outside the cells. Mark + on the holders.
3. **Always have protection in the circuit.** The protection board (or protected cells) cuts off a short, an overcharge, or a flat pack. The firmware stopping at 3.3 V is a second line, not a replacement.
4. **Insulate everything before the cells go in.** Heat-shrink every joint and the protection board. Don't leave bare 18650s rattling in a bag, and check the cell wrappers for nicks: the whole can is negative.
5. **Charge where you can see it**, on a non-flammable surface, at room temperature (Li-ion shouldn't charge below 0 °C or above about 45 °C). The charger's temperature input is off on this board, so it won't stop a hot charge for you. Never charge it in the sun on the boat.
6. **Retire a cell** that gets hot during normal use, has a damaged wrapper, or won't hold a charge. Recycle old cells at a B-cycle drop-off point (many Bunnings, Aldi and Officeworks stores); don't bin them.

## Current draw and runtime

The estimates from the box draft, until we measure:

| Part | Estimate |
|---|---|
| ESP32-C6 at 80 MHz, Bluetooth on | 40–80 mA |
| Screen backlight, bright | 20–40 mA (the firmware dims it to 15 % after 30 s) |
| GPS (NEO-7M) | about 40 mA |
| SD writes | short bursts, small on average |
| **Total** | **about 100–170 mA** |

Using about 85 % of the pack:

| Pack | At 100 mA | At 170 mA |
|---|---|---|
| 2 × 3000 mAh = 6000 mAh | about 51 h | about 30 h |
| 2 × 3500 mAh = 7000 mAh | about 60 h | about 35 h |

That's several fishing days per charge. Charging a flat 6000–7000 mAh pack takes about 7–8 hours at 1 A, or about 5 hours at 1.5 A.

**To check on the bench:** the bq24074 has a fast-charge safety timer, and a pack this large may hit it before it's full at 1 A. If the CHG LED goes out but the cells read well under 4.15 V, unplug and replug the cable to restart charging, or move to the 1.5 A jumper.

## Firmware hooks

Not written yet. Once the divider is fitted, this is the plan (it matches the box draft's firmware list):

- **`config.h`:**
  ```c
  #define PIN_BATT_ADC        0      // 100k/100k divider from the 5V pin
  #define BATT_DIVIDER        2.0f
  #define BATT_LOW_MV         3400   // "Low battery" banner
  #define BATT_CUTOFF_MV      3300   // flush, write a final row, stop logging
  #define BATT_SAMPLE_MS      5000
  ```
- **A small `battery` module:** every 5 s, average 16 × `analogReadMilliVolts(PIN_BATT_ADC)` (it applies the chip's ADC calibration), multiply by the divider, and smooth it. Map voltage to a percentage with a simple Li-ion table (4.20 V = 100 %, 3.85 V ≈ 60 %, 3.70 V ≈ 30 %, 3.50 V ≈ 10 %, 3.30 V = 0 %). Calibrate once against the multimeter.
- **On charge:** with the cable in, the reading is OUT (about 4.4 V), not the battery. Show "On charge" instead of a percentage when the voltage is over about 4.3 V, or use PGOOD on GPIO 20 if it's wired.
- **Screen and console:** a battery icon and percentage on the logger screen, and the voltage in `status`.
- **Low battery:** at 3.40 V show a banner; at 3.30 V (held for 30 s, so a backlight or SD spike doesn't trigger it) flush the log, write a final row, and stop logging cleanly. This settles the low-battery write left open in requirements Q5.

## Bench test plan

1. **Measure current first.** Before the battery, put a USB-C power meter between a power bank and the logger. Note the draw logging with a fix and the screen dim, with the screen bright, and in Transfer with the phone syncing.
2. **Build the pack.** Charge both cells to the same voltage, fit them, and check the pack reads 3.6–4.2 V (not 7+ V) at the protection board's output.
3. **Check JST polarity**, then plug the pack into the charger with the switch off. Plug in USB-C: CHG should light.
4. **Switch on.** The logger should boot and run. Measure the 5V pin (about 4.4 V on the cable) and 3V3.
5. **Unplug the cable.** The logger should keep running without a reset, and 5V drops to the battery voltage.
6. **Battery reading.** Once the firmware hook is in, compare `status` with the multimeter.
7. **Run-down test.** Full charge, then leave it logging on the bench until it stops. Note the hours, and check the last log file ends cleanly. This tells us whether the box needs the bigger battery.
