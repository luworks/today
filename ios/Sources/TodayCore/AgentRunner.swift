import Foundation

/// One function call from the model.
public struct AgentToolCall: Equatable, Sendable {
  public var callID: String
  public var name: String
  public var arguments: String

  public init(callID: String, name: String, arguments: String) {
    self.callID = callID
    self.name = name
    self.arguments = arguments
  }

  public var tool: AgentTool? { AgentTool(rawValue: name) }
  /// The parsed arguments (strict schemas always send an object).
  public var args: JSONValue { JSONValue.parse(arguments) ?? [:] }
}

/// What a tool returns to the model, and how many cards it put on screen.
public struct AgentToolOutcome: Equatable, Sendable {
  public var output: String
  public var cards: Int

  public init(output: String, cards: Int = 0) {
    self.output = output
    self.cards = cards
  }

  public init(_ json: JSONValue, cards: Int = 0) {
    self.init(output: json.text, cards: cards)
  }

  public static func error(_ code: String, _ message: String) -> AgentToolOutcome {
    AgentToolOutcome(["error": .string(code), "message": .string(message)])
  }
}

/// Executes the twelve tools on the phone. Reads return data; writes only prepare a card through
/// ActionPolicy and the code-owned write layer, and never write (§1.1, §4.1).
@MainActor
public protocol AgentToolbox: AnyObject {
  func run(_ call: AgentToolCall) async -> AgentToolOutcome
}

public struct AgentRunResult: Equatable, Sendable {
  public enum Stop: Equatable, Sendable {
    case finished, stepCap, deadline, cancelled
    case failed(ModelClientError)
  }

  /// Items to append to the conversation's history: the user message, every output item verbatim
  /// and each tool output. Empty when the run failed before any step completed (the draft is kept).
  public var items: [JSONValue] = []
  /// What to show under the user's message; code-written when the model's words can't be used.
  public var reply = ""
  /// The model's own final text, before `AgentReply` checked it.
  public var modelText = ""
  public var steps = 0
  public var usage: [AgentUsage] = []
  public var stop: Stop = .finished
  /// Seconds from the start of the run to the first card on screen.
  public var firstCard: TimeInterval?
  public var duration: TimeInterval = 0
  public var cards = 0
  /// Tool names in call order (for the run log).
  public var calls: [String] = []

  public var costMicros: Int { usage.reduce(0) { $0 + $1.costMicros } }
  public var failed: ModelClientError? {
    if case .failed(let e) = stop { return e }
    return nil
  }
}

/// The agent loop (§1.1 ②): send the history, run the tools the model calls, send their outputs
/// back, until the model replies in plain text or the run reaches 6 steps or 30 seconds.
/// Read tools run concurrently; a card shows as soon as its call is complete, before the step ends.
@MainActor
public final class AgentRunner {
  private let client: any ModelClient
  private let toolbox: any AgentToolbox
  private let maxSteps: Int
  private let deadline: TimeInterval
  private let clock: () -> Date

  public init(
    client: any ModelClient, toolbox: any AgentToolbox, maxSteps: Int = AgentContract.maxSteps,
    deadline: TimeInterval = AgentContract.runDeadline, clock: @escaping () -> Date = Date.init
  ) {
    self.client = client
    self.toolbox = toolbox
    self.maxSteps = maxSteps
    self.deadline = deadline
    self.clock = clock
  }

  @MainActor private final class State {
    var result = AgentRunResult()
    var timedOut = false
    var lastWrite: Task<Void, Never>?
  }

  /// `message` is the full last user message (the user's words plus the turn context).
  public func run(
    history: [JSONValue], message: String, runID: String, chinese: Bool
  ) async -> AgentRunResult {
    let started = clock()
    let state = State()
    let loop = Task { @MainActor in
      await self.loop(history: history, message: message, runID: runID, state: state, t0: started)
    }
    let seconds = deadline
    let timer = Task { @MainActor in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      state.timedOut = true
      loop.cancel()
    }
    await withTaskCancellationHandler {
      await loop.value
    } onCancel: {
      loop.cancel()
    }
    timer.cancel()
    var r = state.result
    r.duration = clock().timeIntervalSince(started)
    switch r.stop {
    case .finished:
      r.reply = AgentReply.finalize(r.modelText, cards: r.cards, chinese: chinese)
    case .stepCap, .deadline, .cancelled:
      r.reply = AgentReply.unfinished(cards: r.cards, chinese: chinese)
    case .failed(let e):
      r.reply =
        r.cards > 0
        ? AgentReply.unfinished(cards: r.cards, chinese: chinese)
        : AgentReply.unavailable(e, chinese: chinese)
    }
    return r
  }

  private func loop(
    history: [JSONValue], message: String, runID: String, state: State, t0: Date
  ) async {
    var newItems: [JSONValue] = [AgentItem.userMessage(message)]
    defer {
      // A run that never completed a step leaves no trace in the history: the draft is retried as new.
      state.result.items = state.result.usage.isEmpty ? [] : newItems
    }
    for step in 1...maxSteps {
      state.result.steps = step
      var started: [String: Task<AgentToolOutcome, Never>] = [:]
      var text = ""
      var output: [JSONValue]?
      do {
        let stream = client.respond(AgentRequest(input: history + newItems, runID: runID))
        for try await event in stream {
          try Task.checkCancellation()
          switch event {
          case .functionCall(let id, let name, let arguments):
            let call = AgentToolCall(callID: id, name: name, arguments: arguments)
            if started[id] == nil { started[id] = start(call, state: state, t0: t0) }
          case .textDelta(let delta): text += delta
          case .completed(let items, let usage):
            output = items
            state.result.usage.append(usage ?? AgentUsage(input: 0, output: 0))
          }
        }
        try Task.checkCancellation()
      } catch {
        state.result.stop = stopReason(error, state: state)
        return
      }
      guard let output else {
        state.result.stop = .failed(.incomplete)
        return
      }
      newItems += output
      let calls = output.filter { AgentItem.type($0) == "function_call" }.compactMap {
        item -> AgentToolCall? in
        guard let id = item["call_id"]?.string, let name = item["name"]?.string else { return nil }
        return AgentToolCall(callID: id, name: name, arguments: item["arguments"]?.string ?? "{}")
      }
      if calls.isEmpty {
        let said = output.filter { AgentItem.role($0) == "assistant" }.compactMap(AgentItem.text)
          .joined(separator: "\n")
        state.result.modelText = said.isEmpty ? text : said
        state.result.stop = .finished
        return
      }
      for call in calls {
        let task = started[call.callID] ?? start(call, state: state, t0: t0)
        started[call.callID] = task
        let outcome = await task.value
        newItems.append(AgentItem.functionCallOutput(callID: call.callID, output: outcome.output))
      }
      if Task.isCancelled {
        state.result.stop = state.timedOut ? .deadline : .cancelled
        return
      }
      if step == maxSteps { state.result.stop = .stepCap }
    }
  }

  /// Starts a tool as soon as its call is complete. Reads run side by side; writes run one after
  /// another in call order so cards appear in the order the model proposed them.
  private func start(_ call: AgentToolCall, state: State, t0: Date) -> Task<AgentToolOutcome, Never>
  {
    state.result.calls.append(call.name)
    let isWrite = call.tool?.isWrite ?? false
    let previous = isWrite ? state.lastWrite : nil
    let toolbox = self.toolbox
    let clock = self.clock
    let task = Task { @MainActor () -> AgentToolOutcome in
      await previous?.value
      let outcome: AgentToolOutcome
      if call.tool == nil {
        outcome = .error("unknown_tool", "No tool named \(call.name).")
      } else {
        outcome = await toolbox.run(call)
      }
      if outcome.cards > 0 {
        state.result.cards += outcome.cards
        if state.result.firstCard == nil {
          state.result.firstCard = clock().timeIntervalSince(t0)
        }
      }
      return outcome
    }
    if isWrite { state.lastWrite = Task { _ = await task.value } }
    return task
  }

  private func stopReason(_ error: any Error, state: State) -> AgentRunResult.Stop {
    if state.timedOut { return .deadline }
    if error is CancellationError || Task.isCancelled { return .cancelled }
    if let e = error as? ModelClientError { return .failed(e) }
    if error is URLError { return .failed(.network) }
    return .failed(.network)
  }
}
