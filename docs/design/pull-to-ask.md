# Pull down to ask AI

Owner request (2026-11-20): in the calendar surfaces, pulling down past a
point should not refresh; it should open AI chat with the input already
focused, so typing can start without tapping the bottom field. Follow-up
(2026-11-20): the full-width "Ask AI or add anything" field was replaced by
a floating ✦ Chat button beside Today (shown only off today) and +; ✦ is the
fallback and VoiceOver-equivalent entry. V3 (2026-11-21): the top bar is gone
and one docked bottom row holds the four tabs and an "Ask anything" field with
+; the field is now that entry. Restyle (2026-11-23): the tabs and Ask field now sit in two floating Liquid Glass
capsules, with a subtle selection fill in the tab strip. The field and + keep
separate tap targets (`docs/design/bottom-bar-options.html`, version B).

## Gesture map before this change

| Surface | Gesture | Owner |
| --- | --- | --- |
| Today timeline (`DayAgenda` List) | Vertical scroll; top overscroll only rubber-bands. No `refreshable` anywhere in Today/Calendar. | UIKit scroll view inside the SwiftUI `List` |
| Today week strip | Calendar → Month's folded strip: horizontal paging one week per swipe; its grab handle drags down to the month grid and up to fold back. | `MonthCalendar` (`MonthFold`, `MonthWeekStrip`) |
| Today rows | Trailing swipe for row actions; 0.35 s hold then move drags one occurrence in time; a still hold opens the long-press menu. | `RowActions`, `TimelineHoldDrag` |
| Calendar 2 Day | Horizontal paging one day per swipe inside a vertical hour scroll. | `OneDayPaging` in `CalendarView` |
| Calendar Month | Vertical paging one month per swipe; below the grid a continuous multi-day agenda `List` (`DayAgendaList` until November 2026). | `OneMonthPaging`, `MonthAgendaList` |
| Calendar Year | Continuous vertical scrolling. | `CalendarView` |
| Any page | Rightward swipe anywhere opens the sidebar with past chats (from the left edge it always wins; elsewhere a horizontal scroller that can still move right, the ribbon and the bottom bar off the first tab keep it); the same swipe on the Chat page returns to the sidebar. | `DrawerPan` in `HomeView` |
| Bottom bar | Horizontal swipe switches tabs. | `TabSwipe` |
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
- **Feedback while pulling.** The page should feel like coming home to a
  trusted head butler already waiting: warm, calm, confident, not playful
  (owner, 2026-11-20). A small warm orb (`sparkles`, orange to amber, both
  adaptive system colours) grows with the pull from 55 % to full size and
  tracks the finger with no animation lag. A soft warm glow bleeds in from
  the top edge of the surface, eased (smoothstep) so it stays faint early and
  is full at the threshold. Nothing is drawn at rest. The label reads
  "Pull to ask AI" and cross-fades to "Release, I'm here" when armed.
- **Armed.** The orb breathes (`symbolEffect(.breathe)`), and crossing into
  armed fires one `InteractionFeedback.arm`: a soft impact at 0.6
  intensity, replacing the selection detent.
- **Release.** `openAsk` runs first, unchanged, so the editor is focused and
  the keyboard rises at once. Then the shell plays a one-shot welcome:
  a warm glow sweeps once around the screen edge (stroked continuous
  rounded rect with a turning angular gradient, blurred, 0.7 s, fades out,
  never loops) and two soft beats (0.6, then 0.35 after 120 ms,
  `InteractionFeedback.welcome`). Only the pull plays it; ✦ and the sidebar
  open Chat quietly. The Chat panel does not grow out of the orb: it is a
  prebuilt page revealed with animations disabled, and morphing it would
  delay the keyboard.
- **Greeting.** A new, empty chat (pull, ✦ or the sidebar) opens with one
  quiet assistant line that already knows the day, in the voice of a head
  butler: composed, understated, British spelling, never cute (owner,
  2026-11-20). "Good morning. Next is Yuan – Alden上学 at 08:00; six things
  remain today, one overdue." / "Good evening. Nothing further today.
  Tomorrow begins at 07:30 with 刷牙." / "Good afternoon. Your day is clear."
  It is rule-built and read-only (`ButlerGreeting` in TodayCore, unit-tested:
  salutation 05:00 morning, 12:00 afternoon, 17:00 evening; next = first
  timed item still to start; "remain" = items still left today plus
  reminders due today with no time or a passed time; overdue = open reminders
  due before today; settled items are left out like on Today; at most 90
  characters, a long title is cut with "…"). Its input comes from the
  widget feed's item list (`WidgetFeed.butlerDay`), the same read as the Up
  Next card, widgets and Siri; while Apple Calendar is still warming up it
  says only the salutation. No model call, so nothing waits: the editor is
  focused and the keyboard rises first, the line is computed on the next
  main-actor turn and rises in (`spring(duration: 0.4, bounce: 0.15)`, 8 pt),
  then the Reminder / Event / Alarm buttons follow with a 30 ms stagger.
  Reduce Motion fades only. It replaces the former "What do you want to
  plan?" title, is static text for VoiceOver (`ask.greeting`), is never saved
  into the thread or sent to the agent, and is gone once a message is sent.
  The brief also mentioned suggestion chips (`AskSuggestions`); those were
  removed in P4, so the only chips are the kind buttons.
- **Return.** Chat's existing Close button (and its left-edge swipe to the
  sidebar) behave as before. The calendar page stayed mounted underneath,
  so closing lands back at the top the pull started from; the viewed day
  is untouched.
- **Reduce Motion.** No travel, growth, breathing or sweep: the orb, glow
  and label only fade, the edge glow fades in and out without turning, and
  the haptics stay. Opening uses the existing no-animation transaction.
- **VoiceOver.** The retained bottom field is the equivalent entry (label
  "Chat", hint "Starts a new chat"). The pull indicator is decoration and is
  hidden from accessibility; the gesture adds no rotor or action burden.
- **Suppressed while** chat is already open, the sidebar is open, or the
  keyboard is up for inline editing. Hold-drag timeline moves do not
  scroll, so they cannot arm the pull.

The decision logic is pure and unit-tested (`PullToAsk` in TodayCore):
tracking samples in, `.armed` / `.open` events out. The SwiftUI modifier
(`pullToAsk()` in TodayDesignSystem) only feeds scroll geometry and phase
into it, draws the orb and glow, and calls the shell's `\.pullToAsk` environment
action, which `HomeView` wires to `openAsk(nil)`.

Threshold feel (64 pt of damped overscroll is a longer finger travel) is a
starting value in the pull-to-refresh range. Simulator drags cannot prove
the real rubber-band feel or haptic strength; the owner confirms both on the
phone. The orb, glow and welcome curves are pure and unit-tested
(`PullToAsk.glow`, `orbScale`, `PullToAskWelcome`).
