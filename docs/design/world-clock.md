# World Clock (Alarms tab > World Clock): spec

Reference: the app Overlap, five screenshots supplied by the user (cards now, cards scrubbed 15 h back, graph at two times, the old city picker).
We copy the look and the interaction. We do not copy its name, logo, the green "Calendar" header link or any asset; everything is drawn in SwiftUI.
Keep our own chrome: top tab pills, the shared `PillSwitcher` (Alarms / World Clock / Stopwatch / Timer), the bottom Ask bar and the +.

## Measurements

The screenshots are 1320 x 2868 px: 3 px per pt, a 440 x 956 pt screen. Everything below is points unless noted. (The prompt said 921 px; that is the size the screenshots were *displayed* at, 0.698 of the files.)

### City card (cards screen)

| Part | Value |
|---|---|
| Side margin | 15 (card x 15 to 425) |
| Card height | 82 |
| Gap between cards | 2 (pitch 84) |
| Corner radius | 12, circular (corner profile fits a circle: 5.4 pt in at 2 pt down) |
| Text inset | 16 left and right (name starts at x = 31, time ends at x = 409) |
| Name | bold, about 19 pt (cap height 13 pt), cap top 26 below the card top |
| Offset ("+2") | about 10 pt, medium, white 85 %, digit top 48.7 below the card top |
| Star (home) | star.fill, 12 pt wide, in the offset's place (top 47.7) |
| Time | heavy, rounded digits, tabular, about 35 pt (digit height 24.3), digit top 21 below the card top, right aligned |
| Date | uppercase, about 10 pt, medium, tracked 0.5, right aligned under the time, "SATURDAY, OCTOBER 17" |
| Time zone offset text | bare sign and hours: "+2", "-8", "+5:30"; home shows a star |
| Next day | the date line changes ("SUNDAY, OCTOBER 18"); no other marker |
| First card top | 104 from the screen top (below the Overlap header); in our app: directly under the switcher |

### Pill

207 x 36 pt for "15 HOURS BEFORE NOW", 72 x 36 for "NOW"; fill `#181E25` (24,30,37), fully round, 18 pt side padding, text about 15 pt regular, uppercase, the keyword NOW bold, white.
It is always there: at rest it reads NOW, while scrubbing it reads "N HOURS BEFORE NOW" or "N HOURS AFTER NOW" (minutes: "1 HOUR 15 MIN AFTER NOW"; our assumption, no screenshot shows minutes). Tapping it goes back to now.
Position: centered, 122 pt above the screen bottom (above the reference's toolbar); ours sits above the Ask bar.

### Graph

Cards turn into plain rows: no background, content inset 25 pt more (name at x = 40, time ends at x = 400), time about 5 % smaller, row pitch 80. A sentence and waves fill the lower part of the screen.
- Sentence: 24 pt, centered, three lines, width about 290, bold names, time and "Overlap", light words: "**Overlap** for **Dallas, Boston, Aba** and 1 more, when it was **04:50** in **San Jose**". Names: three at most, then "and N more". was / is / will be follows the scrub.
- Waves: a solid front wave `#49A27D` and two translucent layers behind it (colors sampled (16,47,36) and (20,55,42), a green at 25 to 35 % fading to black at the top of each layer). Wave height is the share of cities: one city of five is 0.14 of the screen height, so the full height is 0.7 x the screen height x (cities in the window / all cities).
- The x axis starts at the shown time and runs about 5 hours: fits both graph screens (at 04:50 the count climbs 1, 2, 3, 4 as Boston, Dallas and San Jose start work; at 13:15 it falls 3, 2, 1). The edges are smoothed (about 22 minutes) so the waves roll. This is inferred from two frames, not measured.

### Colors

Page: black (`#000`) in dark mode, the system background in light mode. The cards keep their colors in both modes (they are art, not chrome).
Good hours (local 9:00 to 17:59): one flat green `#49A27D` (73,162,125), no gradient.
Everything else is a horizontal gradient whose two ends are the color of the day curve a little earlier and a little later (20 minutes either way); measured centers:

| Local time | Left | Right |
|---|---|---|
| 21:20 to 02:40 | 26,16,59 `#1A103B` | same (flat) |
| 03:50 | 26,20,63 | 26,26,69 |
| 05:50 | 28,48,92 | 29,54,99 |
| 06:50 | 31,63,107 | 33,69,114 |
| 08:00 to 09:00, 17:00 to 18:00 | 33,72,114 `#214872` (brightest blue) | same |
| 18:20 | 33,72,114 | 27,46,90 |
| 18:50 | 27,45,89 | 27,39,83 |
| 20:20 | 26,23,66 | 26,17,61 |

So there are four bands: night (indigo), dawn (blue climbing), day (green), dusk (blue sinking into night), and between the stops the colors mix linearly in the minute of the day (`WorldClock.Look`). Mornings are brighter to the right, evenings darker to the right, deep night is flat.

## The rule for green (overlap)

Screens: San Jose 18:20 blue, Dallas 20:20 indigo, Boston 21:20 indigo, Aba 02:20 indigo, **Beijing 09:20 green**; 15 hours back: Aba 11:50 **green**, San Jose 03:50, Dallas 05:50, Boston 06:50 and Beijing 18:50 not.
So a card is green exactly when its **own** local time is inside the good hours, 9:00 to 18:00, which is our existing `DayBand.work` / `isWorking` (and `WorkIntervals`). It is not "inside a window shared by all cities": Beijing is green while the others sleep.
The *shared* window (everybody working at once) is what the graph shows: the front wave is the number of cities within good hours over time, and its top is full height when all of them are.
Nothing changed in `ClockLogic` for this: `DayBand`, `isWorking`, `overlap` and `workCurve` stay as they were.

## Behaviour

- **No Overlap capsule.** The colors, the pill and the star are automatic. The graph is reached through one quiet bell-curve icon at the right end of the pill's row (`worldClock.graph`), which swaps cards and graph (like Overlap's toolbar icon); no capsule, no toggle label. Vertical swipes are left to the list.
- **Scrubbing**: a horizontal drag anywhere on the page moves every clock together: 10 pt per minute, up to 24 hours either way. Scrubbing has no haptic feedback, including at the limits. Past the ends the page follows the finger less and less (rubber band, at most 56 pt) and springs back. The minutes are kept (now 18:50, 15 hours back reads 03:50).
- **Pill**: tap goes back to now.
- **+** (the app-wide plus) adds a city; the home city is the starred first card and is the device time zone mapped to a named city (Los Angeles for America/Los_Angeles, the biggest city of the zone otherwise).
- **Cards** also keep the long press menu (Move Up / Move Down / Delete) and press-hold-drag reordering.
- **Graph mode**: cards are flat rows, waves and sentence fill the lower half, scrubbing still works and the waves move.

## Cities

`ios/One/cities.json`, built by `scripts/build_cities.py` from GeoNames `cities15000`, `countryInfo` and the Chinese entries of `alternateNamesV2` (GeoNames data are CC BY 4.0, https://www.geonames.org; credited in the picker footer and `ios/README.md`).
Contents: every national capital, every city of 1.5 million or more, the largest city of each country, larger cities of countries with many time zones, and a hand-picked list of business and tourism hubs (Beijing, Shanghai, Shenzhen, San Jose, Dallas, Boston, Aba and so on). About 950 cities, about 110 KB, no network at runtime.
Per city: GeoNames id, English name, Chinese name, country code, IANA zone, latitude, longitude, population rank, capital flag. Country names come from the system (English and Chinese), so they are not stored.

Saved list: still `today.worldClock.cities`. Old entries are time zone identifiers ("Asia/Tokyo"); they are migrated on load to the city that stands for the zone (the one named like the zone, else the biggest) and saved back as city keys ("g1850147"). A zone no listed city uses becomes a made-up city named after the zone and keeps the identifier as its key. Unknown entries are dropped, duplicates collapse, order is kept.

Search (picker): English and Chinese (simplified or traditional) names, country names in either language ("china", "中国"), time zone names; ignores case, diacritics, apostrophes and hyphens. Order: exact name, name start, word start, Chinese name, name contains, country, time zone; inside each tier capitals and bigger cities first. Each result: "Beijing, China" (Chinese interface: the Chinese names), the UTC offset and the current local time at the right.

## Known differences from the reference

See the end of the implementation report (rubber band shows as a page offset, no zoom of the graph by pinch, no share / calendar buttons, the graph x range is inferred, the font is SF Pro Rounded where Overlap uses its own).
