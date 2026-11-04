import Foundation
import XCTest
@testable import QuietInboxCore

final class FilterEngineTests: XCTestCase {
    func testAllowListWinsConflictingSenderRules() {
        var policy = FilterPolicy()
        policy.allowedSenders = ["+1 (415) 555-0199"]
        policy.blockedSenders = ["+14155550199"]
        let decision = FilterEngine().classify(
            sender: "+1 415 555 0199", body: "Claim your free prize now!", policy: policy
        )
        XCTAssertEqual(decision.action, .allow)
        XCTAssertTrue(decision.reason.contains("allow list"))
    }

    func testBlockListDoesNotInventCountryCodeOrMatchSuffix() {
        var policy = FilterPolicy()
        policy.blockedSenders = ["+14155550199"]
        let engine = FilterEngine(trainingData: nil)
        XCTAssertEqual(engine.classify(sender: "+1 (415) 555-0199", body: "Hello", policy: policy).action, .junk)
        XCTAssertEqual(engine.classify(sender: "4155550199", body: "Hello", policy: policy).action, .review)
        XCTAssertEqual(engine.classify(sender: "+4414155550199", body: "Hello", policy: policy).action, .review)
    }

    func testBlankSenderCannotMatchAnEmptyRule() {
        var policy = FilterPolicy()
        policy.blockedSenders = ["", " () +"]
        policy.allowedSenders = [" "]
        XCTAssertEqual(FilterEngine(trainingData: nil).classify(sender: "", body: "Hello", policy: policy).action, .review)
    }

    func testPausedFilterReturnsNoDecisionEvenForBlockedSender() {
        var policy = FilterPolicy()
        policy.enabled = false
        policy.blockedSenders = ["12345"]
        XCTAssertEqual(FilterEngine().classify(sender: "12345", body: "", policy: policy).action, .review)
    }

    func testOrdinaryVerificationDeliveryAndMedicalMessagesAreNotJunk() {
        let messages = [
            "Your verification code is 527184. Do not share this code with anyone. It expires in 5 minutes.",
            "Your parcel was delivered to reception today. Thank you for your order.",
            "Reminder: your hospital appointment is tomorrow at 10:30. Call the clinic if you need to reschedule.",
            "您的验证码为627481，5分钟内有效，请勿向任何人泄露验证码。",
            "您的快递已送达驿站，请凭取件码5678领取包裹，无需额外付费。",
            "医院提醒：您预约的门诊时间为明天上午10点30分，请携带医保卡就诊。",
        ]
        let engine = FilterEngine()
        for message in messages {
            XCTAssertNotEqual(engine.classify(sender: "Unknown", body: message, policy: .init()).action, .junk, message)
        }
    }

    func testVerificationCodeWordsDoNotBypassScamClassification() {
        let messages = [
            "Congratulations winner! Claim your free cash prize now. Pay processing fees to claim your reward. Send your verification code to receive your prize.",
            "恭喜中奖，请立即提供验证码和银行卡密码领取现金大奖。立即点击链接支付手续费完成领奖。",
        ]
        for message in messages {
            XCTAssertEqual(FilterEngine().classify(sender: "Unknown", body: message, policy: .init()).action, .junk)
        }
    }

    func testCompatibilityAndInvisibleCharactersDoNotChangeLearnedFeatures() {
        let original = "Claim your free cash reward now"
        let disguised = "Ｃｌａｉｍ your fr\u{200B}ee cash re\u{2060}ward NOW"
        XCTAssertEqual(FilterEngine.features(original), FilterEngine.features(disguised))
    }

    func testMissingCorruptAndSingleClassTrainingResourcesFailOpen() {
        let invalidResources: [Data?] = [
            nil,
            Data("broken".utf8),
            Data("[]".utf8),
            Data("[{\"label\":\"unknown\",\"text\":\"test\"}]".utf8),
            Data("[{\"label\":\"spam\",\"text\":\"free cash prize\"}]".utf8),
        ]
        for resource in invalidResources {
            let decision = FilterEngine(trainingData: resource).classify(
                sender: "Unknown", body: "Claim your free prize", policy: .init()
            )
            XCTAssertEqual(decision.action, .review)
        }
    }

    func testMissingBodyOverlongBodyAndUnfamiliarScriptAreKept() {
        let engine = FilterEngine()
        for message in ["", "\u{200B}", String(repeating: "x", count: 4097), "こんにちは", "🙃🙃🙃"] {
            XCTAssertEqual(engine.classify(sender: "Unknown", body: message, policy: .init()).action, .review)
        }
    }

    func testExplicitRulesContinueWorkingWithoutModel() {
        var policy = FilterPolicy()
        policy.blockedSenders = ["MARKETING"]
        XCTAssertEqual(FilterEngine(trainingData: nil).classify(sender: "marketing", body: "", policy: policy).action, .junk)
    }

    func testPolicyRoundTripPreservesUserChoices() throws {
        var policy = FilterPolicy()
        policy.enabled = false
        policy.allowedSenders = ["Hospital"]
        policy.blockedSenders = ["+123456789"]
        let restored = try JSONDecoder().decode(FilterPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(restored.enabled, policy.enabled)
        XCTAssertEqual(restored.allowedSenders, policy.allowedSenders)
        XCTAssertEqual(restored.blockedSenders, policy.blockedSenders)
    }
}
