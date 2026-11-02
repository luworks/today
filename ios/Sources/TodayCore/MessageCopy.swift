import Foundation

/// Which chat messages offer a Copy button. The app's own status sentences ("Added the alarm “Gym”. Tap Undo if you
/// don't want it.", "OK, dropped it.", "已添加…") are templates: copying them is never useful.
/// Your own words, and answers the model wrote (`ChatMessage.carriesContent`), can be copied.
/// Plain Swift (no SwiftUI) so it runs under `swift test`.
public enum MessageCopy {
  /// True for the app's own sentences: an AI message is one unless it carries the model's content.
  public static func isTemplate(isUser: Bool, content: Bool) -> Bool {
    !isUser && !content
  }
}
