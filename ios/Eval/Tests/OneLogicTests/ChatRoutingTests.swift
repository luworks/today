import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class ChatRoutingTests: XCTestCase {
  func testMonthOnlyBookingRequestPreservesActionWithoutInventingAppointment() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2030, month: 10, day: 19, hour: 9)))
    for (text, title) in [
      ("明年8月 预约医生做 annual check", "2031年8月 预约医生做 annual check"),
      (
        "Next August book a doctor for an annual check",
        "August 2031 book a doctor for an annual check"
      ),
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
      let capture = CaptureConversation.parse(text, now: now, calendar: calendar)
      XCTAssertEqual(capture.title, title)
      XCTAssertEqual(capture.kind, .task)
      XCTAssertTrue(CaptureParser.isBookingAction(text))
      XCTAssertFalse(capture.hasDay)
      XCTAssertNil(capture.hour)
      XCTAssertNil(capture.taskTiming(calendar: calendar).due)
      XCTAssertTrue(capture.notes?.contains(text) == true)
      XCTAssertTrue(capture.isReadyToAdd)
      let action = try XCTUnwrap(
        CaptureParser.leadingMonth(text, now: now, calendar: calendar)?.action)
      // A follow-up changes the preview only, retaining the requested month and original subject.
      guard
        case .updated(let renamed) = Dialogue.refine(
          capture, with: "call it Book annual check", now: now, calendar: calendar)
      else {
        return XCTFail("Expected a preview refinement")
      }
      XCTAssertEqual(renamed.title, "Book annual check")
      XCTAssertEqual(renamed.notes, capture.notes)
      XCTAssertNil(renamed.taskTiming(calendar: calendar).due)
    }
  }

  func testMonthContextDoesNotCreateFromReportsQuestionsOrRefusals() {
    for text in [
      "明年8月 我已经预约医生做 annual check 了",
      "明年8月 预约好了医生做 annual check",
      "明年8月 预约医生需要带什么？",
      "明年8月 不要创建预约医生的提醒",
      "Next August I already booked a doctor for an annual check",
      "Next August how do I book a doctor?",
      "Next August don't add a task to book a doctor",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
      XCTAssertNil(ChatRouting.contextualTimeAnswer(text, hasTimeContext: true), text)
    }
  }

  func testConversationIsNotAnItemEvenWithPlannerWordsOrDates() {
    for text in [
      "我进行一个测试，然后看看我的 Activity 中是不是会选择显示",
      "I'm testing whether this appears in Activity",
      "你好", "Thanks for explaining the alarm", "谢谢，明天再聊",
      "我今天很累，想聊聊天", "I am feeling overwhelmed by tomorrow's meeting",
      "I already set an alarm for 7am", "我已经设置了明天7点的闹钟",
      "Can you explain what remind me means?", "I'm testing the app", "Write me a cover letter",
      "帮我写一封邮件", "Write me a poem", "I already bought milk yesterday", "我记得今天还有一个会议",
      "I remember you said remind me", "How do I create an alarm?", "怎么设置闹钟？",
      "What's your favorite movie?",
      "Don't add a task, I'm just chatting", "不要创建任务，我只是说说",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
    }
  }

  func testEmbeddedCreationWordsDoNotOverrideConversation() {
    for text in [
      "What happens if I set an alarm for 7am?",
      "Can you tell me how to add a reminder?",
      "How does remind me work?",
      "为什么设置闹钟需要权限？", "如何添加一个提醒？",
      "Yesterday I set an alarm for 7am", "我昨天设置了明天7点的闹钟",
      "Don’t remind me to buy milk", "不要提醒我明天买牛奶",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
    }
  }

  func testAlarmQuestionsAndRefusalsAreConversation() {
    for text in [
      "Did I set an alarm for 7am?", "Have I set an alarm for 7am?",
      "Can you show me how to set an alarm?", "Could you show me how to add a timer?",
      "Don't wake me at 7am, okay?", "Don’t wake me at 7am, okay?",
      "Do not wake me at 7am", "我设置了早上7点的闹钟吗？",
      "我是不是设了7点的闹钟？", "你能教我怎么设一个闹钟吗？",
      "不要早上7点叫醒我，好吗？", "不用7点叫我起床",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
    }
  }

  func testExplicitAndTerseRequestsStillReachCapture() {
    for text in [
      "Could you add a timer for 10 minutes?", "可以帮我设一个早上7点的闹钟吗？", "能明天7点叫醒我吗？",
      "Can you buy milk?", "买几个苹果", "Buy milk", "Call Alex tomorrow at 3pm", "Pay studio invoice",
      "明天下午3点开会", "Dentist tomorrow at 3pm", "Set an alarm for 7am",
      "Can you set an alarm for 7am?",
      "When I get home remind me to buy milk", "明天提醒我设置闹钟",
      "提醒我明天买牛奶", "明天早上7点叫醒我", "Can you remind me to call Mom?",
      "可以明天提醒我买牛奶吗？", "Buy milk; Call Alex tomorrow at 3pm",
      "请把我可以卖的东西都放到车库去，然后今天下午 3 点的时候提醒我移动一下",
      "哦，我想卖家里的一些东西，然后去 Marketplace。今天下午 3 点提醒我吧",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
    }
  }

  func testQuestionsAndReportsAboutRequestsStayConversation() {
    for text in [
      "Did I add a reminder for 7am?", "Did you remind me to call Mom?",
      "Have you set a reminder for tomorrow?", "Does add a reminder need permission?",
      "Should I remind me to call Mom?", "Would adding a reminder help?",
      "Can you confirm you added a reminder?", "Could you check whether you remind me?",
      "Is it possible to add a reminder?", "What does add a reminder do?",
      "You said remind me to call Mom", "Yesterday you said add a reminder",
      "你提醒我明天买牛奶了吗？", "我添加了明天7点的提醒吗？",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
      XCTAssertNil(ChatRouting.contextualTimeAnswer(text, hasTimeContext: true), text)
    }
  }

  func testChineseExistingActionQuestionsDoNotBecomeNewRequests() {
    for text in [
      "有没有人提醒我明天的会议？", "有人添加了一个提醒吗？",
      "是否有人提醒我明天的会议？", "谁提醒我明天的会议？",
      "有人添加了一个提醒", "有没有人提醒我明天的会议",
      "你提醒我明天买牛奶了吗？", "我添加了明天7点的提醒吗？",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
      XCTAssertNil(ChatRouting.contextualTimeAnswer(text, hasTimeContext: true), text)
    }
  }

  func testChineseRequestBoundaryPreservesExplicitRequests() {
    for text in [
      "提醒我明天买牛奶", "明天提醒我设置闹钟", "7点提醒我买牛奶",
      "可以明天提醒我买牛奶吗？", "能不能帮我添加一个提醒？",
      "请添加一个明天买牛奶的提醒", "帮我记一下明天买牛奶", "别忘了买牛奶",
      "请把我可以卖的东西都放到车库去，然后今天下午 3 点的时候提醒我移动一下",
      "哦，我想卖家里的一些东西，然后去 Marketplace。今天下午 3 点提醒我吧",
      "Can you remind me to 买牛奶 tomorrow?", "Can you add a reminder for 买牛奶?",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
    }
  }

  func testSupportedChineseWeekdayPrefixesStillReachCapture() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9))!
    // These are the weekday forms already understood by CaptureParser, including both Sundays.
    for prefix in ["", "下", "这", "这个", "本", "下下"] {
      for week in ["周", "星期", "礼拜"] {
        for (day, weekday) in [
          ("一", 2), ("二", 3), ("三", 4), ("四", 5),
          ("五", 6), ("六", 7), ("日", 1), ("天", 1),
        ] {
          for (time, hour) in [("", nil), ("上午9点", 9), ("下午3点半", 15)] as [(String, Int?)] {
            let text = prefix + week + day + time + "提醒我买牛奶"
            XCTAssertEqual(ChatRouting.intent(text), .capture, text)
            let parsed = CaptureParser.parse(text, now: now, calendar: cal)
            XCTAssertTrue(parsed.hasDay, text)
            XCTAssertEqual(cal.component(.weekday, from: parsed.day), weekday, text)
            XCTAssertEqual(parsed.hour, hour, text)
          }
        }
      }
    }
    for text in [
      "可以下周一上午9点提醒我买牛奶吗？", "请本星期五下午3点提醒我交报告",
      "Please 下礼拜天提醒我买牛奶", "下周一 09:30 提醒我买牛奶",
      "下午3点下周一提醒我买牛奶", "我想先休息。下周一上午9点提醒我买牛奶",
      "请先收拾东西，然后这礼拜日下午3点的时候提醒我出发",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
    }
  }

  func testWeekdayWordsDoNotTurnExistingActionQuestionsIntoRequests() {
    for text in [
      "有没有人提醒我下周一的会议？", "有人添加了下周五的提醒吗？",
      "谁提醒我本星期天买牛奶？", "你提醒我这礼拜日买牛奶了吗？",
      "下周一有人提醒我买牛奶吗？", "本星期五是否有人添加了一个提醒？",
      "下周八提醒我买牛奶", "星期提醒我买牛奶", "周刊提醒我买牛奶",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
      XCTAssertNil(ChatRouting.contextualTimeAnswer(text, hasTimeContext: true), text)
    }
  }

  func testReportedWeekdayReminderQuestionStaysConversation() {
    XCTAssertEqual(ChatRouting.intent("本周一添加的提醒是什么？"), .conversation)
  }

  func testChineseReportedActionsAndRelativeClauseQuestionsStayConversation() {
    for prefix in ["", "明天", "本周一", "下星期五下午3点"] {
      for question in [
        "添加的提醒是什么？", "创建的提醒是哪一个？", "添加了一个提醒吗？",
        "创建过的提醒有哪些？", "提醒我开会的是谁？", "提醒我买牛奶了吗？",
      ] {
        let text = prefix + question
        XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
        XCTAssertNil(ChatRouting.contextualTimeAnswer(text, hasTimeContext: true), text)
      }
    }
  }

  func testChineseCreationQuestionsKeepTheirActualReminderObjects() {
    for text in [
      "帮我添加一个提醒", "添加一个提醒", "下周一提醒我买牛奶",
      "可以帮我添加一个下周一的提醒吗？", "本周一添加一个买牛奶的提醒好吗？",
      "下周一提醒我检查会议的资料好吗？", "添加一个读完了的书的整理提醒",
      "添加了不起的项目复盘提醒好吗？", "提醒我检查是谁添加的文件",
      "帮我添加一个名叫添加了什么的提醒好吗？",
      "添加一个谁动了我的奶酪的读书提醒", "提醒我把做完了的报告发给同事",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
    }
  }

  func testExplicitReminderWithEmbeddedCompletionQuestionStillCaptures() {
    XCTAssertEqual(ChatRouting.intent("下周一提醒我确认报告提交了没有"), .capture)
  }

  func testReminderObjectsCanContainCompletionChecks() {
    for text in [
      "提醒我检查门锁好了没", "提醒我确认报告提交了没有",
      "下星期五下午3点提醒我检查门锁好了没",
      "帮我添加一个提醒，确认报告提交了没有",
      "添加一个提醒，确认报告提交了没有",
      "本周一添加一个提醒，检查门锁好了没",
      "可以帮我添加一个提醒，确认报告提交了没有？",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
    }
  }

  func testLeadingCompletedActionInquiriesRemainConversation() {
    for prefix in ["", "本周一", "明天"] {
      for question in [
        "添加了没有？", "创建了没？", "提醒我了没有？", "提醒我了没？",
        "添加了一个提醒吗？", "提醒我买牛奶了吗？",
        "添加的提醒是什么？", "提醒我开会的是谁？",
      ] {
        let text = prefix + question
        XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
        XCTAssertNil(ChatRouting.contextualTimeAnswer(text, hasTimeContext: true), text)
      }
    }
  }

  func testExplicitReminderWithPolarObjectQuestionStillCaptures() {
    XCTAssertEqual(ChatRouting.intent("提醒我确认报告提交了吗"), .capture)
  }

  func testCheckAndInquiryReminderObjectsCanContainPolarQuestions() {
    for prefix in ["提醒我", "下周一提醒我", "本星期五下午3点提醒我"] {
      for object in [
        "确认报告提交了吗", "检查门锁好了吗？", "问他吃饭了吗",
        "询问同事收到邮件了吗？", "核实快递送到过吗", "查看备份完成了吗",
        "查明款项到账了吗", "看看灯关了吗？",
      ] {
        XCTAssertEqual(ChatRouting.intent(prefix + object), .capture, prefix + object)
      }
    }
    for text in [
      "添加一个提醒，确认报告提交了吗", "下周一添加一个提醒，询问同事收到邮件了吗",
      "提醒我下周一检查报告提交了吗",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
    }
  }

  func testReportedActionsRemainConversationEvenWhenTheyMentionChecks() {
    for prefix in ["", "本周一", "明天"] {
      for question in [
        "提醒我买牛奶了吗？", "提醒我了没有？", "添加了一个提醒吗？",
        "添加了一个确认报告的提醒吗？", "提醒过我确认报告了吗？",
        "提醒我检查门锁的是谁？", "添加的检查报告提醒是什么？",
      ] {
        let text = prefix + question
        XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
        XCTAssertNil(ChatRouting.contextualTimeAnswer(text, hasTimeContext: true), text)
      }
    }
  }

  func testPoliteEnglishPrefixPreservesChineseReminderRequest() {
    for text in ["Please 提醒我明天买牛奶", "Can you 明天提醒我买牛奶?"] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
    }
  }

  func testPoliteContentGenerationStaysConversation() {
    for prefix in ["", "Please ", "Can you ", "Could you "] {
      for request in [
        "write a story?", "write me a poem?", "write me a cover letter?", "make a joke?",
      ] {
        XCTAssertEqual(ChatRouting.intent(prefix + request), .conversation, prefix + request)
      }
    }
    for text in [
      "Remind me to write a story tomorrow", "Can you remind me to write a poem tomorrow?",
      "Write the report tomorrow", "Could you write the report tomorrow?",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
    }
  }

  func testSupportedOperationQuestionsReachExistingDispatch() {
    for text in [
      "Can you tidy overdue?", "Could you tidy my 2 overdue reminders?",
    ] {
      // Unsure continues to the existing planner handlers, rather than generic chat/capture.
      XCTAssertEqual(ChatRouting.intent(text), .unsure, text)
    }
    for text in [
      "How does Plan my day work?", "Does plan my day move events?",
      "Can you explain tidy overdue?", "Did you plan my day?",
      "Could you tell me how to tidy overdue?", "总结一下今天是什么意思？",
      "总结一下今天好吗？",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
    }
  }

  func testRemovedReviewRequestUsesOrdinaryUncertainRouting() {
    XCTAssertEqual(ChatRouting.intent("Review today"), .unsure)
    XCTAssertFalse(ChatRouting.isSupportedOperationRequest("Review today"))
  }

  func testEnglishRequestBoundaryDoesNotDependOnTitleLanguage() {
    for text in ["Did you remind me to 买牛奶?", "You said add a reminder for 买牛奶"] {
      XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
    }
    for text in [
      "Remind me to 买牛奶 tomorrow", "Can you add a reminder for 买牛奶?",
      "7点提醒我买牛奶", "可以明天提醒我买牛奶吗？",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
    }
  }

  func testOperationBoundaryRequiresCompleteSupportedRequest() {
    for text in [
      "Could you tidy my 2 overdue reminders?", "Tidy 2 overdue", "整理2条过期提醒",
    ] {
      XCTAssertTrue(ChatRouting.isSupportedOperationRequest(text), text)
      XCTAssertTrue(
        OverdueTidy.isRequest(text),
        "Must reach an existing handler: \(text)")
    }
    for text in [
      "Does plan my day move events at 5pm?", "How does Plan my day work?",
      "Can you explain tidy overdue?", "Did you plan my day?",
      "Can you plan my day without asking?", "总结一下今天是什么意思？",
      "Review today", "总结一下今天好吗？", "Could you review tomorrow?", "Can you tidy my overdue?",
    ] {
      XCTAssertFalse(ChatRouting.isSupportedOperationRequest(text), text)
    }
    for text in [
      "Would you remind me to call Mom?", "Please add a reminder for tomorrow",
      "Don't forget to pay rent tomorrow", "Set a reminder for 7am",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
    }
    XCTAssertEqual(ChatRouting.intent("Would you write a story?"), .conversation)
    XCTAssertEqual(ChatRouting.intent("Would you remind me to write a story tomorrow?"), .capture)
  }

  func testContextualTimeAnswersRequireOpenTimeContext() throws {
    let now = Date(timeIntervalSince1970: 1_792_000_000)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    for text in [
      "How about 5pm?", "What about tomorrow at 5pm?", "下午5点，可以吗？", "明天下午5点好吗？", "5pm", "改成下午4点",
    ] {
      XCTAssertNil(
        ChatRouting.contextualTimeAnswer(text, hasTimeContext: false, now: now, calendar: cal), text
      )
      let answer = try XCTUnwrap(
        ChatRouting.contextualTimeAnswer(text, hasTimeContext: true, now: now, calendar: cal), text)
      XCTAssertNotNil(Dialogue.answerTime(answer, keeping: now, now: now, calendar: cal), text)
      let preview = Capture(title: "Call Alex", day: now, hasDay: true, hour: 15)
      guard
        case .updated(let edited) = Dialogue.refine(preview, with: answer, now: now, calendar: cal)
      else {
        return XCTFail("Time answer must reuse preview refinement: \(text)")
      }
      XCTAssertEqual(edited.title, preview.title)
      XCTAssertEqual(edited.hour, text.contains("4") ? 16 : 17)
    }
  }

  func testConversationWithTimeDoesNotQualifyAsContextualAnswer() {
    for text in [
      "Did I set an alarm for 7am?", "Can you show me how to set an alarm for 7am?",
      "Don't wake me at 7am, okay?", "我是不是设了7点的闹钟？",
      "不要早上7点叫醒我，好吗？", "I am meeting friends at 5pm",
      "我今天下午5点很累，想聊聊", "Thanks for explaining the alarm at 7am",
      "How about telling me a story at 5pm?", "下午5点的会议是什么？",
      "Did the Dentist appointment end at 5pm?", "Is 5pm free?",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
      let answer = ChatRouting.contextualTimeAnswer(text, hasTimeContext: true)
      XCTAssertNil(answer, text)
    }
  }

  func testUnknownInputDoesNotDefaultToCapture() {
    for text in [
      "I want to talk about tomorrow's meeting", "我想聊明天的会议", "some thoughts", "测试",
      "Perhaps a new hobby", "2026-10-20", "tomorrow at 3pm",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .unsure, text)
    }
  }

  func testRelativeTimeImperativesReachCaptureWithTheirOwnAction() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23, minute: 45))!
    for (text, title) in [
      ("30分钟后关烤箱", "关烤箱"),
      ("半小时后关烤箱", "关烤箱"),
      ("In 30 minutes turn off the oven", "turn off the oven"),
      ("After thirty minutes call Alex", "call Alex"),
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
      let parsed = CaptureParser.parse(text, now: now, calendar: cal)
      XCTAssertEqual(parsed.title, title, text)
      XCTAssertEqual(parsed.kind, .task, text)
      XCTAssertFalse(parsed.ringsAsAlarm, text)
      XCTAssertTrue(parsed.hasDay, text)
      XCTAssertEqual(parsed.day, cal.startOfDay(for: now.addingTimeInterval(1800)), text)
      XCTAssertEqual(parsed.hour, 0, text)
      XCTAssertEqual(parsed.minute, 15, text)
      XCTAssertNil(
        ChatRouting.contextualTimeAnswer(text, hasTimeContext: true, now: now, calendar: cal), text)
      XCTAssertNil(Dialogue.answerTime(text, keeping: now, now: now, calendar: cal), text)
      let pending = Capture(title: "Call Mom", day: now, hasDay: true, hour: 9)
      XCTAssertEqual(
        Dialogue.refine(pending, with: text, now: now, calendar: cal), .notARefinement, text)
    }
  }

  func testRelativeTimeNarrativesAndQuestionsStayConversation() {
    for text in [
      "In 30 minutes I am turning off the oven", "30分钟后我在关烤箱",
      "Should I turn off the oven in 30 minutes?", "30分钟后关烤箱可以吗？",
      "What happens if I turn off the oven in 30 minutes?", "30分钟后关烤箱是什么意思？",
      "I already turned off the oven", "我已经关烤箱了",
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .conversation, text)
    }
    for text in ["in 30 minutes", "30分钟后", "30分钟后的天气"] {
      XCTAssertNotEqual(ChatRouting.intent(text), .capture, text)
    }
  }

}
