import SwiftUI

/// How wide the toolbar's search field is: the width of the details card, so that it does not straddle the edge between
/// the table and the card (two different greys in dark mode), but narrower when the window is too narrow for that.
///
/// A toolbar does not shrink a field to fit: at the minimum window width a field of the card's width was moved into the
/// toolbar's overflow menu, where it cannot be used, and a flexible `frame(minWidth:maxWidth:)` made no difference. So the
/// width is worked out here from the width of the area the toolbar has, less what the title and the buttons need.
enum SearchFieldLayout {
    static let widest = MainWindowLayout.paneWidth
    static let narrowest: CGFloat = 120
    /// What the title, the subtitle and the buttons take of the detail area's width. An estimate: the subtitle can
    /// grow with the speed and the number of active downloads.
    static let otherToolbarItems: CGFloat = 500

    /// The narrowest the detail area can really be: the window at its minimum width, less the widest sidebar.
    static let smallestRealArea = MainWindowLayout.minWindowWidth - MainWindowLayout.sidebarMaxWidth

    static func width(detailAreaWidth: CGFloat) -> CGFloat {
        // A width below any the window can have is a measurement taken before the layout has settled (right after
        // launch). Acting on it reserved a slot of the floor's width in the toolbar, which the field then outgrew and
        // spilled out of the window; the toolbar only re-measures a slot when the window is resized.
        guard detailAreaWidth >= smallestRealArea else { return widest }
        return min(widest, max(narrowest, detailAreaWidth - otherToolbarItems))
    }
}

/// The search field in the window's toolbar, drawn here instead of with `.searchable`: that field is as wide as the
/// toolbar leaves room for and cannot be given a width (see `SearchFieldLayout`).
struct ToolbarSearchField: View {
    @Binding var text: String
    /// Set to true to move keyboard focus into the field (⌘F); the field sets it back once it has. The field keeps its own
    /// focus state because a toolbar item is hosted apart from the window's content: a `FocusState` of the window's
    /// view cannot reach into it.
    @Binding var focusRequested: Bool
    let width: CGFloat
    /// Where keyboard focus goes when Escape is pressed in an empty field.
    let leave: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search downloads", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                // Escape clears the text first, and only then gives the keyboard back, as the system search field does.
                .onExitCommand {
                    if text.isEmpty { leave() } else { text = "" }
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 34)
        .glassSurface(.capsule)
        // `initial`: a request made while the field was not on screen (the toolbar had moved it into its overflow menu)
        // is still there when it comes back, and would otherwise never be seen, so ⌘F would stay dead.
        .onChange(of: focusRequested, initial: true) { _, requested in
            guard requested else { return }
            isFocused = true
            Self.focusFieldInWindow()
            focusRequested = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isSearchField)
    }

    /// Puts the keyboard cursor in the field through AppKit. Setting the SwiftUI focus state alone did not move focus out
    /// of the table: the field is hosted in the toolbar, apart from the window's content.
    @MainActor
    private static func focusFieldInWindow() {
        // The one text field among the toolbar's items is the search field.
        guard let window = MainWindow.window,
              let field = window.toolbar?.items.lazy.compactMap({ $0.view?.firstDescendant(of: NSTextField.self) }).first else { return }
        window.makeFirstResponder(field)
    }
}
