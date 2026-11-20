# Pull down to ask AI

Owner request (2026-11-20): in the calendar surfaces, pulling down past a
point should not refresh; it should open AI chat with the input already
focused, so typing can start without tapping the bottom field. The bottom
"Ask AI or add anything" field stays for now as the fallback and the
VoiceOver-equivalent entry; retiring it is a later step, not this one.

## Gesture map before this change

| Surface | Gesture | Owner |
| --- | --- | --- |
| Today timeline (`DayAgenda` List) | Vertical scroll; top overscroll only rubber-bands. No `refreshable` anywhere in Today/Calendar. | UIKit scroll view inside the SwiftUI `List` |
| Today week strip | Horizontal drag, axis locked at 8 pt, follows the finger; release past about two day cells commits one adjacent week, vertical drags are ignored. Detent/settle haptics via `InteractionFeedback`. | `WeekStrip` + `WeekStripSwipe` |
| Today rows | Trailing swipe for row actions; 0.35 s hold then move drags one occurrence in time; a still hold opens the long-press menu. | `RowActions`, `TimelineHoldDrag` |
| Calendar 2 Day | Horizontal paging one day per swipe inside a vertical hour scroll. | `OneDayPaging` in `CalendarView` |
| Calendar Month | Vertical paging one month per swipe; the selected day's agenda is a separate `List` below the grid. | `OneMonthPaging`, `DayAgendaList` |
| Calendar Year | Continuous vertical scrolling. | `CalendarView` |
| Any page | Rightward swipe from the left edge (24 pt strip) opens the sidebar with past chats; the same swipe on the Chat page returns to the sidebar. | `DrawerDrag`, Chat overlay in `HomeView` |
| Top/bottom bars | Horizontal swipe switches tabs. | `TabSwipe` |
| Bottom field | Tap reveals the prebuilt full-screen Chat; an empty new chat focuses its editor on the next frame and the keyboard is warmed at launch. Close (top right) returns to the page underneath, which stayed mounted with its scroll position. | `openAsk` / `closeAsk` in `HomeView`, `AskView` |

Direction check: the owner's words also mention swiping sideways. In the
current build every horizontal direction is already taken (week paging,
2 Day paging, row actions, the sidebar edge swipe and tab swipes), so a
horizontal "open chat" swipe would fight paging. The free slot is the one
the request points at first: pulling down past the top of a calendar list,
which today does nothing but rubber-band because no pull-to-refresh exists
there. That is the trigger this change uses.

## The chosen interaction

- **Where.** The Today timeline list, Calendar's 2 Day hour scroll, and the
  Month view's selected-day agenda list. The Month pager and Year scroll
  keep their vertical paging/scrolling: pulling there moves months/years,
  and hijacking it would break browsing. Their day surfaces above still
  offer the pull.
- **Trigger.** Scroll to the top, keep pulling down. Overscroll distance is
  read from the scroll geometry, so ordinary scrolling, paging and row
  gestures never produce it. At 64 pt of overscroll the pull is armed
  (8 pt hysteresis: it disarms again below 56 pt). Releasing while armed
  opens a new chat through the same `openAsk` path as the bottom field, so
  the editor is focused and the keyboard rises with no extra tap.
  Releasing below the threshold, or sliding back below the disarm band
  before release, cancels: the list rubber-bands back and nothing opens.
  Overscroll that only appears while decelerating (a fast flick bouncing
  at the top) never arms, because arming requires finger tracking.
- **Feedback while pulling.** A quiet pill follows the pull at the top:
  "Pull to ask AI" brightens with progress and switches to
  "Release to ask AI" when armed. Crossing into armed fires one
  `InteractionFeedback.detent` haptic, the same selection tick the week
  strip uses for crossing a tooth. No other haptics.
- **Return.** Chat's existing Close button (and its left-edge swipe to the
  sidebar) behave as before. The calendar page stayed mounted underneath,
  so closing lands back at the top the pull started from; the viewed day
  is untouched.
- **Reduce Motion.** The pill only fades (no travel), and opening uses the
  existing no-animation transaction, as a bottom-field tap already does.
- **VoiceOver.** The retained bottom field is the equivalent entry (label
  "Chat", hint "Starts a new chat"). The pull pill is decoration and is
  hidden from accessibility; the gesture adds no rotor or action burden.
- **Suppressed while** chat is already open, the sidebar is open, or the
  keyboard is up for inline editing. Hold-drag timeline moves do not
  scroll, so they cannot arm the pull.

The decision logic is pure and unit-tested (`PullToAsk` in TodayCore):
tracking samples in, `.armed` / `.open` events out. The SwiftUI modifier
(`pullToAsk()` in TodayDesignSystem) only feeds scroll geometry and phase
into it, draws the pill, and calls the shell's `\.pullToAsk` environment
action, which `HomeView` wires to `openAsk(nil)`.

Threshold feel (64 pt of damped overscroll is a longer finger travel) is a
starting value in the pull-to-refresh range. Simulator drags cannot prove
the real rubber-band feel; the owner confirms it on the phone.

## Composer retirement path (proposal, awaiting owner approval)

The bottom bar is one `HStack` in `HomeView.bottomButtons`: the
"Ask AI or add anything" field filling the width, then the Today capsule
and the + circle on the right, at the same height. The bar around them
also carries the Undo toast and is a `TabSwipe` surface. The two neighbors
have jobs unrelated to AI entry: Today always returns to the actual
current day (and resets Calendar's browsed day to match), and + opens the
structured create menu (New alarm / New reminder / New event, plus
Add city on World Clock). Nothing below moves or resizes them; only the
field's stages are up for approval.

- **Stage 0 — now (shipped in #389).** The whole bar is unchanged. The
  field is the fallback for every case the gesture does not cover and the
  VoiceOver entry (label "Chat"). Gate for any next stage: the owner
  confirms the pull feel on the phone and uses it as the default entry.
- **Stage 1 — shrink (proposed, reversible).** The text field collapses to
  a round sparkles "Ask AI" button, the same height and 44 pt hit target
  as +, keeping the "Chat" accessibility label and the existing
  automation identifier. Today and + stay in their exact places, order
  and sizes; the freed width is empty bar, and the bar keeps its Undo
  toast and full-width tab swipe. This tests whether the words
  "Ask AI or add anything" are still doing discoverability work while a
  one-tap, VoiceOver-visible entry remains.
- **Stage 2 — retire (proposed end state).** The Ask button leaves the
  bar. Today and + remain a right-side cluster, unchanged; the bar itself
  stays for the Undo toast and tab swipe, with quiet empty space on the
  left (slimming the bar is a separate visual decision). Non-gesture
  chat entries that already exist become the documented equivalents: the
  sidebar's New chat (menu button or left-edge swipe) and Ask AI in item
  long-press menus. If the owner still wants a same-thumb entry at that
  point, the + menu can gain an "Ask AI" row — decided then, not now.
  Stage 2 also retires the "Ask AI or add anything" automation
  identifier, so its tests migrate to the surviving entries in the same
  change.

Open questions for the owner before Stage 1: whether a one-time hint
should ever teach the pull (today the pill only appears while pulling),
and whether the empty bar at Stage 2 should visually slim or keep its
current height as swipe surface. No stage beyond 0 is implemented.
