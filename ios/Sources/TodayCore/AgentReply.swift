import Foundation

/// The agent's final words, checked by code (docs/engineering/ai-agent-architecture.md §1.4 step 5):
/// the model may never say that something was added, moved, deleted or done. Only a card's own
/// status (rendered by code) says that, after the user taps it. Every fixed string the agent
/// path shows lives here, in the language of the user's message.
public enum AgentReply {
  public static func isChinese(_ text: String) -> Bool {
    text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
  }

  private static let claims: [String] = [
    // English: "I've added", "has been moved", "Done!", "successfully scheduled" …
    #"(?i)\b(i'?ve|i have|i|we'?ve|has been|have been|was|were|is now|are now|successfully|all set,? i)\s+(just\s+)?(added|created|moved|deleted|removed|scheduled|rescheduled|set|updated|changed|completed|cancell?ed|saved|marked)\b"#,
    #"(?i)^\s*(done|all done|all set)\b"#,
    #"(?i)\b(it'?s|they'?re|that'?s)\s+(been\s+)?(added|moved|deleted|removed|scheduled|done|saved|set)\b"#,
    // Chinese: "已添加", "已经帮你改到", "设置好了", "搞定" …
    #"已(经)?(为你|帮你|给你|替你)?(添加|加上|加好|新建|创建|建好|设置|设好|设定|移动|挪|改|修改|更新|删除|删掉|取消|标记|标为|保存|记下|提醒你)"#,
    #"(添加|设置|设|改|删|建|安排|加)(好|完)了"#,
    #"已(经)?(为你|帮你|给你|替你)?把"#,
    #"搞定|办好了|弄好了"#,
  ]

  /// Whether the text claims a write happened.
  public static func claimsDone(_ text: String) -> Bool {
    claims.contains { text.range(of: $0, options: .regularExpression) != nil }
  }

  /// The reply to show: the model's own words unless they claim a write, or there are none.
  public static func finalize(_ model: String, cards: Int, chinese: Bool) -> String {
    let text = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty || claimsDone(text) {
      return cards > 0 ? cardsReady(cards, chinese: chinese) : nothingChanged(chinese: chinese)
    }
    return text
  }

  public static func cardsReady(_ n: Int, chinese: Bool) -> String {
    if chinese {
      return n == 1 ? "卡片准备好了，点了才会生效。" : "\(n) 张卡片准备好了，点了才会生效。"
    }
    return n == 1
      ? "A card is ready. Nothing changes until you tap it."
      : "\(n) cards are ready. Nothing changes until you tap them."
  }

  public static func nothingChanged(chinese: Bool) -> String {
    chinese ? "没有改动任何内容。" : "Nothing was changed."
  }

  /// The run hit the step cap or the deadline: say so, and keep the cards it made.
  public static func unfinished(cards: Int, chinese: Bool) -> String {
    let head = chinese ? "还没做完，先停在这里。" : "I couldn't finish this in time."
    guard cards > 0 else {
      return head + (chinese ? " 请换个说法再试一次。" : " Try again or rephrase it.")
    }
    return head + " " + cardsReady(cards, chinese: chinese)
  }

  /// The model could not be reached (offline, signed out, quota) and the rules weren't sure either:
  /// the draft goes back to the composer (§4.7 #3).
  public static func unavailable(_ error: ModelClientError?, chinese: Bool) -> String {
    let rest =
      chinese
      ? "你的草稿还在输入框里；说清楚的提醒、事件和闹钟仍可在本地预览，整理逾期也能用。"
      : "Your draft is still in the box; clear reminders, events and alarms still get a local preview, and Tidy overdue still works."
    switch error {
    case .unavailable?:
      return (chinese ? "需要登录 Luna AI 才能用 AI。" : "Sign in to Luna AI to use AI. ") + rest
    case .quota(let code)? where code == "run_quota" || code == "service_budget_exhausted":
      return (chinese ? "今天的 AI 用量已用完。" : "Today's AI limit has been reached. ") + rest
    default:
      return (chinese ? "AI 暂时不可用。" : "AI is unavailable right now. ") + rest
    }
  }

  /// The heading of a rules-only preview made while the AI can't run (§4.7 #3).
  public static func localPreview(_ error: ModelClientError?, chinese: Bool) -> String {
    let why: String
    switch error {
    case .unavailable?: why = chinese ? "未登录 Luna AI" : "Not signed in to Luna AI"
    default: why = chinese ? "AI 暂时不可用" : "AI is unavailable"
    }
    return chinese
      ? "\(why)，这是按规则读出的预览。点 Add 才会添加。"
      : "\(why), so this preview comes from the rules. Nothing is added until you tap Add."
  }
}
