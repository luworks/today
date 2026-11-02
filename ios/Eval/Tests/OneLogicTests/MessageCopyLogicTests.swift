import XCTest

@testable import TodayCore

final class MessageCopyLogicTests: XCTestCase {
  func testYourOwnWordsAlwaysCopy() {
    XCTAssertFalse(MessageCopy.isTemplate(isUser: true, content: false))
    XCTAssertFalse(ChatMessage(role: .user, text: "Call Alex tomorrow").isTemplate)
  }

  func testTheAppsOwnSentencesAreTemplatesAndTheModelsAnswersAreNot() {
    XCTAssertTrue(ChatMessage(role: .ai, text: "Here's what I understood.").isTemplate)
    XCTAssertTrue(ChatMessage(role: .ai, text: "卡片准备好了，点了才会生效。").isTemplate)
    XCTAssertFalse(
      ChatMessage(role: .ai, text: "明天 10:00 项目周会，12:00 午餐。", carriesContent: true).isTemplate)
  }

  func testOlderChatsWithoutTheFlagDecodeAsTemplates() throws {
    let old =
      #"{"id":"6F1C2A50-0000-4000-8000-000000000001","role":"ai","text":"Today: 1 open task."}"#
    let message = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
    XCTAssertNil(message.carriesContent)
    XCTAssertTrue(message.isTemplate)
  }
}
