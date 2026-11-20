# Pull down to ask AI

Owner request (2026-11-20): in the calendar surfaces, pulling down past a
point should not refresh; it should open AI chat with the input already
focused, so typing can start without tapping the bottom field. Follow-up
(2026-11-20): the full-width "Ask AI or add anything" field was replaced by
a floating ✦ Chat button beside Today (shown only off today) and +; ✦ is the
fallback and VoiceOver-equivalent entry.

## Gesture map before this change

| Surface | Gesture | Owner |
| --- | --- | --- |
| Today timeline (`DayAgenda` List) | Vertical scroll; top overscroll only rubber-bands. No `refreshable` anywhere in Today/Calendar. | UIKit scroll view inside the SwiftUI `List` |
| Today week strip | Horizontal drag, axis locked at 8 pt, follows the finger; release past about two day cells commits one adjacent week, vertical drags are ignored. Detent/settle haptics via `InteractionFeedback`. | `WeekStrip` + `WeekStripSwipe` |
| Today rows | Trailing swipe for row actions; 0.35 s hold then move drags one occurrence in time; a still hold opens the long-press menu. | `RowActions`, `TimelineHoldDrag` |
| Calendar 2 Day | Horizontal paging one day per swipe inside a vertical hour scroll. | `OneDayPaging` in `CalendarView` |
| Calendar Month | Vertical paging one month per swipe; below the grid a continuous multi-day agenda `List` (`DayAgendaList` until November 2026). | `OneMonthPaging`, `MonthAgendaList` |
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

- **Where.** The Today timeline list and Calendar's 2 Day hour scroll. The
  Month pager, the Month agenda and Year scroll keep their vertical
  paging/scrolling: pulling there moves months, earlier days or years, and
  hijacking it would break browsing. Since November 2026 the Month agenda
  is a continuous multi-day list (`MonthAgendaList`) whose top edge loads
  earlier days, so it no longer offers the pull; ✦ stays its equivalent.
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
