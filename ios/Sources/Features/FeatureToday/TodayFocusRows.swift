#if os(iOS)
  import One
  import SwiftUI
  import TodayCore
  import TodayData
  import TodayPlannerUI

  struct FocusTarget: Identifiable {
    var identity: FocusIdentity?
    var reference: String?
    var title: String
    /// What "Ask AI" opens a chat about; nil when the item can't be read any more.
    var subject: AskSubject? = nil
    var id: String {
      (reference ?? identity?.item ?? "unavailable")
        + String(identity?.occurrence?.timeIntervalSince1970 ?? 0)
    }
  }

  struct TodayFocusRowActions: ViewModifier {
    let enabled: Bool
    let settle: () -> Void
    var ask: AskSubject? = nil
    var open: (() -> Void)? = nil
    var delete: (() -> Void)? = nil
    var restore: (() -> Void)? = nil
    var showSettle = true
    var restoreLabel = "Restore"

    @ViewBuilder private var attentionButtons: some View {
      if let restore {
        Button(restoreLabel, systemImage: "arrow.uturn.backward", action: restore)
      } else if showSettle {
        Button("Settle", systemImage: "checkmark.circle.fill", action: settle)
      }
    }

    @ViewBuilder func body(content: Content) -> some View {
      if enabled {
        content
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let delete { Button("Delete", systemImage: "trash", action: delete).tint(.red) }
            if let restore {
              Button(restoreLabel, systemImage: "arrow.uturn.backward", action: restore).tint(
                .indigo)
            } else if showSettle {
              Button("Settle", systemImage: "checkmark.circle.fill", action: settle).tint(.indigo)
            }
          }
          .contextMenu {
            if let ask { AskAIMenuButton(ask) }
            if let open { Section { Button("Open", systemImage: "pencil", action: open) } }
            Section { attentionButtons }
            if let delete {
              Section { Button("Delete", systemImage: "trash", role: .destructive, action: delete) }
            }
          }
          .accessibilityActions {
            attentionButtons
            if let delete { Button("Delete", action: delete) }
          }
      } else {
        content
      }
    }
  }
#endif
