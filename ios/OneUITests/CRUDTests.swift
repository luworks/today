import XCTest

/// Create, read, update and delete on everything the app manages, the way a person would do it, starting from the
/// test dataset (tests/fixtures/today-dataset.json): reminders and lists, local calendar events, alarms, chats, and Search.
/// Every test launches a fresh in-memory store, so they are independent. Apple Calendar / Reminders sync is off.
@MainActor
final class CRUDTests: XCTestCase {
  var app: XCUIApplication!
  private let cal = Calendar.current

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = TestData.launchArguments
      app.launch()
      XCTAssertTrue(
        app.buttons["Ask AI or add anything"].waitForExistence(timeout: 10), "the app is up")
    }
  }

  // MARK: - Helpers

  private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

  private func any(_ format: String, _ args: Any...) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: format, argumentArray: args))
      .firstMatch
  }

  private func openTab(_ name: String) {
    let pill = app.buttons[name].firstMatch
    XCTAssertTrue(pill.waitForExistence(timeout: 5), "tab \(name)")
    pill.tap()
  }

  /// Waits until `predicate` holds for `element` (re-evaluated, unlike a one-off read).
  @discardableResult
  private func wait(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 5) -> Bool {
    let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
    return XCTWaiter().wait(for: [e], timeout: timeout) == .completed
  }

  /// Scrolls the page until the element exists and is hittable clear of the bottom bar.
  private func reveal(_ el: XCUIElement, up: Bool = true) {
    for _ in 0..<6 where !el.exists || !el.isHittable || el.frame.maxY > app.frame.height - 140 {
      if up { app.swipeUp() } else { app.swipeDown() }
    }
    XCTAssertTrue(el.waitForExistence(timeout: 5), "missing \(el)")
  }

  /// Puts the cursor at the end of the field and erases what is there, then types `text`.
  private func replaceText(in field: XCUIElement, with text: String) {
    XCTAssertTrue(field.waitForExistence(timeout: 5), "field \(field)")
    let old = (field.value as? String) ?? ""
    field.tap()
    // A tap right after a wheel or a sheet settles can be taken by the scroll view; a person would tap again.
    if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { field.tap() }
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard is up for \(field)")
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()  // cursor to the end
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
    field.typeText(text)
  }

  /// Swipe from right to left on a row and tap Delete. A full swipe can delete straight away; otherwise the button shows.
  private func swipeDelete(_ row: XCUIElement) {
    row.swipeLeft()
    let delete = app.buttons["Delete"]
    if delete.waitForExistence(timeout: 2) { delete.tap() }
  }

  private func tapUndo() {
    let undo = app.buttons["Undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 4), "there is an Undo")
    undo.tap()
  }

  /// The navigation bar's back button (the pushed list's "Lists").
  private func goBack() {
    let back = app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
  }

  /// Opens the sidebar with the menu button (the left-edge swipe also works; the button is steadier under automation).
  private func openSidebar() {
    app.buttons["Open menu"].tap()
    XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 6), "the sidebar is open")
    XCTAssertTrue(wait(app.buttons["New chat"], "isHittable == true"), "and settled")
  }

  /// Tap the date part of a compact DatePicker and pick `day` in the calendar that pops up.
  private func pickDate(_ picker: XCUIElement, day: Date) {
    XCTAssertTrue(picker.waitForExistence(timeout: 5), "date picker")
    picker.buttons.element(boundBy: 0).tap()
    let label = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    let cell = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    XCTAssertTrue(
      cell.waitForExistence(timeout: 5),
      "day \(label) in the calendar popover: \(app.debugDescription)")
    cell.tap()
    dismissPopover()
  }

  /// Closes a popover by tapping `outside` (default: the sheet's navigation bar title).
  private func dismissPopover(tapping outside: XCUIElement? = nil) {
    // Tap outside, on a title: the middle of the dismiss region can land on a control under it.
    let region = element("PopoverDismissRegion")
    if region.waitForExistence(timeout: 2) {
      (outside ?? app.navigationBars.firstMatch).coordinate(
        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
      ).tap()
    }
    XCTAssertTrue(region.waitForNonExistence(timeout: 3), "the popover closes")
  }

  // MARK: - Reminders

  func testReminderRepeatWeekdaysCanBeChosenAndPersisted() {
    openTab("Reminders")
    let home = element("list.Home")
    reveal(home)
    home.tap()
    let reminder = app.staticTexts["Buy milk"].firstMatch
    reveal(reminder)
    reminder.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["task.title"].firstMatch.waitForExistence(timeout: 5))

    app.buttons["task.repeat"].tap()
    let choose = app.buttons["task.repeat.chooseDays"]
    XCTAssertTrue(choose.waitForExistence(timeout: 5))
    choose.tap()
    let monday = app.switches["task.repeat.weekday.2"]
    let wednesday = app.switches["task.repeat.weekday.4"]
    XCTAssertTrue(monday.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["task.repeat.days.done"].isEnabled)
    monday.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    XCTAssertEqual(monday.value as? String, "1")
    wednesday.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    XCTAssertEqual(wednesday.value as? String, "1")
    app.buttons["task.repeat.days.done"].tap()
    XCTAssertTrue(
      wait(app.buttons["task.repeat"], "label CONTAINS 'Every Mon, Wed'"),
      app.buttons["task.repeat"].debugDescription)
    app.buttons["task.save"].tap()

    XCTAssertTrue(reminder.waitForExistence(timeout: 5))
    reminder.tap()
    XCTAssertTrue(wait(app.buttons["task.repeat"], "label CONTAINS 'Every Mon, Wed'"))
    app.buttons["task.repeat"].tap()
    choose.tap()
    XCTAssertTrue(monday.waitForExistence(timeout: 5))
    XCTAssertEqual(monday.value as? String, "1")
    XCTAssertEqual(wednesday.value as? String, "1")
    monday.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    XCTAssertEqual(monday.value as? String, "0")
    app.navigationBars["Repeat on"].buttons["Cancel"].tap()
    XCTAssertTrue(wait(app.buttons["task.repeat"], "label CONTAINS 'Every Mon, Wed'"))
    app.buttons["Cancel"].tap()
  }

  /// New Reminder in a list, edit title and due date in its editor, flag, complete (shows in Completed), delete and Undo.
  func testReminderCreateEditFlagCompleteDeleteUndo() {
    openTab("Reminders")
    let work = element("list.Work")
    reveal(work)
    work.tap()

    // Create.
    let field = app.textFields["newReminderField"]
    reveal(field)
    field.tap()
    field.typeText("Buy printer ink\n")
    let created = app.staticTexts["Buy printer ink"]
    XCTAssertTrue(created.waitForExistence(timeout: 5), "the new reminder shows in Work")
    XCTAssertTrue(app.staticTexts["Prepare the demo"].exists, "next to Work's other reminders")

    // Update: title and due date in the editor (opened right away: a just-created reminder must keep its editor open).
    created.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["task.title"].firstMatch.waitForExistence(timeout: 5),
      "the reminder's editor opens")
    app.buttons["task.more"].tap()
    replaceText(
      in: app.descendants(matching: .any)["task.title"].firstMatch,
      with: "Buy printer ink and paper")
    let deadline = app.switches["Deadline"]
    XCTAssertTrue(deadline.exists)
    // the switch itself, not the label
    deadline.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    XCTAssertTrue(wait(deadline, "value == '1'"), "Deadline is on")
    let tomorrow = cal.date(byAdding: .day, value: 1, to: .now)!
    // Stay in the month the picker opens on: tomorrow, or yesterday on the last day of a month.
    let dueDay =
      cal.isDate(tomorrow, equalTo: .now, toGranularity: .month)
      ? tomorrow : cal.date(byAdding: .day, value: -1, to: .now)!
    // Due, the only date picker
    pickDate(app.datePickers.element(boundBy: 0), day: dueDay)
    app.buttons["task.save"].tap()

    let renamed = app.staticTexts["Buy printer ink and paper"]
    XCTAssertTrue(renamed.waitForExistence(timeout: 5), "the new title is saved")
    XCTAssertFalse(app.staticTexts["Buy printer ink"].exists, "the old title is gone")
    let dueText = cal.isDate(dueDay, inSameDayAs: tomorrow) ? "Due Tomorrow" : "Due Yesterday"
    XCTAssertTrue(
      app.staticTexts[dueText].waitForExistence(timeout: 3),
      "the row shows the new deadline (\(dueText))")

    // Flag (long-press menu, like Apple Reminders).
    renamed.press(forDuration: 1.0)
    // The menu's Flag (the inline New Reminder row has a Flag button of its own).
    let flag = app.buttons.matching(
      NSPredicate(format: "label == 'Flag' AND identifier != 'newRow.flag'")
    ).firstMatch
    XCTAssertTrue(flag.waitForExistence(timeout: 3), "the long-press menu offers Flag")
    flag.tap()
    let flaggedMark = app.cells.containing(.staticText, identifier: "Buy printer ink and paper")
      .images["Flagged"]
    XCTAssertTrue(
      flaggedMark.waitForExistence(timeout: 3)
        || any("label == 'Flagged'").waitForExistence(timeout: 1),
      "the row shows a flag")

    // Complete with the circle.
    app.buttons["Complete Buy printer ink and paper"].tap()
    XCTAssertTrue(
      renamed.waitForNonExistence(timeout: 5), "a completed reminder leaves the open list")
    goBack()
    let completed = element("smart.completed")
    app.revealReminderPill(completed)
    XCTAssertTrue(
      wait(completed, "label BEGINSWITH 'Completed, 4'"), "Completed counts it: \(completed.label)")
    let flagged = element("smart.flagged")
    app.revealReminderPill(flagged)
    XCTAssertTrue(
      flagged.label.hasPrefix("Flagged, 3"),
      "a completed reminder no longer counts as flagged: \(flagged.label)")
    app.revealReminderPill(completed)
    completed.tap()
    let done = app.staticTexts["Buy printer ink and paper"]
    XCTAssertTrue(done.waitForExistence(timeout: 5), "it is in Completed")
    XCTAssertTrue(app.buttons["Reopen Buy printer ink and paper"].exists, "as a completed reminder")

    // Delete (swipe left) and Undo.
    swipeDelete(done)
    XCTAssertTrue(done.waitForNonExistence(timeout: 5), "deleted")
    tapUndo()
    XCTAssertTrue(
      app.staticTexts["Buy printer ink and paper"].waitForExistence(timeout: 5),
      "Undo brings it back")
  }

  /// + on Reminders opens the quick-add sheet: a title and time grid, then Save.
  func testReminderQuickAddWithPlus() {
    openTab("Reminders")
    app.addNew("New reminder")
    let title =
      app.textFields["quick.title"].exists
      ? app.textFields["quick.title"] : app.textViews["quick.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5), "+ on Reminders opens the quick-add sheet")
    title.typeText("Water the garden")
    app.buttons["+1 day"].tap()
    app.buttons["09:30"].tap()
    let when = app.buttons["quick.when"]
    let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now))!
    let at = cal.date(bySettingHour: 9, minute: 30, second: 0, of: tomorrow)!
    let shown = at.formatted(
      .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    XCTAssertTrue(
      wait(when, "label CONTAINS %@".replacingOccurrences(of: "%@", with: "'\(shown)'")),
      "the when bar shows tomorrow 09:30: \(when.label), expected \(shown)")
    app.buttons["quick.save"].tap()
    XCTAssertTrue(
      app.buttons["quick.save"].waitForNonExistence(timeout: 5), "Save closes the sheet")

    let scheduled = element("smart.scheduled")
    app.revealReminderPill(scheduled)
    scheduled.tap()
    let row = app.staticTexts["Water the garden"]
    reveal(row)
    XCTAssertTrue(row.exists, "the reminder is in Scheduled")
    let due = "Due Tomorrow " + at.formatted(date: .omitted, time: .shortened)
    XCTAssertTrue(
      any("label BEGINSWITH %@", due).waitForExistence(timeout: 3), "with its due time (\(due))")
  }

  /// Swipe left on a reminder offers Flag and Delete; Flag flags it, and the Flagged list shows it.
  func testReminderSwipeFlagShowsInFlagged() {
    openTab("Reminders")
    let home = element("list.Home")
    reveal(home)
    home.tap()
    let row = app.staticTexts["Backup photos"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    // A short drag reveals the buttons without a full swipe (which would delete).
    let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -140, dy: 0)))
    let flag = app.buttons["Flag"]
    XCTAssertTrue(flag.waitForExistence(timeout: 3), "swipe left shows Flag")
    flag.tap()
    goBack()
    let flagged = element("smart.flagged")
    app.revealReminderPill(flagged)
    XCTAssertTrue(
      wait(flagged, "label BEGINSWITH 'Flagged, 4'"), "four flagged now: \(flagged.label)")
    flagged.tap()
    XCTAssertTrue(app.staticTexts["Backup photos"].waitForExistence(timeout: 5), "it is in Flagged")
  }

  /// Add List, rename it (Name & Appearance), delete it (More > Delete List).
  func testListCreateRenameDelete() {
    openTab("Reminders")
    let add = app.buttons["addList"]
    reveal(add)
    add.tap()
    let name = app.textFields["List Name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5), "New List opens")
    name.typeText("Garden")
    app.navigationBars["New List"].buttons["Done"].tap()
    let garden = element("list.Garden")
    reveal(garden)
    XCTAssertTrue(garden.exists, "the new list is in My Lists")

    // Rename from inside the list.
    garden.tap()
    XCTAssertTrue(any("label BEGINSWITH 'Garden, '").waitForExistence(timeout: 5), "the list opens")
    app.buttons["More"].tap()
    app.buttons["Name & Appearance"].tap()
    XCTAssertTrue(app.navigationBars["Name & Appearance"].waitForExistence(timeout: 5))
    app.buttons["Clear name"].tap()
    app.textFields["List Name"].tap()
    app.textFields["List Name"].typeText("Garden Club")
    app.navigationBars["Name & Appearance"].buttons["Done"].tap()
    XCTAssertTrue(
      any("label BEGINSWITH 'Garden Club, '").waitForExistence(timeout: 5),
      "the title follows the rename")

    // A reminder in it moves with the list.
    let field = app.textFields["newReminderField"]
    field.tap()
    field.typeText("Plant tulips\n")
    XCTAssertTrue(app.staticTexts["Plant tulips"].waitForExistence(timeout: 5))

    // Delete.
    app.buttons["More"].tap()
    app.buttons["Delete List"].tap()
    let alert = app.alerts.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 5), "deleting asks first")
    XCTAssertTrue(alert.label.contains("Garden Club"), alert.label)
    alert.buttons["Delete List and Reminders"].tap()
    XCTAssertTrue(
      app.buttons["addList"].waitForExistence(timeout: 5)
        || element("list.Work").waitForExistence(timeout: 2),
      "back on Lists")
    for _ in 0..<3 { app.swipeUp() }
    XCTAssertFalse(element("list.Garden Club").exists, "the list is gone")
    XCTAssertFalse(element("list.Garden").exists)

    // Its reminder went with it.
    app.buttons["Open menu"].tap()
    XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 6))
    app.buttons["Search"].tap()
    let search = app.textFields["search.field"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.typeText("tulips")
    XCTAssertTrue(
      any("label CONTAINS 'No Results'").waitForExistence(timeout: 5),
      "the list's reminders were deleted with it")
  }

  /// Deleting a list with reminders can keep them: they move to the default "Reminders" list.
  func testListSwipeDeleteKeepsReminders() {
    openTab("Reminders")
    let home = element("list.Home")
    reveal(home)
    swipeDelete(home)
    let alert = app.alerts.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 5), "deleting a list asks first")
    alert.buttons["Delete List, Keep Reminders"].tap()
    XCTAssertTrue(home.waitForNonExistence(timeout: 5), "Home is gone")
    let all = element("smart.all")
    app.revealReminderPill(all)
    all.tap()
    XCTAssertTrue(
      app.staticTexts["Backup photos"].waitForExistence(timeout: 5), "its reminders are kept")
  }

  // MARK: - Calendar events

  /// The new event's default start: the next full hour (as `EventEditor.defaultStart`).
  private var nextFullHour: Date {
    cal.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)!
  }

  private func showMonth() {
    let month = app.buttons["calendar.mode.month"]
    XCTAssertTrue(month.waitForExistence(timeout: 5))
    month.tap()
    XCTAssertTrue(element("calendar.monthPager").waitForExistence(timeout: 5))
  }

  /// In Month, selects `day` (paging to its month first if needed).
  private func selectDay(_ day: Date) {
    if !cal.isDate(day, equalTo: .now, toGranularity: .month) {
      element("calendar.monthPager").swipeUp()
    }
    let id = String(
      format: "day.%04d-%02d-%02d", cal.component(.year, from: day),
      cal.component(.month, from: day), cal.component(.day, from: day))
    let cell = element(id)
    XCTAssertTrue(cell.waitForExistence(timeout: 5), "day cell \(id)")
    if !cell.isSelected { cell.tap() }
    XCTAssertTrue(wait(cell, "isSelected == true"), "\(id) is selected")
  }

  /// The day list under the month grid is lazy: scroll it until the row is built and on screen.
  private func revealInDayList(_ row: XCUIElement) {
    let list = element("calendar.dayList")
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    for _ in 0..<6 where !(row.exists && row.isHittable) { list.swipeUp() }
    _ = row.waitForExistence(timeout: 3)
  }

  /// A row in the Month day list.
  private func agendaRow(_ title: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'agenda.row' AND label BEGINSWITH %@", title + ",")
    ).firstMatch
  }

  /// A row in the Today tab.
  private func todayRow(_ title: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
  }

  /// + on Calendar creates an event; it shows in Calendar and Today; open it, change title and time, save; delete it in the editor.
  func testEventCreateEditDeleteInEditor() {
    openTab("Calendar")
    let start = nextFullHour
    app.addNew("New event")
    XCTAssertTrue(
      app.navigationBars["New event"].waitForExistence(timeout: 5), "+ on Calendar adds an event")
    app.textFields["event.title"].typeText("Piano lesson")
    app.navigationBars["New event"].buttons["Done"].tap()

    // Read: Calendar (Month, its day) and Today.
    showMonth()
    selectDay(start)
    let row = agendaRow("Piano lesson")
    revealInDayList(row)
    XCTAssertTrue(row.exists, "the event is listed on its day")
    if cal.isDateInToday(start) {
      openTab("Today")
      let today = todayRow("Piano lesson")
      if !today.waitForExistence(timeout: 3) { reveal(today) }
      XCTAssertTrue(today.exists, "and in Today")
      openTab("Calendar")
      showMonth()
      selectDay(start)
      revealInDayList(agendaRow("Piano lesson"))
    }

    // Update: title and start time.
    agendaRow("Piano lesson").tap()
    XCTAssertTrue(
      app.navigationBars["Event"].waitForExistence(timeout: 5), "the event's editor opens")
    replaceText(in: app.textFields["event.title"], with: "Piano recital")
    let starts = app.datePickers.element(boundBy: 0)  // Starts (then Ends)
    XCTAssertTrue(
      starts.waitForExistence(timeout: 3), "Starts: \(app.datePickers.debugDescription)")
    // the time, not the date
    let time = starts.buttons.matching(NSPredicate(format: "label CONTAINS ':'")).firstMatch
    XCTAssertTrue(time.exists, "the time button: \(starts.debugDescription)")
    time.tap()
    let minutes = app.pickerWheels.element(boundBy: 1)
    XCTAssertTrue(minutes.waitForExistence(timeout: 5), "the time wheels: \(app.debugDescription)")
    minutes.adjust(toPickerWheelValue: "30")
    dismissPopover()
    app.navigationBars["Event"].buttons["Done"].tap()
    let edited = agendaRow("Piano recital")
    revealInDayList(edited)
    XCTAssertTrue(edited.exists, "the new title is saved")
    XCTAssertFalse(agendaRow("Piano lesson").exists, "the old title is gone")
    let newStart = start.addingTimeInterval(30 * 60)
    let range = EventLabel.range(newStart, newStart.addingTimeInterval(3600))
    XCTAssertTrue(
      edited.label.contains(range),
      "it starts half an hour later and keeps its hour: \(edited.label), expected \(range)")

    // Delete in the editor.
    edited.tap()
    XCTAssertTrue(app.navigationBars["Event"].waitForExistence(timeout: 5))
    let delete = app.buttons["Delete event"]
    XCTAssertTrue(delete.waitForExistence(timeout: 3), "a one-off event says Delete event")
    delete.tap()
    XCTAssertTrue(edited.waitForNonExistence(timeout: 5), "the event is gone")
    tapUndo()
    revealInDayList(agendaRow("Piano recital"))
    XCTAssertTrue(agendaRow("Piano recital").exists, "Undo brings it back")
  }

  /// Today: swipe left on an event row deletes it (Undo brings it back). Calendar: long-press > Delete.
  func testEventSwipeAndLongPressDelete() {
    let dentist = todayRow("Dentist")
    if !dentist.waitForExistence(timeout: 3) { reveal(dentist, up: false) }
    XCTAssertTrue(dentist.exists, "Dentist is on today's schedule")
    swipeDelete(dentist)
    XCTAssertTrue(dentist.waitForNonExistence(timeout: 5), "swipe left deletes it")
    tapUndo()
    XCTAssertTrue(todayRow("Dentist").waitForExistence(timeout: 5), "Undo brings it back")

    openTab("Calendar")
    showMonth()
    let lunch = agendaRow("Lunch with Priya")
    XCTAssertTrue(lunch.waitForExistence(timeout: 5), "today's events under the grid")
    lunch.press(forDuration: 1.0)
    for name in ["Show Details", "Edit", "Delete"] {
      XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 3), "the menu has \(name)")
    }
    app.buttons["Delete"].tap()
    XCTAssertTrue(lunch.waitForNonExistence(timeout: 5), "long-press Delete removes it")
    XCTAssertTrue(agendaRow("Product sync").exists, "other events stay")
    openTab("Today")
    XCTAssertFalse(todayRow("Lunch with Priya").exists, "and it is gone from Today too")
  }

  /// A repeating event's Delete asks first (swipe or long-press), and Cancel keeps it.
  func testRepeatingEventDeleteAsksFirst() {
    openTab("Calendar")
    showMonth()
    let tomorrow = cal.date(byAdding: .day, value: 1, to: .now)!
    selectDay(tomorrow)
    let weekly = agendaRow("Weekly sync")
    XCTAssertTrue(weekly.waitForExistence(timeout: 5), "Weekly sync is tomorrow")

    weekly.press(forDuration: 1.0)
    app.buttons["Delete"].tap()
    XCTAssertTrue(
      app.staticTexts["“Weekly sync” repeats."].waitForExistence(timeout: 5), "it asks first")
    XCTAssertTrue(app.buttons["Delete All Occurrences"].exists, "the series choice")
    // Cancel: a button, or (in a popover) a tap outside.
    if app.buttons["Cancel"].exists {
      app.buttons["Cancel"].tap()
    } else {
      dismissPopover(tapping: element("topBar.month"))
    }
    XCTAssertTrue(
      app.buttons["Delete All Occurrences"].waitForNonExistence(timeout: 3), "the question closes")
    XCTAssertTrue(weekly.waitForExistence(timeout: 3), "Cancel keeps it")

    // Swipe: no full swipe for a repeating event, so the question can't be skipped.
    weekly.swipeLeft()
    let delete = app.buttons["Delete"]
    XCTAssertTrue(delete.waitForExistence(timeout: 3), "swipe shows Delete")
    XCTAssertTrue(weekly.exists, "a swipe alone deletes nothing")
    delete.tap()
    XCTAssertTrue(
      app.buttons["Delete All Occurrences"].waitForExistence(timeout: 5), "it asks again")
    app.buttons["Delete All Occurrences"].tap()
    XCTAssertTrue(weekly.waitForNonExistence(timeout: 5), "the series is gone")
    let nextWeek = cal.date(byAdding: .day, value: 8, to: .now)!
    selectDay(nextWeek)
    XCTAssertFalse(agendaRow("Weekly sync").waitForExistence(timeout: 2), "next week's too")
  }

  // MARK: - Alarms

  private var alarmRows: XCUIElementQuery { app.buttons.matching(identifier: "alarm.row") }

  private func alarmRow(_ label: String) -> XCUIElement {
    app.buttons.matching(
      NSPredicate(format: "identifier == 'alarm.row' AND label CONTAINS %@", label)
    ).firstMatch
  }

  private func alarmSwitch(_ label: String) -> XCUIElement {
    app.switches.matching(
      NSPredicate(format: "identifier == 'alarm.toggle' AND label CONTAINS %@", label)
    ).firstMatch
  }

  /// + on the Alarms section > Save; edit time and label; switch off and on; swipe to delete, Undo; Delete Alarm in the editor.
  func testAlarmCreateEditToggleDelete() {
    openTab("Clock")
    XCTAssertTrue(alarmRow("Wake up").waitForExistence(timeout: 5), "the dataset's alarms")
    XCTAssertEqual(alarmRows.count, 4)

    // Create.
    app.addNew("New alarm")
    XCTAssertTrue(
      app.staticTexts["Add Alarm"].waitForExistence(timeout: 5), "+ on Alarms adds an alarm")
    let label = app.textFields["alarm.label"]
    label.tap()
    label.typeText("Piano practice")
    app.buttons["alarm.save"].tap()
    let created = alarmRow("Piano practice")
    XCTAssertTrue(created.waitForExistence(timeout: 5), "the new alarm is listed")
    XCTAssertEqual(alarmRows.count, 5)
    XCTAssertTrue(
      stride(from: 0, to: 60, by: 5).contains {
        created.label.contains(String(format: ":%02d", $0))
      },
      "opens on a five-minute mark: \(created.label)")

    // Update: minutes and label (right away: a just-created alarm must keep its editor open).
    created.tap()
    XCTAssertTrue(app.staticTexts["Edit Alarm"].waitForExistence(timeout: 5))
    app.setAlarmMinutes("20")
    replaceText(in: app.textFields["alarm.label"], with: "Piano lesson")
    app.buttons["alarm.save"].tap()
    let edited = alarmRow("Piano lesson")
    XCTAssertTrue(edited.waitForExistence(timeout: 5), "the new label is saved")
    XCTAssertTrue(edited.label.contains(":20"), "and the new time: \(edited.label)")
    XCTAssertFalse(alarmRow("Piano practice").exists, "the old label is gone")
    XCTAssertEqual(alarmRows.count, 5, "edited in place, not added")

    // Switch off and on.
    let toggle = alarmSwitch("Piano lesson")
    XCTAssertEqual(toggle.value as? String, "1", "a saved alarm is on")
    toggle.toggleSwitch()
    XCTAssertTrue(wait(toggle, "value == '0'"), "switched off")
    toggle.toggleSwitch()
    XCTAssertTrue(wait(toggle, "value == '1'"), "and on again")

    // Delete with a swipe; Undo.
    swipeDelete(edited)
    XCTAssertTrue(edited.waitForNonExistence(timeout: 5), "swipe deletes it")
    XCTAssertEqual(alarmRows.count, 4)
    tapUndo()
    XCTAssertTrue(alarmRow("Piano lesson").waitForExistence(timeout: 5), "Undo brings it back")
    XCTAssertEqual(alarmRows.count, 5)

    // Delete Alarm in the editor (a dataset alarm).
    alarmRow("Take medicine").tap()
    let delete = app.buttons["alarm.delete"]
    XCTAssertTrue(delete.waitForExistence(timeout: 5))
    delete.tap()
    XCTAssertTrue(
      alarmRow("Take medicine").waitForNonExistence(timeout: 5), "Delete Alarm removes it")
    XCTAssertEqual(alarmRows.count, 4)
  }

  /// Switching off a dataset alarm that is on, and on one that is off.
  func testAlarmTogglesFromDataset() {
    openTab("Clock")
    let run = alarmSwitch("Weekend run")
    XCTAssertTrue(run.waitForExistence(timeout: 5))
    XCTAssertEqual(run.value as? String, "0", "Weekend run starts off")
    run.tap()
    XCTAssertTrue(wait(run, "value == '1'"))
    let wake = alarmSwitch("Wake up")
    XCTAssertEqual(wake.value as? String, "1")
    wake.tap()
    XCTAssertTrue(wait(wake, "value == '0'"))
    // Leaving the tab and coming back keeps both.
    openTab("Today")
    openTab("Clock")
    XCTAssertTrue(wait(alarmSwitch("Weekend run"), "value == '1'"))
    XCTAssertTrue(wait(alarmSwitch("Wake up"), "value == '0'"))
  }

  // MARK: - Chats

  private func chatRow(_ title: String) -> XCUIElement {
    app.buttons.matching(
      NSPredicate(format: "identifier == 'conversation.row' AND label == %@", title)
    ).firstMatch
  }

  private var askField: XCUIElement { app.textViews["Ask AI or add anything"].firstMatch }

  /// Ask AI bar: send a message, see it in the sidebar; reopen a chat; New chat from the sidebar.
  func testChatCreateAndReopen() {
    app.buttons["Ask AI or add anything"].tap()
    XCTAssertTrue(
      app.staticTexts["What do you want to plan?"].waitForExistence(timeout: 5), "a new chat")
    let field = askField.exists ? askField : app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.typeText("Anything left today?\n")
    XCTAssertTrue(
      app.staticTexts["Anything left today?"].waitForExistence(timeout: 5),
      "the message is in the chat")
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sign in to Luna AI'"))
        .firstMatch.waitForExistence(timeout: 5),
      "the AI answers (not signed in to Luna AI)")
    app.buttons["Close"].tap()

    openSidebar()
    let row = chatRow("Anything left today?")
    XCTAssertTrue(row.waitForExistence(timeout: 5), "the chat is in the sidebar")
    XCTAssertTrue(chatRow("Plan my day").exists, "with the dataset's chats")

    // Reopen a dataset chat.
    chatRow("Call Alex tomorrow at 3pm").tap()
    XCTAssertTrue(
      app.staticTexts["make it 4pm"].waitForExistence(timeout: 5), "its messages are back")
    app.buttons["Close"].tap()
    XCTAssertTrue(
      chatRow("Call Alex tomorrow at 3pm").waitForExistence(timeout: 5),
      "Close returns to the sidebar")

    // New chat from the sidebar.
    app.buttons["New chat"].tap()
    XCTAssertTrue(
      app.staticTexts["What do you want to plan?"].waitForExistence(timeout: 5),
      "New chat starts empty")
    let f2 = askField.exists ? askField : app.textViews.firstMatch
    f2.typeText("What's on this week?\n")
    XCTAssertTrue(app.staticTexts["What's on this week?"].waitForExistence(timeout: 5))
    app.buttons["Close"].tap()
    XCTAssertTrue(
      chatRow("What's on this week?").waitForExistence(timeout: 5), "the new chat is listed")
  }

  /// Long-press > Rename; long-press > Archive (shows under Archived); swipe > Delete and Undo.
  func testChatRenameArchiveDeleteUndo() {
    openSidebar()

    // Rename.
    let plan = chatRow("Plan my day")
    XCTAssertTrue(plan.waitForExistence(timeout: 5))
    plan.press(forDuration: 1.0)
    XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
    app.buttons["Rename"].tap()
    let field = app.alerts.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 3), "Rename asks for a title")
    XCTAssertEqual(field.value as? String, "Plan my day")
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Plan my day".count))
    field.typeText("Morning plan")
    XCTAssertTrue(wait(field, "value == 'Morning plan'"), "typed: \(field.value ?? "")")
    app.alerts.buttons["Save"].tap()
    XCTAssertTrue(chatRow("Morning plan").waitForExistence(timeout: 5), "renamed")
    XCTAssertFalse(chatRow("Plan my day").exists)

    // Archive.
    let left = chatRow("What's left today?")
    XCTAssertTrue(left.waitForExistence(timeout: 3))
    left.press(forDuration: 1.0)
    XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 3))
    app.buttons["Archive"].tap()
    XCTAssertTrue(left.waitForNonExistence(timeout: 5), "it leaves the list")
    let archived = app.buttons["conversation.archived"]
    XCTAssertTrue(archived.waitForExistence(timeout: 3), "an Archived section")
    if archived.value as? String != "Expanded" { archived.tap() }
    XCTAssertTrue(
      chatRow("What's left today?").waitForExistence(timeout: 5), "it is under Archived")
    XCTAssertTrue(chatRow("Book a hotel in Rome for March").exists, "with the one archived before")

    // Delete with a swipe (right to left, as on every list), then Undo.
    let dentist = chatRow("Move the dentist to tomorrow")
    XCTAssertTrue(dentist.waitForExistence(timeout: 3))
    dentist.swipeLeft()
    let delete = app.buttons["Delete"]
    XCTAssertTrue(delete.waitForExistence(timeout: 3), "swipe right to left shows Delete")
    delete.tap()
    XCTAssertTrue(dentist.waitForNonExistence(timeout: 5), "deleted")
    tapUndo()
    XCTAssertTrue(
      chatRow("Move the dentist to tomorrow").waitForExistence(timeout: 5), "Undo brings it back")
  }

  // MARK: - Search

  private func searchResult(_ title: String) -> XCUIElement {
    app.buttons.matching(
      NSPredicate(format: "identifier == 'search.result' AND label BEGINSWITH %@", title)
    ).firstMatch
  }

  /// Search opens from the sidebar's top-right button and finds reminders, events and alarms from the dataset.
  func testSearchFindsEveryKind() {
    openSidebar()
    app.buttons["Search"].tap()
    let field = app.textFields["search.field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5), "Search opens")

    func search(_ text: String) {
      if app.buttons["Clear text"].exists { app.buttons["Clear text"].tap() }
      field.typeText(text)
    }

    search("milk")
    XCTAssertTrue(searchResult("Buy milk").waitForExistence(timeout: 5), "a reminder")
    XCTAssertTrue(app.staticTexts["Reminders"].exists, "under Reminders")

    search("Dentist")
    XCTAssertTrue(searchResult("Dentist").waitForExistence(timeout: 5), "an event")
    XCTAssertTrue(app.staticTexts["Events"].exists)

    search("medicine")
    XCTAssertTrue(searchResult("Take medicine").waitForExistence(timeout: 5), "an alarm")
    XCTAssertTrue(app.staticTexts["Alarms"].exists)

    search("passport")
    XCTAssertTrue(
      searchResult("Renew passport").waitForExistence(timeout: 5), "a reminder far ahead")
    search("Documents folder")
    XCTAssertTrue(searchResult("Renew passport").waitForExistence(timeout: 5), "by its note")
    search("errands")
    XCTAssertTrue(searchResult("Buy milk").waitForExistence(timeout: 5), "by its tag")
    search("Pick up parcel")
    XCTAssertTrue(
      searchResult("Pick up parcel").waitForExistence(timeout: 5), "a completed reminder")
    search("Tokyo")
    XCTAssertTrue(
      searchResult("Book flights to Tokyo").waitForExistence(timeout: 5), "a reminder and")
    XCTAssertTrue(searchResult("Flight to Tokyo").exists, "an event with the same word")
    search("zzqx")
    XCTAssertTrue(
      any("label CONTAINS 'No Results'").waitForExistence(timeout: 5), "nothing for nonsense")

    // A result opens in its editor.
    search("Gym")
    let gym = searchResult("Gym")
    XCTAssertTrue(gym.waitForExistence(timeout: 5))
    gym.tap()
    XCTAssertTrue(app.navigationBars["Event"].waitForExistence(timeout: 5), "the event opens")
    XCTAssertEqual(app.textFields["event.title"].value as? String, "Gym")
    app.navigationBars["Event"].buttons["Cancel"].tap()

    app.buttons["Close search"].tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Search closes")
  }

  /// What was created in the session can be found, and what was deleted can't.
  func testSearchSeesCreatedAndDeletedItems() {
    let createdTitle = "QA bank reminder"
    XCTAssertFalse(
      app.staticTexts[createdTitle].exists, "the fixture cannot satisfy the creation assertion")
    openTab("Reminders")
    let reminders = element("list.Reminders")
    reveal(reminders)
    reminders.tap()
    let field = app.textFields["newReminderField"]
    reveal(field)
    field.tap()
    field.typeText(createdTitle + "\n")
    XCTAssertTrue(app.staticTexts[createdTitle].waitForExistence(timeout: 5))
    XCTAssertEqual(
      app.staticTexts.matching(identifier: createdTitle).count, 1, "one newly created reminder")
    let article = app.staticTexts["Read that design article"]
    XCTAssertTrue(article.exists)
    swipeDelete(article)
    XCTAssertTrue(article.waitForNonExistence(timeout: 5))
    goBack()

    openSidebar()
    app.buttons["Search"].tap()
    let search = app.textFields["search.field"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.typeText(createdTitle)
    XCTAssertTrue(
      searchResult(createdTitle).waitForExistence(timeout: 5), "a reminder made in this session")
    app.buttons["Clear text"].tap()
    search.typeText("design article")
    XCTAssertTrue(
      any("label CONTAINS 'No Results'").waitForExistence(timeout: 5),
      "a deleted reminder is not found")
  }
}

/// How a row reads an event's time, e.g. "22:30 to 23:30" (the app's EventSpeech).
private enum EventLabel {
  static func range(_ start: Date, _ end: Date) -> String {
    let text = Date.IntervalFormatStyle(time: .shortened).format(start..<end)
    let pieces = text.split(whereSeparator: { "–—-".contains($0) }).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return pieces.count == 2 ? pieces.joined(separator: " to ") : text
  }
}
