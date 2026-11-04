import Foundation
import IdentityLookup
import QuietInboxCore

final class MessageFilterExtension: ILMessageFilterExtension, ILMessageFilterQueryHandling {
    private let engine = FilterEngine()

    func handle(
        _ queryRequest: ILMessageFilterQueryRequest,
        context: ILMessageFilterExtensionContext,
        completion: @escaping (ILMessageFilterQueryResponse) -> Void
    ) {
        let response = ILMessageFilterQueryResponse()
        // The extension only reads policy. Never persist SMS text or filter telemetry.
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.luworks.quietinbox"
        ) else {
            response.action = .none
            completion(response)
            return
        }
        let file = container.appendingPathComponent("policy.json")
        let policy: FilterPolicy
        if FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file),
                let saved = try? JSONDecoder().decode(FilterPolicy.self, from: data)
            else {
                response.action = .none
                completion(response)
                return
            }
            policy = saved
        } else { policy = FilterPolicy() }
        let decision = engine.classify(
            sender: queryRequest.sender ?? "", body: queryRequest.messageBody ?? "", policy: policy
        )
        switch decision.action {
        case .junk: response.action = .junk
        case .allow: response.action = .allow
        case .review: response.action = .none
        }
        completion(response)
    }
}
