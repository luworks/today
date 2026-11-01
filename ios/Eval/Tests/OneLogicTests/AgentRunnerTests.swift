import XCTest

@testable import TodayCore

/// The on-phone agent loop with a scripted model (docs/engineering/ai-agent-architecture.md §1.4, §3 O7).
@MainActor
final class AgentRunnerTests: XCTestCase {
  typealias Call = ScriptedModelClient.Call

  /// A toolbox that behaves like the planner's: reads return data, writes register a card in an
  /// `AgentProposalBook` and never write.
  final class Toolbox: AgentToolbox {
    var book = AgentProposalBook()
    var run = "run-1"
    var log: [String] = []
    var inFlight = 0
    var maxInFlight = 0
    var readDelay: Duration = .zero

    func run(_ call: AgentToolCall) async -> AgentToolOutcome {
      log.append(call.name)
      guard let tool = call.tool else { return .error("unknown_tool", call.name) }
      if !tool.isWrite {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if readDelay > .zero { try? await Task.sleep(for: readDelay) }
        inFlight -= 1
        return AgentToolOutcome(["items": [["id": "t17", "title": "[QA] Dentist"]]])
      }
      switch tool {
      case .reviseProposal:
        let id = call.args["proposal_id"]?.string ?? ""
        switch book.revisable(id) {
        case .success: return AgentToolOutcome(["proposal_id": .string(id), "status": "revised"])
        case .failure(.decided(let status, let item)):
          return AgentToolOutcome([
            "error": "proposal_decided", "status": .string(status.rawValue),
            "item_id": item.map(JSONValue.string) ?? .null,
          ])
        case .failure(.unknown): return .error("unknown_proposal", id)
        }
      case .proposeDelete:
        let id = book.open(
          tool: tool, kind: "event", tier: .confirmConsequence([.deletesEvent]), run: run)
        return AgentToolOutcome(["proposal_id": .string(id.id), "status": "shown"], cards: 1)
      default:
        let key = call.args["items"]?.text
        let opened = book.open(
          tool: tool, kind: "reminder", tier: .preview, itemID: call.args["id"]?.string,
          run: run, contentKey: tool == .proposeCreate ? key : nil)
        return AgentToolOutcome(
          ["proposal_id": .string(opened.id), "status": "shown"], cards: opened.duplicate ? 0 : 1)
      }
    }
  }

  private func runner(
    _ steps: [ScriptedModelClient.Step], toolbox: Toolbox = Toolbox(), maxSteps: Int = 6,
    deadline: TimeInterval = 30
  ) -> (AgentRunner, ScriptedModelClient, Toolbox) {
    let client = ScriptedModelClient(steps)
    return (
      AgentRunner(client: client, toolbox: toolbox, maxSteps: maxSteps, deadline: deadline),
      client, toolbox
    )
  }

  // MARK: The loop

  func testMultiStepLoopReplaysItemsAndShowsTwoCards() async {
    let (r, client, box) = runner([
      ScriptedModelClient.calls([Call("find_items", ["query": "牙医"], id: "c1")]),
      ScriptedModelClient.calls([
        Call("propose_edit", ["id": "t17", "when_text": "4点"], id: "c2"),
        Call("propose_create", ["items": [["kind": "reminder", "title": "买牛奶"]]], id: "c3"),
      ]),
      ScriptedModelClient.reply("准备好了两张卡，点了才会生效。"),
    ])
    let result = await r.run(
      history: [], message: "把牙医改到4点，顺便提醒我买牛奶", runID: "run-1", chinese: true)
    XCTAssertEqual(result.stop, .finished)
    XCTAssertEqual(result.steps, 3)
    XCTAssertEqual(result.cards, 2)
    XCTAssertNotNil(result.firstCard)
    XCTAssertEqual(box.log, ["find_items", "propose_edit", "propose_create"])
    XCTAssertEqual(result.reply, "准备好了两张卡，点了才会生效。")
    // Each step replays everything before it, verbatim, with the outputs right after their calls.
    XCTAssertEqual(client.requests.count, 3)
    XCTAssertTrue(client.requests.allSatisfy { $0.runID == "run-1" && $0.toolsVersion == "v1" })
    let third = client.requests[2].input
    XCTAssertEqual(
      third.map { AgentItem.type($0) },
      [
        "message", "function_call", "function_call_output", "function_call", "function_call",
        "function_call_output", "function_call_output",
      ])
    XCTAssertEqual(third[2]["call_id"], "c1")
    XCTAssertEqual(result.items.count, third.count + 1)
    XCTAssertEqual(result.usage.count, 3)
    XCTAssertEqual(result.costMicros, result.usage.map(\.costMicros).reduce(0, +))
  }

  func testHistoryComesFirstAndTheUserMessageCarriesTheContext() async {
    let history = [AgentItem.userMessage("earlier"), AgentItem.assistantMessage("ok")]
    let (r, client, _) = runner([ScriptedModelClient.reply("Hi.")])
    _ = await r.run(
      history: history, message: "hello\n\n[Context] now: 2026-11-01", runID: "r", chinese: false)
    let input = client.requests[0].input
    XCTAssertEqual(Array(input.prefix(2)), history)
    XCTAssertEqual(AgentItem.text(input[2]), "hello\n\n[Context] now: 2026-11-01")
    XCTAssertFalse(
      input.contains { AgentItem.role($0) == "system" || AgentItem.role($0) == "developer" })
  }

  func testReadToolsRunInParallel() async {
    let box = Toolbox()
    box.readDelay = .milliseconds(80)
    let (r, _, _) = runner(
      [
        ScriptedModelClient.calls([
          Call("get_agenda", ["start": "tomorrow", "end": "tomorrow", "kinds": []], id: "a"),
          Call("free_time", ["day": "tomorrow", "min_minutes": 30], id: "b"),
          Call("list_lists", [:], id: "c"),
        ]),
        ScriptedModelClient.reply("You have one event tomorrow."),
      ], toolbox: box)
    let result = await r.run(history: [], message: "我明天有什么安排？", runID: "r", chinese: true)
    XCTAssertEqual(box.maxInFlight, 3, "all three reads were in flight together")
    XCTAssertEqual(result.cards, 0)
    XCTAssertEqual(result.reply, "You have one event tomorrow.")
  }

  func testTheRunStopsAtSixStepsAndSaysItIsUnfinished() async {
    let looping = (1...8).map { i in
      ScriptedModelClient.calls([Call("find_items", ["query": .string("x\(i)")], id: "c\(i)")])
    }
    let (r, client, _) = runner(looping)
    let result = await r.run(history: [], message: "loop", runID: "r", chinese: true)
    XCTAssertEqual(result.stop, .stepCap)
    XCTAssertEqual(result.steps, 6)
    XCTAssertEqual(client.requests.count, 6, "the Worker would refuse a 7th step")
    XCTAssertEqual(result.reply, AgentReply.unfinished(cards: 0, chinese: true))
    // Every call has its output, so the history stays replayable.
    let calls = result.items.filter { AgentItem.type($0) == "function_call" }.count
    let outputs = result.items.filter { AgentItem.type($0) == "function_call_output" }.count
    XCTAssertEqual(calls, outputs)
  }

  func testTheDeadlineStopsARunAndKeepsItsCards() async {
    let (r, _, box) = runner(
      [
        ScriptedModelClient.calls([
          Call("propose_create", ["items": [["kind": "reminder", "title": "Milk"]]], id: "c1")
        ]),
        ScriptedModelClient.reply("slow", delay: .seconds(5)),
      ], deadline: 0.3)
    let result = await r.run(history: [], message: "milk", runID: "r", chinese: false)
    XCTAssertEqual(result.stop, .deadline)
    XCTAssertEqual(result.cards, 1)
    XCTAssertTrue(box.book.hasOpen)
    XCTAssertEqual(result.reply, AgentReply.unfinished(cards: 1, chinese: false))
    XCTAssertLessThan(result.duration, 3)
  }

  func testAFailedFirstStepLeavesNoHistoryAndKeepsTheDraft() async {
    let (r, _, _) = runner([.fail(.network)])
    let result = await r.run(history: [], message: "offline", runID: "r", chinese: true)
    XCTAssertEqual(result.stop, .failed(.network))
    XCTAssertTrue(result.items.isEmpty)
    XCTAssertEqual(result.reply, AgentReply.unavailable(.network, chinese: true))
    XCTAssertTrue(result.reply.contains("草稿"))
  }

  func testAnUnknownToolGetsAnErrorOutputNotACrash() async {
    let (r, client, _) = runner([
      ScriptedModelClient.calls([Call("send_email", ["to": "x"], id: "c1")]),
      ScriptedModelClient.reply("I can't send email."),
    ])
    let result = await r.run(history: [], message: "email Alex", runID: "r", chinese: false)
    XCTAssertEqual(result.stop, .finished)
    let output = client.requests[1].input.last
    XCTAssertEqual(AgentItem.type(output!), "function_call_output")
    XCTAssertTrue(output?["output"]?.string?.contains("unknown_tool") ?? false)
  }

  // MARK: The reply can't claim a write

  func testTheReplyCanNeverClaimItIsDone() async {
    for claim in [
      "I've added the reminder.", "Done! Moved to 4pm.", "The dentist has been moved to 4.",
      "已帮你添加买牛奶的提醒。", "已经把牙医改到4点了", "设置好了", "搞定！",
    ] {
      let (r, _, _) = runner([
        ScriptedModelClient.calls([
          Call("propose_create", ["items": [["kind": "reminder", "title": "Milk"]]], id: "c1")
        ]),
        ScriptedModelClient.reply(claim),
      ])
      let chinese = AgentReply.isChinese(claim)
      let result = await r.run(history: [], message: claim, runID: "r", chinese: chinese)
      XCTAssertEqual(result.reply, AgentReply.cardsReady(1, chinese: chinese), claim)
      XCTAssertEqual(result.modelText, claim)
    }
  }

  func testOrdinaryAnswersAreKept() {
    for answer in [
      "你明天有两个安排：上午10点的会议和下午3点的牙医。", "A card is ready to move your dentist appointment to 4pm.",
      "You have nothing scheduled tomorrow.", "卡片准备好了，你点 Add 才会添加。",
    ] {
      XCTAssertFalse(AgentReply.claimsDone(answer), answer)
      XCTAssertEqual(AgentReply.finalize(answer, cards: 1, chinese: true), answer)
    }
    XCTAssertEqual(AgentReply.finalize("", cards: 0, chinese: false), "Nothing was changed.")
  }

  // MARK: Cards

  func testReviseProposalOnADecidedCardFailsWithTheItemID() async {
    let box = Toolbox()
    let first = box.book.open(tool: .proposeCreate, kind: "reminder", tier: .preview, run: "r0")
    box.book.set(first.id, status: .added, itemID: "t7")
    let (r, client, _) = runner(
      [
        ScriptedModelClient.calls([
          Call("revise_proposal", ["proposal_id": .string(first.id), "when_text": "5点"], id: "c1")
        ]),
        ScriptedModelClient.calls([Call("propose_edit", ["id": "t7", "when_text": "5点"], id: "c2")]
        ),
        ScriptedModelClient.reply("卡片准备好了。"),
      ], toolbox: box)
    let result = await r.run(history: [], message: "其实是5点", runID: "r1", chinese: true)
    let output = JSONValue.parse(client.requests[1].input.last?["output"]?.string ?? "")
    XCTAssertEqual(output?["error"], "proposal_decided")
    XCTAssertEqual(output?["status"], "added")
    XCTAssertEqual(output?["item_id"], "t7")
    XCTAssertEqual(box.log, ["revise_proposal", "propose_edit"])
    XCTAssertEqual(result.cards, 1)
    XCTAssertEqual(box.book.entry("p2")?.itemID, "t7")
    XCTAssertEqual(box.book.entry(first.id)?.status, .added, "the decided card is untouched")
  }

  func testReviseProposalOnAnOpenCardIsAllowed() {
    var book = AgentProposalBook()
    let p = book.open(tool: .proposeCreate, kind: "reminder", tier: .preview, run: "r")
    if case .failure = book.revisable(p.id) { XCTFail("open cards are revisable") }
    XCTAssertEqual(book.revisable("p9"), .failure(.unknown))
    for status in [AgentProposalBook.Status.added, .applied, .dropped, .undone, .void] {
      book.set(p.id, status: status)
      XCTAssertEqual(book.revisable(p.id), .failure(.decided(status, itemID: nil)))
    }
  }

  func testConfirmConsequenceCardsAreExcludedFromAddAll() async {
    let (r, _, box) = runner([
      ScriptedModelClient.calls([
        Call("propose_create", ["items": [["kind": "reminder", "title": "Milk"]]], id: "c1"),
        Call("propose_delete", ["id": "e1", "scope": "this"], id: "c2"),
        Call("propose_create", ["items": [["kind": "reminder", "title": "Bread"]]], id: "c3"),
      ]),
      ScriptedModelClient.reply("Three cards are ready."),
    ])
    box.run = "run-1"
    let result = await r.run(history: [], message: "x", runID: "run-1", chinese: false)
    XCTAssertEqual(result.cards, 3)
    XCTAssertEqual(box.book.entries.map(\.id), ["p1", "p2", "p3"])
    XCTAssertEqual(box.book.addAll(), ["p1", "p3"])
    XCTAssertEqual(box.book.addAll(run: "run-1"), ["p1", "p3"])
    XCTAssertFalse(box.book.entry("p2")!.tier.allowsAddAll)
  }

  func testTheSameCreateTwiceInOneRunIsOneCard() async {
    let item: JSONValue = ["items": [["kind": "reminder", "title": "Milk"]]]
    let (r, _, box) = runner([
      ScriptedModelClient.calls([Call("propose_create", item, id: "c1")]),
      ScriptedModelClient.calls([Call("propose_create", item, id: "c2")]),
      ScriptedModelClient.reply("A card is ready."),
    ])
    let result = await r.run(history: [], message: "milk", runID: "run-1", chinese: false)
    XCTAssertEqual(result.cards, 1)
    XCTAssertEqual(box.book.entries.count, 1)
  }

  func testAStaleCardIsVoidedAtApply() {
    // Shown as a preview; by Apply the reminder changed under it (§4.2): the recheck voids the card.
    var book = AgentProposalBook()
    let p = book.open(tool: .proposeEdit, kind: "reminder", tier: .preview, itemID: "t3", run: "r")
    let now = ActionPolicy.Request(
      tool: .proposeEdit, source: .agent, kind: .reminder, fields: [.due],
      changedSincePreview: true)
    XCTAssertEqual(ActionPolicy.recheck(shown: .preview, now: now), .void(.changedSincePreview))
    book.set(p.id, status: .void)
    XCTAssertFalse(book.hasOpen)
    XCTAssertEqual(book.addAll(), [])
    // Attendees added since the card was shown: confirm again rather than apply.
    let louder = ActionPolicy.Request(
      tool: .proposeEdit, source: .agent, kind: .event, fields: [.start],
      userAskedToMoveEvent: true, attendees: 3)
    XCTAssertEqual(
      ActionPolicy.recheck(shown: .preview, now: louder),
      .reconfirm(.confirmConsequence([.notifies(attendees: 3)])))
  }

  // MARK: Routing

  func testFastLaneRunsFirstAndCorrectionsGoToOpenAgentCards() {
    let capture = Capture(title: "交房租", day: Date(), hasDay: true, hour: 15)
    XCTAssertFalse(AgentRouting.useAgent(.directReminder(capture), agentHasOpenCards: true))
    XCTAssertTrue(AgentRouting.useAgent(.notFastLane, agentHasOpenCards: false))
    XCTAssertTrue(AgentRouting.useAgent(.clarifyCorrection, agentHasOpenCards: true))
    XCTAssertFalse(AgentRouting.useAgent(.clarifyCorrection, agentHasOpenCards: false))
    XCTAssertTrue(
      AgentRouting.useAgent(.continuation(capture, direct: true), agentHasOpenCards: true))
    XCTAssertFalse(
      AgentRouting.useAgent(.continuation(capture, direct: false), agentHasOpenCards: false))
  }

  func testOnlyTheUsersOwnWordsAskToMoveAMeeting() {
    for text in ["把会议改到4点", "推迟牙医", "move the standup to 3", "reschedule lunch", "其实是5点"] {
      XCTAssertTrue(AgentRouting.userAskedToMove(text), text)
    }
    for text in ["我明天有什么安排？", "提醒我买牛奶", "what's on tomorrow", "delete the dentist"] {
      XCTAssertFalse(AgentRouting.userAskedToMove(text), text)
    }
  }
}

/// The SSE decoder, history storage and accounting.
final class AgentStreamAndHistoryTests: XCTestCase {
  func testTheStreamYieldsACardAsSoonAsItsArgumentsAreDone() throws {
    let body = """
      event: response.created
      data: {"type":"response.created","response":{"id":"resp_1"}}

      event: response.output_item.added
      data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"propose_create","arguments":""}}

      event: response.function_call_arguments.delta
      data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"items\\":[]}"}

      event: response.function_call_arguments.done
      data: {"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\\"items\\":[]}"}

      event: response.output_item.done
      data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"propose_create","arguments":"{\\"items\\":[]}"}}

      event: response.completed
      data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","id":"fc_1","call_id":"call_1","name":"propose_create","arguments":"{\\"items\\":[]}","status":"completed"}],"usage":{"input_tokens":1828,"input_tokens_details":{"cached_tokens":1757},"output_tokens":40}}}

      """
    var decoder = LunaStreamDecoder()
    var events: [AgentEvent] = []
    for line in body.components(separatedBy: "\n") { events += try decoder.feed(line: line) }
    events += try decoder.finish()
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(
      events.first,
      .functionCall(callID: "call_1", name: "propose_create", arguments: #"{"items":[]}"#))
    guard case .completed(let output, let usage)? = events.last else { return XCTFail() }
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0]["call_id"], "call_1")
    XCTAssertEqual(usage, AgentUsage(input: 1828, cached: 1757, output: 40))
    XCTAssertTrue(decoder.finished)
  }

  func testAFailedOrIncompleteStepThrows() {
    var decoder = LunaStreamDecoder()
    XCTAssertThrowsError(
      try decoder.feed(line: #"data: {"type":"response.incomplete","response":{}}"#)
        + decoder.feed(line: ""))
  }

  func testWorkerErrorsMapToClientErrors() {
    func body(_ code: String) -> Data { Data(#"{"error":"\#(code)"}"#.utf8) }
    XCTAssertEqual(
      LunaStreamDecoder.failure(status: 401, body: body("sign_in_required")), .unavailable)
    XCTAssertEqual(
      LunaStreamDecoder.failure(status: 429, body: body("run_quota")), .quota("run_quota"))
    XCTAssertEqual(
      LunaStreamDecoder.failure(status: 400, body: body("upstream_rejected")), .replayRejected)
    XCTAssertEqual(
      LunaStreamDecoder.failure(status: 400, body: body("invalid_item")), .rejected("invalid_item"))
    XCTAssertEqual(LunaStreamDecoder.failure(status: 502, body: Data()), .network)
  }

  func testCostMatchesTheWorkerLedger() {
    // docs/qa/agent-p0-20261031.md: 1828 in / 1757 cached / 40 out → 45 µ$.
    XCTAssertEqual(AgentUsage(input: 1828, cached: 1757, output: 40).costMicros, 45)
    XCTAssertEqual(AgentUsage(input: 0, output: 0).costMicros, 0)
  }

  func testJSONValuesRoundTripVerbatim() throws {
    let raw =
      #"{"type":"reasoning","id":"rs_1","encrypted_content":"gAAA+/=","summary":[],"phase":"final","n":3,"x":1.5,"ok":true,"none":null}"#
    let value = try XCTUnwrap(JSONValue.parse(raw))
    let again = try XCTUnwrap(JSONValue.parse(value.text))
    XCTAssertEqual(value, again)
    XCTAssertEqual(value["encrypted_content"], "gAAA+/=")
    XCTAssertEqual(value["n"]?.int, 3)
    XCTAssertTrue(value.text.contains(#""n":3"#), "integers stay integers")
  }

  func testShortIDsAreStablePerConversationAndSurviveStorage() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var h = AgentHistory(now: now)
    XCTAssertEqual(h.shortID(for: "ref-a", prefix: "t"), "t1")
    XCTAssertEqual(h.shortID(for: "ref-b", prefix: "t"), "t2")
    XCTAssertEqual(h.shortID(for: "ref-c", prefix: "e"), "e1")
    XCTAssertEqual(h.shortID(for: "ref-a", prefix: "t"), "t1")
    h.appendReceipt(user: "明天下午3点提醒我交房租", receipt: "Added reminder t1 “交房租”.")
    let back = AgentHistory.restore(h.encoded, now: now)
    XCTAssertEqual(back, h)
    XCTAssertEqual(back.ref(for: "t2"), "ref-b")
    XCTAssertEqual(back.items.count, 2)
    let meta = String(data: h.encoded, encoding: .utf8) ?? ""
    XCTAssertTrue(
      meta.contains(#""tools_version":"v1""#) && meta.contains(#""model":"gpt-6-luna""#))
  }

  func testOldOrBrokenHistoryIsCompactedToTextAndReceipts() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertEqual(AgentHistory.restore(Data("garbage".utf8), now: now).items, [])
    var h = AgentHistory(now: now)
    _ = h.shortID(for: "ref-a", prefix: "t")
    h.items = [["type": "reasoning", "encrypted_content": "x"]]
    h.meta.toolsVersion = "v0"
    XCTAssertTrue(h.needsCompaction)
    h.compact(
      transcript: [(true, "提醒我买牛奶"), (false, "卡片准备好了。")],
      receipts: ["p1 reminder “买牛奶” added as t1"], now: now)
    XCTAssertFalse(h.needsCompaction)
    XCTAssertEqual(h.items.count, 3)
    XCTAssertTrue(h.items.allSatisfy { AgentItem.type($0) == "message" })
    XCTAssertEqual(h.ids["t1"], "ref-a", "short ids survive compaction")
    XCTAssertTrue(AgentItem.text(h.items[2])?.contains("t1") ?? false)
  }
}
