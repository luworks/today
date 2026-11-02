import Foundation

/// Which chat messages offer a Copy button. The app's own status sentences ("Here's what I understood. Nothing is added
/// until you confirm.", "Updated…", "OK, dropped it.", "卡片准备好了…") are templates: copying them is never useful.
/// Your own words, and answers the model wrote (`ChatMessage.carriesContent`), can be copied.
/// Plain Swift (no SwiftUI) so it runs under `swift test`.
public enum MessageCopy {
  /// True for the app's own sentences: an AI message is one unless it carries the model's content.
  public static func isTemplate(isUser: Bool, content: Bool) -> Bool {
    !isUser && !content
  }
}
