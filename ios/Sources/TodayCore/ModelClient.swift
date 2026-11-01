import Foundation

/// One agent step sent to a model (docs/engineering/ai-agent-architecture.md §1.2). The Worker owns
/// the prompt, tools and model; the client sends only the replayed items, the tool version and the run.
public struct AgentRequest: Equatable, Sendable {
  public var input: [JSONValue]
  public var runID: String
  public var toolsVersion: String

  public init(input: [JSONValue], runID: String, toolsVersion: String = AgentContract.toolsVersion)
  {
    self.input = input
    self.runID = runID
    self.toolsVersion = toolsVersion
  }
}

/// The contract this build speaks (`backend/luna/agent-v1.mjs`).
public enum AgentContract {
  public static let toolsVersion = "v1"
  public static let model = "gpt-6-luna"
  /// Worker cap per run (`run_step_limit`); the client stops first.
  public static let maxSteps = 6
  /// Client deadline for a whole run, in seconds (§4.2).
  public static let runDeadline: TimeInterval = 30
}

/// Token usage of one step, as reported in `response.completed`.
public struct AgentUsage: Equatable, Sendable {
  public var input: Int
  public var cached: Int
  public var output: Int

  public init(input: Int, cached: Int = 0, output: Int) {
    self.input = input
    self.cached = cached
    self.output = output
  }

  public init?(_ json: JSONValue?) {
    guard let json, let input = json["input_tokens"]?.int, let output = json["output_tokens"]?.int
    else { return nil }
    self.init(
      input: input, cached: min(json["input_tokens_details"]?["cached_tokens"]?.int ?? 0, input),
      output: output)
  }

  /// Micro-dollars at the Worker's rates (backend/luna/README.md): uncached input $0.10/M,
  /// cached input $0.01/M, output including reasoning $0.50/M, rounded up per step.
  public var costMicros: Int {
    let units = (input - cached) * 10 + cached + output * 50
    return (units + 99) / 100
  }
}

/// What a model step streams back.
public enum AgentEvent: Equatable, Sendable {
  /// A complete function call (`response.function_call_arguments.done`): the card can show now.
  case functionCall(callID: String, name: String, arguments: String)
  case textDelta(String)
  /// `response.completed`: every output item, verbatim, and the step's usage.
  case completed(output: [JSONValue], usage: AgentUsage?)
}

public enum ModelClientError: Error, Equatable, Sendable {
  /// No AI account, consent or endpoint: the agent can't run at all.
  case unavailable
  /// The network failed or timed out.
  case network
  /// Daily runs, per-run steps, rate or budget limits (HTTP 429).
  case quota(String)
  /// OpenAI rejected the replayed items before generating (Worker `upstream_rejected`).
  case replayRejected
  /// The step finished as `incomplete` / `failed`, or the stream ended early.
  case incomplete
  /// Any other refusal from the Worker.
  case rejected(String)
}

/// Every model call goes through this (§0, §1.2). v1 has `HostedLunaClient`; tests use `ScriptedModelClient`.
public protocol ModelClient: Sendable {
  func respond(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, any Error>
}

/// Replays scripted steps, for tests and offline development. Records every request it was sent.
public final class ScriptedModelClient: ModelClient, @unchecked Sendable {
  public enum Step: Sendable {
    /// Function calls (emitted as soon as each is complete) and an optional final text.
    case respond(calls: [Call], text: String?, usage: AgentUsage?, delay: Duration)
    case fail(ModelClientError)
  }

  public struct Call: Equatable, Sendable {
    public var name: String
    public var arguments: JSONValue
    public var callID: String

    public init(_ name: String, _ arguments: JSONValue = [:], id: String? = nil) {
      self.name = name
      self.arguments = arguments
      self.callID = id ?? "call_\(name)_\(UUID().uuidString.prefix(6))"
    }
  }

  private let lock = NSLock()
  private var steps: [Step]
  private var sent: [AgentRequest] = []

  public init(_ steps: [Step]) { self.steps = steps }

  public static func calls(
    _ calls: [Call], usage: AgentUsage? = AgentUsage(input: 1800, cached: 1700, output: 40),
    delay: Duration = .zero
  ) -> Step {
    .respond(calls: calls, text: nil, usage: usage, delay: delay)
  }
  public static func reply(
    _ text: String, usage: AgentUsage? = AgentUsage(input: 1900, cached: 1700, output: 30),
    delay: Duration = .zero
  ) -> Step {
    .respond(calls: [], text: text, usage: usage, delay: delay)
  }

  public var requests: [AgentRequest] {
    lock.lock()
    defer { lock.unlock() }
    return sent
  }

  public func respond(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, any Error> {
    lock.lock()
    sent.append(request)
    let step: Step? = steps.isEmpty ? nil : steps.removeFirst()
    lock.unlock()
    return AsyncThrowingStream { continuation in
      let task = Task {
        guard let step else {
          continuation.finish(throwing: ModelClientError.incomplete)
          return
        }
        switch step {
        case .fail(let error):
          continuation.finish(throwing: error)
        case .respond(let calls, let text, let usage, let delay):
          if delay > .zero {
            do { try await Task.sleep(for: delay) } catch {
              continuation.finish(throwing: CancellationError())
              return
            }
          }
          var output: [JSONValue] = []
          for (i, call) in calls.enumerated() {
            let item: JSONValue = [
              "type": "function_call", "id": .string("fc_\(i)"), "call_id": .string(call.callID),
              "name": .string(call.name), "arguments": .string(call.arguments.text),
              "status": "completed",
            ]
            output.append(item)
            continuation.yield(
              .functionCall(callID: call.callID, name: call.name, arguments: call.arguments.text))
          }
          if let text {
            continuation.yield(.textDelta(text))
            output.append(AgentItem.assistantMessage(text))
          }
          continuation.yield(.completed(output: output, usage: usage))
          continuation.finish()
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
