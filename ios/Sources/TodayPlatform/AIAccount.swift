#if os(iOS)
  import Foundation
  import Observation
  import Security

  public enum AIService {
    public static var endpoint: URL? {
      guard let raw = Bundle.main.object(forInfoDictionaryKey: "TodayAIEndpoint") as? String,
        let url = URL(string: raw), url.scheme == "https", url.host != nil,
        url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
      else { return nil }
      return url
    }

    public struct Session: Codable, Sendable {
      public let token: String
      public let expires: Double
      public let username: String
    }
    private static let service = "com.luworks.today.ai-session"
    private static var query: [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: "bearer",
      ]
    }
    public static var credentials: Session? {
      var q = query
      q[kSecReturnData as String] = true
      q[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
        let data = result as? Data,
        let session = try? JSONDecoder().decode(Session.self, from: data),
        session.expires > Date.now.timeIntervalSince1970
      else { return nil }
      return session
    }
    public static var bearer: String? {
      guard UserDefaults.standard.bool(forKey: "today.ai.uploadConsent") else { return nil }
      return credentials?.token
    }
    static func store(_ session: Session) throws {
      let data = try JSONEncoder().encode(session)
      let status = SecItemUpdate(
        query as CFDictionary,
        [
          kSecValueData as String: data,
          kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ] as CFDictionary)
      if status == errSecItemNotFound {
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw Failure.storage }
      } else if status != errSecSuccess {
        throw Failure.storage
      }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
    public enum Failure: LocalizedError {
      case configuration, network, storage, server(String)
      public var errorDescription: String? {
        switch self {
        case .configuration: return "The AI service is not configured."
        case .network: return "Could not connect to the AI service. Please try again."
        case .storage: return "Could not save the AI session securely."
        case .server(let code):
          switch code {
          case "invalid_credentials":
            return "Check your username and password (at least 12 characters)."
          case "session_expired", "sign_in_required":
            return "Your AI session ended. Please sign in again."
          case "username_unavailable": return "That username is already in use."
          case "registration_closed": return "New AI accounts are currently limited."
          case "rate_limit": return "Too many attempts. Please try again later."
          case "service_budget_exhausted": return "The AI service usage limit has been reached."
          default: return "The AI service is temporarily unavailable."
          }
        }
      }
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
      func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
      ) { completionHandler(nil) }
    }
    private static let network: URLSession = {
      let config = URLSessionConfiguration.ephemeral
      config.urlCache = nil
      config.httpCookieStorage = nil
      config.timeoutIntervalForRequest = 20
      return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
    static func request(path: String, method: String = "POST", body: [String: String]? = nil)
      async throws -> Data
    {
      guard let endpoint else { throw Failure.configuration }
      let root = endpoint.deletingLastPathComponent().deletingLastPathComponent()
      var request = URLRequest(url: root.appending(path: path))
      request.httpMethod = method
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Today-iOS/1.0", forHTTPHeaderField: "User-Agent")
      if let bearer = credentials?.token {
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
      }
      if let body { request.httpBody = try JSONEncoder().encode(body) }
      let (data, response) = try await network.data(for: request)
      guard data.count < 16000, let http = response as? HTTPURLResponse else {
        throw Failure.network
      }
      guard http.statusCode == 200 else {
        struct ErrorBody: Decodable { let error: String }
        throw Failure.server(
          (try? JSONDecoder().decode(ErrorBody.self, from: data).error) ?? "unavailable")
      }
      return data
    }
  }

  @MainActor @Observable public final class AIAccount {
    public static let shared = AIAccount()
    public private(set) var username: String?
    public private(set) var busy = false
    public private(set) var error: String?
    public private(set) var used: Int?
    public private(set) var dailyLimit: Int?
    public var enabled: Bool {
      didSet { UserDefaults.standard.set(enabled, forKey: "today.ai.uploadConsent") }
    }
    private init() {
      username = AIService.credentials?.username
      enabled = UserDefaults.standard.bool(forKey: "today.ai.uploadConsent")
    }
    public func authenticate(username: String, password: String, register: Bool) async {
      guard !busy else { return }
      busy = true
      error = nil
      defer { busy = false }
      do {
        let data = try await AIService.request(
          path: register ? "auth/register" : "auth/login",
          body: ["username": username, "password": password])
        let session = try JSONDecoder().decode(AIService.Session.self, from: data)
        try AIService.store(session)
        self.username = session.username
        used = nil
        dailyLimit = nil
        enabled = true
        await refresh()
      } catch { self.error = error.localizedDescription }
    }
    public func refresh() async {
      guard let requestedToken = AIService.credentials?.token else {
        username = nil
        return
      }
      do {
        // Today's agent runs (one per message that reaches the agent), UTC day.
        struct Usage: Decodable {
          let username: String
          let runsUsed: Int
          let dailyRunLimit: Int
        }
        let usage = try JSONDecoder().decode(
          Usage.self, from: await AIService.request(path: "auth/session", method: "GET"))
        guard AIService.credentials?.token == requestedToken else { return }
        username = usage.username
        used = usage.runsUsed
        dailyLimit = usage.dailyRunLimit
        error = nil
      } catch {
        guard AIService.credentials?.token == requestedToken else { return }
        self.error = error.localizedDescription
        if isEndedSession(error) { clearLocalSession() }
      }
    }
    private func isEndedSession(_ error: any Error) -> Bool {
      guard let failure = error as? AIService.Failure, case .server(let code) = failure else {
        return false
      }
      return code == "session_expired" || code == "sign_in_required"
    }
    private func clearLocalSession() {
      AIService.clear()
      username = nil
      enabled = false
      used = nil
      dailyLimit = nil
    }
    public func signOut(deleteAccount: Bool = false) async {
      guard !busy else { return }
      busy = true
      error = nil
      defer { busy = false }
      do {
        _ = try await AIService.request(
          path: deleteAccount ? "auth/account" : "auth/logout",
          method: deleteAccount ? "DELETE" : "POST")
        clearLocalSession()
      } catch {
        self.error = error.localizedDescription
        if !deleteAccount {
          clearLocalSession()
          self.error = "Signed out on this iPhone. Remote sign-out could not be confirmed."
        } else if isEndedSession(error) {
          clearLocalSession()
        }
      }
    }
  }
#endif
