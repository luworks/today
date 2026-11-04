import Foundation

public struct FilterPolicy: Codable {
    public var enabled: Bool = true
    public var blockedSenders: [String] = []
    public var allowedSenders: [String] = []

    public init() {}
}

public enum FilterAction: String, Equatable {
    case allow
    case junk
    case review
}

public struct FilterDecision {
    public let action: FilterAction
    public let reason: String
}

/// A small, experimental classifier trained exclusively from bundled synthetic examples.
/// Scores are evidence sums, not calibrated confidence or accuracy measurements.
public final class FilterEngine {
    private let model: CharacterModel?
    private static let maximumBodyLength = 4096

    public convenience init() {
        let url = Bundle.module.url(forResource: "synthetic-training", withExtension: "json")
        self.init(trainingData: url.flatMap { try? Data(contentsOf: $0) })
    }

    // Resource failure is injectable for tests without changing the production bundle.
    init(trainingData: Data?) {
        model = trainingData.flatMap { CharacterModel(data: $0) }
    }

    public func classify(sender: String, body: String, policy: FilterPolicy) -> FilterDecision {
        guard policy.enabled else {
            return .init(action: .review, reason: "Filtering is paused in Quiet Inbox. No filtering decision returned.")
        }

        let normalizedSender = Self.normalizeSender(sender)
        if !normalizedSender.isEmpty {
            if policy.allowedSenders.contains(where: {
                Self.normalizeSender($0) == normalizedSender
            }) {
                return .init(action: .allow, reason: "This sender is on your allow list.")
            }
            if policy.blockedSenders.contains(where: {
                Self.normalizeSender($0) == normalizedSender
            }) {
                return .init(action: .junk, reason: "This sender is on your block list.")
            }
        }

        guard !body.isEmpty, body.count <= Self.maximumBodyLength else {
            return .init(action: .review, reason: "The message is empty or exceeds the local model's input limit. Kept without filtering.")
        }
        guard let model else {
            return .init(action: .review, reason: "The experimental local model is unavailable. Kept without filtering.")
        }

        let evidence = model.evaluate(body)
        // Multiple distinct learned patterns are necessary. An unknown feature contributes zero.
        // The wide abstention interval intentionally leaves unfamiliar messages untouched.
        if evidence.score >= 9, evidence.spamPatterns >= 6 {
            return .init(action: .junk, reason: "Experimental local model: multiple text patterns resemble the bundled spam examples.")
        }
        if evidence.score <= -6, evidence.hamPatterns >= 6 {
            return .init(action: .allow, reason: "Experimental local model: text patterns resemble the bundled ordinary-message examples.")
        }
        return .init(action: .review, reason: "The experimental local model has insufficient evidence. Kept without filtering.")
    }

    static func normalizeSender(_ sender: String) -> String {
        let text = sender.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneCharacters = CharacterSet(charactersIn: "+0123456789()- .\t\n\r")
        if text.unicodeScalars.allSatisfy(phoneCharacters.contains) {
            let result = String(text.unicodeScalars.filter {
                CharacterSet(charactersIn: "+0123456789").contains($0)
            })
            guard result.contains(where: { $0.isNumber }) else { return "" }
            return result
        }
        return text.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func features(_ body: String) -> Set<String> {
        // Compatibility folding handles full-width text. Dropping non-alphanumerics also
        // removes zero-width separators. No message, feature, or decision is persisted.
        let normalized = body.precomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let characters = Array(String(normalized.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
        guard characters.count >= 2 else { return [] }
        return Set(zip(characters, characters.dropFirst()).map { String([$0.0, $0.1]) })
    }
}

private struct TrainingExample: Decodable {
    let label: String
    let text: String
}

private struct CharacterModel {
    let weights: [String: Double]

    init?(data: Data) {
        guard let examples = try? JSONDecoder().decode([TrainingExample].self, from: data),
              !examples.isEmpty,
              examples.allSatisfy({ ["spam", "ham"].contains($0.label) && !$0.text.isEmpty })
        else { return nil }

        let spam = examples.filter { $0.label == "spam" }
        let ham = examples.filter { $0.label == "ham" }
        guard spam.count >= 10, ham.count >= 10 else { return nil }
        var spamCounts: [String: Int] = [:]
        var hamCounts: [String: Int] = [:]
        for example in spam {
            for feature in FilterEngine.features(example.text) {
                spamCounts[feature, default: 0] += 1
            }
        }
        for example in ham {
            for feature in FilterEngine.features(example.text) {
                hamCounts[feature, default: 0] += 1
            }
        }
        var learnedWeights: [String: Double] = [:]
        for feature in Set(spamCounts.keys).union(hamCounts.keys) {
            let spamProbability = Double(spamCounts[feature, default: 0] + 1) / Double(spam.count + 2)
            let hamProbability = Double(hamCounts[feature, default: 0] + 1) / Double(ham.count + 2)
            learnedWeights[feature] = log(spamProbability / hamProbability)
        }
        weights = learnedWeights
    }

    func evaluate(_ body: String) -> (score: Double, spamPatterns: Int, hamPatterns: Int) {
        var score = 0.0
        var spamPatterns = 0
        var hamPatterns = 0
        for feature in FilterEngine.features(body) {
            let weight = weights[feature, default: 0]
            score += weight
            if weight >= 0.65 { spamPatterns += 1 }
            if weight <= -0.65 { hamPatterns += 1 }
        }
        return (score, spamPatterns, hamPatterns)
    }
}
