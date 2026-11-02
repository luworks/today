import XCTest

/// The left sidebar is the history of conversations with the AI (like ChatGPT / Claude), not a second tab bar.
/// Each test runs against a fresh in-memory store, so there are no conversations to start with.
@MainActor
final class SidebarTests: XCTestCase {
  var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = ["-uiTesting"]
      app.launch()
    }
  }

  /// Talks to the AI once and returns to the main page. Not signed in to Luna AI (TodayMock), a question gets the
  /// "sign in" answer, so no model or preview is involved; Close drops the draft it puts back.
  private func haveAConversation(_ text: String = "Anything left today?") {
    let bar = app.buttons["Ask AI or add anything"]
    XCTAssertTrue(bar.waitForExistence(timeout: 5))
    bar.tap()
    let field =
      app.textViews["Ask AI or add anything"].firstMatch.exists
      ? app.textViews["Ask AI or add anything"].firstMatch
      : app.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.typeText(text + "\n")
    XCTAssertTrue(reply.waitForExistence(timeout: 5), "the AI answers")
    app.buttons["Close"].tap()
    XCTAssertTrue(bar.waitForExistence(timeout: 5), "back on the main page")
  }

  private var reply: XCUIElement {
    app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sign in to Luna AI'"))
      .firstMatch
  }

  func testConversationAppearsInSidebarAndReopens() {
    haveAConversation("Anything left today?")
    app.openSidebar()
    let row = app.buttons["Anything left today?"]
    XCTAssertTrue(
      row.waitForExistence(timeout: 5), "the conversation is listed, titled by the first message")
    row.tap()
    XCTAssertTrue(
      app.staticTexts["Anything left today?"].waitForExistence(timeout: 5),
      "the user's message is back")
    XCTAssertTrue(reply.waitForExistence(timeout: 5), "and the AI's answer")
    XCTAssertFalse(
      app.staticTexts["What do you want to plan?"].exists,
      "it is the old conversation, not a new one")
  }

  func testNewChatStartsEmpty() {
    haveAConversation()
    app.openSidebar()
    app.buttons["New chat"].tap()
    XCTAssertTrue(app.staticTexts["What do you want to plan?"].waitForExistence(timeout: 5))
    XCTAssertFalse(reply.exists)
  }

  func testSwipeLeftDeletesAConversationAndUndoBringsItBack() {
    haveAConversation()
    app.openSidebar()
    let row = app.buttons["Anything left today?"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.swipeLeft()
    let delete = app.buttons["Delete"]
    XCTAssertTrue(
      delete.waitForExistence(timeout: 3), "swiping right to left reveals Delete, as on every list")
    delete.tap()
    XCTAssertTrue(row.waitForNonExistence(timeout: 5), "the conversation is gone")
    XCTAssertTrue(
      app.staticTexts["Your conversations with AI will appear here."].waitForExistence(timeout: 3))
    let undo = app.buttons["Undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 3), "there is an Undo")
    undo.tap()
    XCTAssertTrue(
      app.buttons["Anything left today?"].waitForExistence(timeout: 5), "Undo puts it back")
  }

  /// Opened from the sidebar, the chat goes back to the sidebar: by the close button, and by swiping right from the
  /// left edge.
  func testChatOpenedFromSidebarGoesBackToSidebar() {
    haveAConversation()
    app.openSidebar()
    let row = app.buttons["Anything left today?"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.tap()
    XCTAssertTrue(reply.waitForExistence(timeout: 5))
    app.buttons["Close"].tap()
    XCTAssertTrue(row.waitForExistence(timeout: 5), "Close returns to the sidebar, not the page")

    row.tap()
    XCTAssertTrue(reply.waitForExistence(timeout: 5))
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.4))
    start.press(
      forDuration: 0.05,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.4)))
    XCTAssertTrue(row.waitForExistence(timeout: 5), "a right swipe returns to the sidebar")
    XCTAssertFalse(reply.exists)
  }

  func testSwipeLeftArchivesAConversationIntoTheArchivedSection() {
    haveAConversation()
    app.openSidebar()
    let row = app.buttons["Anything left today?"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.swipeLeft()
    let archive = app.buttons["Archive"]
    XCTAssertTrue(archive.waitForExistence(timeout: 2))
    archive.tap()
    XCTAssertTrue(row.waitForNonExistence(timeout: 5), "the conversation leaves the main list")
    let archived = app.buttons["conversation.archived"]
    XCTAssertTrue(archived.waitForExistence(timeout: 3), "an Archived section appears")
    archived.tap()
    XCTAssertTrue(
      app.buttons["Anything left today?"].waitForExistence(timeout: 5),
      "it is still reachable under Archived")
  }

  /// The page stays visible on the right of the open sidebar; swiping it back to the left closes the sidebar.
  /// (A swipe on a chat row shows that row's actions instead, like every other list.)
  func testSwipeLeftOnThePageReturnsToToday() {
    haveAConversation()
    app.openSidebar()
    let row = app.buttons["Anything left today?"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
      .press(
        forDuration: 0.05,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
    // The closed sidebar stays built behind the page, so check that the page is back and reachable instead.
    let calendar = app.buttons["Calendar"].firstMatch
    let back = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == true"), object: calendar)
    XCTAssertEqual(
      XCTWaiter().wait(for: [back], timeout: 8), .completed, "a left swipe closes the sidebar")
  }

  func testLongPressOffersRenameArchiveAndDelete() {
    haveAConversation()
    app.openSidebar()
    let row = app.buttons["Anything left today?"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.press(forDuration: 1.0)
    for name in ["Rename", "Archive", "Delete"] {
      XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 3), "the menu has \(name)")
    }
    app.buttons["Rename"].tap()
    let field = app.alerts.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 3), "Rename asks for a new title")
    // The field starts with the current title. (Typing a new one is checked by hand: the on-screen keyboard
    // does not clear reliably under automation on every OS.)
    XCTAssertEqual(
      field.value as? String, "Anything left today?", "Rename starts from the current title")
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(
      app.buttons["Anything left today?"].waitForExistence(timeout: 5), "cancelling keeps the title"
    )
  }

  func testSidebarHasNoTabRowsAndShowsTheEmptyState() {
    app.openSidebar()
    XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["Settings"].exists)
    XCTAssertTrue(app.staticTexts["Your conversations with AI will appear here."].exists)
    // The pill bar on the page behind owns these; the sidebar must not repeat them.
    // The page stays visible beside the sidebar (its pills included), so look inside the sidebar itself.
    let sidebar = app.otherElements["sidebar"]
    XCTAssertTrue(sidebar.exists)
    for name in ["Today", "Calendar", "Reminders", "Clock"] {
      let byId = sidebar.buttons.matching(identifier: name).count
      let byLabel = sidebar.buttons.matching(NSPredicate(format: "label == %@", name)).count
      XCTAssertEqual(byId + byLabel, 0, "no \(name) row in the sidebar")
    }
  }

  func testCloseButtonClosesTheSidebar() {
    app.openSidebar()
    let close = app.buttons["Close sidebar"]
    XCTAssertTrue(close.waitForExistence(timeout: 3))
    close.tap()
    XCTAssertTrue(
      app.buttons["Calendar"].firstMatch.waitForExistence(timeout: 8), "the page is back")
    // The closed sidebar stays built (so opening is instant) but sits behind the page: it can't be touched.
    let newChat = app.buttons["New chat"]
    let covered = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == false"), object: newChat)
    XCTAssertEqual(
      XCTWaiter().wait(for: [covered], timeout: 8), .completed,
      "the sidebar is out of reach once closed")
  }
}
