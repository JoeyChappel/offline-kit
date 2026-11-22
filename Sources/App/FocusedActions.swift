import SwiftUI

/// What the Ask screen offers the menu bar (New Conversation ⌘N, Stop Answer Esc) while it is showing.
struct AskActions {
    var canStartOver: Bool
    var isBusy: Bool
    var startOver: () -> Void
    var stop: () -> Void
}

extension FocusedValues {
    /// Set by Ask while it is on screen.
    @Entry var askActions: AskActions?
    /// The window's sidebar, for Go › sections.
    @Entry var kitNavigation: KitNavigation?
    /// Set by a screen with its own search box (not the toolbar's): focuses it for Edit › Find (⌘F).
    @Entry var findAction: (() -> Void)?
}

extension View {
    /// Makes ⌘F focus this screen's search box.
    func findShortcut(_ focus: FocusState<Bool>.Binding) -> some View {
        focusedSceneValue(\.findAction, { focus.wrappedValue = true })
    }
}
