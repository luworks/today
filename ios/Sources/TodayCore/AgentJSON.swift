import Foundation

/// A JSON value kept exactly as the Responses API sent it, so agent items (ids, `phase`,
/// `encrypted_content` …) replay verbatim (docs/engineering/ai-agent-architecture.md §1.5).
public enum JSONValue: Equatable, Hashable, Sendable, Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? c.decode(Double.self) {
      self = .number(n)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSONValue].self) {
      self = .array(a)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n):
      // Integers stay integers on the wire (token counts, indexes).
      if n.rounded() == n, abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  public subscript(key: String) -> JSONValue? {
    if case .object(let o) = self { return o[key] }
    return nil
  }

  public var string: String? {
    if case .string(let s) = self { return s }
    return nil
  }
  public var int: Int? {
    if case .number(let n) = self, n.rounded() == n { return Int(n) }
    return nil
  }
  public var bool: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }
  public var array: [JSONValue]? {
    if case .array(let a) = self { return a }
    return nil
  }
  public var isNull: Bool { self == .null }

  /// Compact JSON text (keys sorted, so equal values give equal text).
  public var text: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
  }

  public static func parse(_ text: String) -> JSONValue? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
  ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
  }
  public init(nilLiteral: ()) { self = .null }
}

/// Builders and readers for the Responses items the agent replays.
public enum AgentItem {
  public static func userMessage(_ text: String) -> JSONValue {
    ["role": "user", "content": .string(text)]
  }
  /// Assistant text in the shape the Worker accepts for replay (`output_text` parts).
  public static func assistantMessage(_ text: String) -> JSONValue {
    [
      "type": "message", "role": "assistant",
      "content": [["type": "output_text", "text": .string(text)]],
    ]
  }
  public static func functionCallOutput(callID: String, output: String) -> JSONValue {
    ["type": "function_call_output", "call_id": .string(callID), "output": .string(output)]
  }
  public static func functionCall(callID: String, name: String, arguments: String) -> JSONValue {
    [
      "type": "function_call", "call_id": .string(callID), "name": .string(name),
      "arguments": .string(arguments),
    ]
  }

  public static func type(_ item: JSONValue) -> String? {
    item["type"]?.string ?? (item["role"] != nil ? "message" : nil)
  }

  /// The text of a message item (string content or its text parts).
  public static func text(_ item: JSONValue) -> String? {
    guard type(item) == "message" else { return nil }
    if let s = item["content"]?.string { return s }
    return item["content"]?.array?.compactMap { $0["text"]?.string }.joined()
  }

  public static func role(_ item: JSONValue) -> String? { item["role"]?.string }
}
