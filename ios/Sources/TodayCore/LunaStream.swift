import Foundation

/// Turns the Worker's SSE pass-through of an OpenAI Responses stream into `AgentEvent`s.
/// Pure and incremental: feed it lines as they arrive (`HostedLunaClient`), or a whole body in tests.
public struct LunaStreamDecoder: Sendable {
  /// Function call items announced by `response.output_item.added`, by item id.
  private var pending: [String: (callID: String, name: String)] = [:]
  private var emitted: Set<String> = []
  private var data: [String] = []
  public private(set) var finished = false

  public init() {}

  /// One SSE line (without its newline). Returns the events it completes.
  public mutating func feed(line raw: String) throws -> [AgentEvent] {
    let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
    if line.isEmpty {
      defer { data = [] }
      guard !data.isEmpty else { return [] }
      return try decode(data.joined(separator: "\n"))
    }
    if line.hasPrefix("data:") {
      var value = line.dropFirst(5)
      if value.first == " " { value = value.dropFirst() }
      data.append(String(value))
    }
    // `event:`, `id:`, `retry:` and comments carry nothing the JSON payload doesn't.
    return []
  }

  /// Flushes a final event that had no trailing blank line.
  public mutating func finish() throws -> [AgentEvent] {
    guard !data.isEmpty else { return [] }
    defer { data = [] }
    return try decode(data.joined(separator: "\n"))
  }

  private mutating func decode(_ payload: String) throws -> [AgentEvent] {
    guard payload != "[DONE]", let event = JSONValue.parse(payload) else { return [] }
    switch event["type"]?.string {
    case "response.output_item.added":
      if let item = event["item"], item["type"]?.string == "function_call",
        let id = item["id"]?.string, let callID = item["call_id"]?.string,
        let name = item["name"]?.string
      {
        pending[id] = (callID, name)
      }
      return []
    case "response.function_call_arguments.done":
      guard let id = event["item_id"]?.string, let args = event["arguments"]?.string,
        let call = pending[id], !emitted.contains(call.callID)
      else { return [] }
      emitted.insert(call.callID)
      return [.functionCall(callID: call.callID, name: call.name, arguments: args)]
    case "response.output_item.done":
      // Fallback when the arguments event was not seen.
      guard let item = event["item"], item["type"]?.string == "function_call",
        let callID = item["call_id"]?.string, let name = item["name"]?.string,
        let args = item["arguments"]?.string, !emitted.contains(callID)
      else { return [] }
      emitted.insert(callID)
      return [.functionCall(callID: callID, name: name, arguments: args)]
    case "response.output_text.delta":
      return event["delta"]?.string.map { [.textDelta($0)] } ?? []
    case "response.completed":
      finished = true
      let response = event["response"]
      return [
        .completed(output: response?["output"]?.array ?? [], usage: AgentUsage(response?["usage"]))
      ]
    case "response.incomplete", "response.failed", "error":
      finished = true
      throw ModelClientError.incomplete
    default:
      return []
    }
  }

  /// Maps a Worker error body and HTTP status to the client error the runner understands.
  public static func failure(status: Int, body: Data) -> ModelClientError {
    let code = (try? JSONDecoder().decode(JSONValue.self, from: body))?["error"]?.string ?? ""
    switch status {
    case 401, 403: return .unavailable
    case 429: return .quota(code.isEmpty ? "rate_limit" : code)
    case 400 where code == "upstream_rejected": return .replayRejected
    case 502, 503, 504: return .network
    default: return .rejected(code.isEmpty ? "http_\(status)" : code)
    }
  }
}
