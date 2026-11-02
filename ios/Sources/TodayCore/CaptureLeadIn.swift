import Foundation

/// The words a person puts in front of the thing itself when asking for a reminder:
/// "帮我增加一个 reminder 吧：", "帮我加个提醒，", "add a reminder to", "reminder:", "提醒我：".
/// They are instructions to the app, not part of the title. What follows them is the user's own wording and is kept as is
/// (a "我需要…" after the colon stays), so a title that had a lead-in is not cleaned of its own filler words.
/// A noun alone never counts ("增加库存提醒" and "add a task force meeting" are titles): the verb has to be there, and
/// without an "a" / "一个" the lead-in has to end in a colon, comma or "to".
/// Plain Swift (no SwiftUI) so it runs under `swift test`.
public enum CaptureLeadIn {
  private static let zhPolite = #"(?:请|麻烦(?:你)?)?(?:帮我|帮忙|给我|替我)?(?:再|先)?"#
  private static let zhVerb = #"(?:增加|添加|新增|新建|创建|建立|设置|加|设|建|记|写|定)"#
  private static let zhNoun = #"(?:提醒事项|提醒|reminder|待办事项|待办|todo|to-?do|任务)"#
  private static let zhParticle = #"\s*(?:吧|呀|啊|啦|哦|哈)?"#

  private static let enPolite =
    #"(?:(?:can|could|would|will)\s+(?:you|u)\s+)?(?:please\s+|pls\s+)?"#

  private static let patterns: [String] = [
    // Explicit event wrappers name the item type, not the event's title.
    "^" + enPolite
      + #"(?:create|add|schedule)\s+(?:a\s+|an\s+)?(?:calendar\s+)?event\s+"#,
    // 帮我增加一个 reminder 吧：…   帮我加个提醒，…   新建一条待办 …
    "^" + zhPolite + zhVerb + #"\s*(?:一个|一条|一下|个|条)\s*(?:的\s*)?"# + zhNoun + zhParticle
      + #"\s*[:：，,]?\s*"#,
    // 增加提醒：…   帮我设置提醒，…  (no "一个": the colon or comma has to be there)
    "^" + zhPolite + zhVerb + #"\s*"# + zhNoun + zhParticle + #"\s*[:：，,]\s*"#,
    // 提醒我：…   请提醒我，…   帮我提醒一下：…
    #"^(?:请|麻烦(?:你)?)?(?:帮我)?提醒(?:我|一下)"# + zhParticle + #"\s*[:：，,]\s*"#,
    // add a reminder to … / please set a reminder for … / create a new reminder: …
    "^" + enPolite
      + #"(?:add|set|create|make|put|schedule)(?:\s+up)?\s+(?:me\s+)?(?:(?:a|an|the|new|another)\s+)+reminder(?:\s+(?:to|for|that|about)\s+|\s*[:：,，\-–]\s*|\s*$)"#,
    // add a task: … / make a to-do to … (task and to-do need "to", "that" or a colon: "add a task for John" is a title)
    "^" + enPolite
      + #"(?:add|set|create|make|put|schedule)(?:\s+up)?\s+(?:me\s+)?(?:(?:a|an|the|new|another)\s+)+(?:to-?do|task)(?:\s+(?:to|that)\s+|\s*[:：,，\-–]\s*|\s*$)"#,
    // reminder: … / todo: …
    #"^(?:reminder|to-?do|task)\s*[:：]\s*"#,
    // remind me: …   please remind me, …   (a plain "remind me to" is the ordinary filler)
    #"^(?:please\s+|pls\s+)?remind\s+me\s*[:：,，]\s*"#,
  ]

  /// `title` without its lead-in, or nil when it has none (or nothing would be left).
  public static func strip(_ title: String) -> String? {
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
    for pattern in patterns {
      guard let r = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
        r.lowerBound == t.startIndex, !r.isEmpty
      else { continue }
      let rest = t[r.upperBound...].replacingOccurrences(
        of: #"^\s*(?:吧|呀|啊|啦|哦|哈)[，,：:]\s*"#, with: "", options: .regularExpression
      ).trimmingCharacters(
        in: CharacterSet(charactersIn: " \t\n,，。.、:：!！"))
      guard !rest.isEmpty else { return nil }
      return rest
    }
    return nil
  }
}
