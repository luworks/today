#if os(iOS)
  import SwiftUI

  /// The swipe actions every list uses, so they look and behave the same on every screen (Apple Mail / Reminders colors):
  /// Delete is always red and the rightmost, Flag orange, Archive indigo, Pin yellow, Info gray. All come from the trailing
  /// edge (swipe right to left). The tints are explicit: a list's own color (a purple Reminders list) must never repaint them.
  /// Icon only, like iOS 26 Mail and Reminders: with text, two actions are wide enough that the row's title slides off screen.
  /// The title stays the accessibility label, so VoiceOver and the UI tests still find "Delete", "Flag", ….
  @MainActor
  public enum RowAction {
    /// `asksFirst`: Delete only opens a question (a repeating event, a list). Then the button has no destructive role:
    /// with one, SwiftUI removes the row at once, the data still has it, and the list crashes on its next update
    /// ("Invalid update: invalid number of items").
    @ViewBuilder
    public static func delete(asksFirst: Bool = false, _ action: @escaping () -> Void) -> some View
    {
      let label = Label("Delete", systemImage: "trash.fill").labelStyle(.iconOnly)
      if asksFirst {
        Button(action: action) { label }.tint(.red)
      } else {
        Button(role: .destructive, action: action) { label }.tint(.red)
      }
    }

    public static func flag(_ flagged: Bool, _ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Label(flagged ? "Unflag" : "Flag", systemImage: flagged ? "flag.slash.fill" : "flag.fill")
          .labelStyle(.iconOnly)
      }
      .tint(.orange)
    }

    public static func archive(_ archived: Bool, _ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Label(
          archived ? "Unarchive" : "Archive",
          systemImage: archived ? "tray.and.arrow.up.fill" : "archivebox.fill"
        ).labelStyle(.iconOnly)
      }
      .tint(.indigo)
    }

    public static func pin(_ pinned: Bool, _ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash.fill" : "pin.fill")
          .labelStyle(.iconOnly)
      }
      .tint(.yellow)
    }

    public static func settle(_ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Label("Settle", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
      }
      .tint(.indigo)
    }

    public static func tomorrow(_ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Label("Tomorrow", systemImage: "sunrise").labelStyle(.iconOnly)
      }
      .tint(.blue)
    }

    public static func info(_ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Label("Info", systemImage: "info.circle.fill").labelStyle(.iconOnly)
      }
      .tint(Color(.systemGray))
    }
  }
#endif
