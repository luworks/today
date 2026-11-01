#if os(iOS)
  import Foundation
  import TodayCore
  import os

  /// `ModelClient` for the Luna Worker's agent mode: `POST /v1/responses` with `tools_version`,
  /// streamed as SSE (backend/luna/README.md "Agent mode"). The Worker fixes the model, prompt and
  /// tools; this client sends only `{input, tools_version, run_id, stream}`. No retries, no fallback.
  public struct HostedLunaClient: ModelClient {
    public struct Configuration: Sendable {
      public let endpoint: URL
      public let bearer: String

      public init(endpoint: URL, bearer: String) {
        self.endpoint = endpoint
        self.bearer = bearer
      }
    }

    private let configuration: @Sendable () -> Configuration?

    public init(configuration: @escaping @Sendable () -> Configuration? = Self.live) {
      self.configuration = configuration
    }

    /// The signed-in account with cloud upload consent; nil means the agent is unavailable.
    @Sendable public static func live() -> Configuration? {
      #if DEBUG && targetEnvironment(simulator)
        // QA only: an unreachable endpoint stands in for airplane mode (the Simulator has none).
        if ProcessInfo.processInfo.arguments.contains("-agentOffline") {
          return Configuration(
            endpoint: URL(string: "https://127.0.0.1:9/v1/responses")!, bearer: "offline")
        }
      #endif
      guard let endpoint = AIService.endpoint, let bearer = AIService.bearer else { return nil }
      return Configuration(endpoint: endpoint, bearer: bearer)
    }

    public var isAvailable: Bool { configuration() != nil }

    private static let log = Logger(subsystem: "com.luworks.one", category: "Agent")
    private static let session: URLSession = {
      let config = URLSessionConfiguration.ephemeral
      config.urlCache = nil
      config.httpCookieStorage = nil
      config.waitsForConnectivity = false
      // The Worker's upstream timeout is 30 s per step; the run deadline is enforced by AgentRunner.
      config.timeoutIntervalForRequest = 30
      config.timeoutIntervalForResource = 35
      return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
      func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
      ) { completionHandler(nil) }
    }

    struct Body: Encodable {
      let input: [JSONValue]
      let tools_version: String
      let run_id: String
      let stream = true
    }

    public func respond(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, any Error> {
      let configuration = configuration()
      return AsyncThrowingStream { continuation in
        let task = Task {
          guard let configuration else {
            continuation.finish(throwing: ModelClientError.unavailable)
            return
          }
          do {
            var http = URLRequest(url: configuration.endpoint)
            http.httpMethod = "POST"
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            http.setValue("Today-iOS/1.0", forHTTPHeaderField: "User-Agent")
            http.setValue("agent", forHTTPHeaderField: "X-Today-Stage")
            http.setValue("Bearer \(configuration.bearer)", forHTTPHeaderField: "Authorization")
            http.httpBody = try JSONEncoder().encode(
              Body(input: request.input, tools_version: request.toolsVersion, run_id: request.runID)
            )
            guard (http.httpBody?.count ?? 0) <= 250_000 else {
              throw ModelClientError.rejected("request_too_large")
            }
            let (bytes, response) = try await Self.session.bytes(for: http)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
              throw ModelClientError.network
            }
            guard status == 200 else {
              var body = Data()
              for try await byte in bytes {
                body.append(byte)
                if body.count > 65_536 { break }
              }
              let failure = LunaStreamDecoder.failure(status: status, body: body)
              Self.log.info(
                "AGENT_STEP run=\(request.runID, privacy: .public) http=\(status) error=\(String(describing: failure), privacy: .public)"
              )
              throw failure
            }
            var decoder = LunaStreamDecoder()
            for try await line in bytes.lines {
              try Task.checkCancellation()
              var events = try decoder.feed(line: line)
              // `lines` drops blank separators; every Responses event is one `data:` line.
              if line.hasPrefix("data:") { events += try decoder.feed(line: "") }
              for event in events { continuation.yield(event) }
              if decoder.finished { break }
            }
            for event in try decoder.finish() { continuation.yield(event) }
            guard decoder.finished else { throw ModelClientError.incomplete }
            continuation.finish()
          } catch let error as ModelClientError {
            continuation.finish(throwing: error)
          } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
          } catch let error as URLError where error.code == .cancelled {
            continuation.finish(throwing: CancellationError())
          } catch {
            continuation.finish(throwing: ModelClientError.network)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  }
#endif
