#if os(iOS)
  import SwiftUI

  /// The one place that defines how a pill looks. Every choice of
  /// capsules (Week / Month / Year, Alarms / World Clock / ..., filters, scopes, ranges) read their size, font and
  /// colors from here, so the two rows on the Calendar tab stay the reference and nothing drifts.
  @MainActor
  public enum PillStyle {
    // MARK: Colors (all adaptive: black on white in light mode, white on black in dark mode)

    public static let selectedFill = Color(.label)
    public static let selectedText = Color(.systemBackground)
    public static let unselectedFill = Color(.secondarySystemFill)
    public static let unselectedText = Color.primary

    public static func fill(selected: Bool) -> Color { selected ? selectedFill : unselectedFill }
    public static func text(selected: Bool) -> Color { selected ? selectedText : unselectedText }

    // MARK: Layout

    /// Gap between neighbouring pills (both rows).
    public static let spacing: CGFloat = 8
    /// Minimum height of a tappable pill; the visible capsule of a control pill may be shorter.
    public static let tapHeight = ButtonConfiguration.minimumHitSize

    /// Every selector: a text pill.
    public enum Control {
      public static let font = Font.footnote.weight(.semibold)
      public static let iconLabelSpacing: CGFloat = 5
      public static let padding: CGFloat = 14
      /// The visible capsule; the hit area stays `tapHeight`.
      public static let height: CGFloat = 34
    }

    /// Extras for `PillChip` only: a small tinted mark (icon or date) sits a little closer to the edge than text does.
    public enum Chip {
      public static let markSize: CGFloat = 18
      public static let leadingPadding: CGFloat = 10
    }

    /// The selection animation every pill row uses.
    public static let selectionAnimation = ButtonConfiguration.responseAnimation
  }

  /// One control pill: the visible look of Week / Month / Year. A label, optionally with a symbol.
  /// Use it directly for a single on/off pill, or through `PillSwitcher` for a choice.
  @MainActor
  public struct PillButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    package let title: String
    package var icon: String? = nil
    package let isSelected: Bool
    package var identifier: String? = nil
    package var fillsWidth = false
    package var action: () -> Void

    public init(
      title: String, icon: String? = nil, isSelected: Bool,
      identifier: String? = nil, fillsWidth: Bool = false, action: @escaping () -> Void
    ) {
      self.title = title
      self.icon = icon
      self.isSelected = isSelected
      self.identifier = identifier
      self.fillsWidth = fillsWidth
      self.action = action
    }

    public var body: some View {
      Button(action: action) {
        HStack(spacing: PillStyle.Control.iconLabelSpacing) {
          if let icon { Image(systemName: icon) }
          Text(title).lineLimit(1).fixedSize()
        }
        .font(PillStyle.Control.font)
        .padding(.horizontal, PillStyle.Control.padding)
        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: PillStyle.Control.height)
        .background(PillStyle.fill(selected: isSelected), in: Capsule())
        .foregroundStyle(PillStyle.text(selected: isSelected))
        // Animate the control, not the destination content changed by its action.
        .animation(reduceMotion ? nil : PillStyle.selectionAnimation, value: isSelected)
        .frame(minHeight: PillStyle.tapHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(PressScale())
      .accessibilityLabel(title)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityIdentifier(identifier ?? "")
    }
  }

  /// A single choice shown as pills: left-aligned with an equal gap, or spread to equal width, and it scrolls
  /// sideways when the pills do not fit. Selecting animates and gives a selection tick.
  @MainActor
  public struct PillSwitcher<Item: Hashable>: View {
    public enum Distribution { case leading, equal }

    package let items: [Item]
    @Binding package var selection: Item
    package var distribution: Distribution = .leading
    package let title: (Item) -> String
    package var icon: ((Item) -> String?)? = nil
    package var identifier: ((Item) -> String)? = nil

    public init(
      items: [Item], selection: Binding<Item>, distribution: Distribution = .leading,
      title: @escaping (Item) -> String, icon: ((Item) -> String?)? = nil,
      identifier: ((Item) -> String)? = nil
    ) {
      self.items = items
      self._selection = selection
      self.distribution = distribution
      self.title = title
      self.icon = icon
      self.identifier = identifier
    }

    public var body: some View {
      ViewThatFits(in: .horizontal) {
        row(fixedWidth: true)
        ScrollView(.horizontal, showsIndicators: false) { row(fixedWidth: false) }
      }
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
      .sensoryFeedback(InteractionFeedback.selection, trigger: selection)
    }

    private func row(fixedWidth: Bool) -> some View {
      HStack(spacing: PillStyle.spacing) {
        ForEach(items, id: \.self) { item in
          PillButton(
            title: title(item), icon: icon?(item), isSelected: item == selection,
            identifier: identifier?(item), fillsWidth: fixedWidth && distribution == .equal
          ) {
            selection = item
          }
        }
        if fixedWidth && distribution == .leading { Spacer(minLength: 0) }
      }
    }
  }

  /// A navigation chip: the same capsule as `PillButton` (always the unselected look, because it opens something rather
  /// than choosing), with a small tinted leading mark and an optional trailing count, e.g. [17 Today 10] in Reminders.
  /// Tap runs `action`; add `.contextMenu` outside for a long-press menu (the preview lifts just the capsule).
  @MainActor
  public struct PillChip<Leading: View>: View {
    package let title: String
    package var count: Int? = nil
    package var accessibilityText: String? = nil
    package var identifier: String? = nil
    @ViewBuilder package var leading: () -> Leading
    package var action: () -> Void

    public init(
      title: String, count: Int? = nil, accessibilityText: String? = nil,
      identifier: String? = nil, @ViewBuilder leading: @escaping () -> Leading,
      action: @escaping () -> Void
    ) {
      self.title = title
      self.count = count
      self.accessibilityText = accessibilityText
      self.identifier = identifier
      self.leading = leading
      self.action = action
    }

    public var body: some View {
      Button(action: action) {
        HStack(spacing: PillStyle.Control.iconLabelSpacing) {
          leading()
            .frame(width: PillStyle.Chip.markSize, height: PillStyle.Chip.markSize)
          Text(title).lineLimit(1).fixedSize()
          if let count {
            Text("\(count)")
              .monospacedDigit()
              .foregroundStyle(Color(.secondaryLabel))
              .contentTransition(.numericText())
          }
        }
        .font(PillStyle.Control.font)
        .padding(.leading, PillStyle.Chip.leadingPadding)
        .padding(.trailing, PillStyle.Control.padding)
        .frame(minHeight: PillStyle.Control.height)
        .background(PillStyle.fill(selected: false), in: Capsule())
        .foregroundStyle(PillStyle.text(selected: false))
        .contentShape(.contextMenuPreview, Capsule())
        .frame(minHeight: PillStyle.tapHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(PressScale())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityText ?? title)
      .accessibilityIdentifier(identifier ?? "")
    }
  }

  /// A row of chips (or any pills): left-aligned with the shared gap, one line only, and it scrolls sideways when they
  /// do not fit (large text, many pinned lists). While they fit there is no scroll view, so a sideways swipe on the row
  /// still switches tabs like on the other rows. `inset` is the page's side gutter: when the row scrolls, the chips
  /// slide under the screen edge instead of being cut at the gutter.
  @MainActor
  public struct PillChipRow<Content: View>: View {
    package var inset: CGFloat = 20
    @ViewBuilder package var content: () -> Content

    public init(inset: CGFloat = 20, @ViewBuilder content: @escaping () -> Content) {
      self.inset = inset
      self.content = content
    }

    public var body: some View {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: PillStyle.spacing) {
          content()
          Spacer(minLength: 0)
        }
        .padding(.horizontal, inset)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: PillStyle.spacing) { content() }
        }
        .contentMargins(.horizontal, inset, for: .scrollContent)
      }
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
  }

#endif
