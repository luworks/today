import Foundation

public enum MessageCopy {
  /// True for the app's own sentences: an AI message is one unless it carries the model's content.
  public static func isTemplate(isUser: Bool, content: Bool) -> Bool {
    !isUser && !content
  }
}
