import SwiftUI

/// Menu bar: Go (⌘1 to ⌘9 and ⌥⌘P for the sidebar sections), File › New Conversation (⌘N), Edit › Find (⌘F),
/// and Controls › Stop Answer (Esc). Each works when the window it acts on is frontmost.
struct KitCommands: Commands {
    @FocusedValue(\.kitNavigation) private var navigation
    @FocusedValue(\.askActions) private var ask
    @FocusedValue(\.findAction) private var find

    private struct Section {
        let title: String
        let item: SidebarItem
        let key: KeyEquivalent
        let modifiers: EventModifiers
    }

    private static let sections: [Section] = [
        Section(title: "Ask", item: .ask, key: "1", modifiers: .command),
        Section(title: "Library", item: .library, key: "2", modifiers: .command),
        Section(title: "Get Resources", item: .resources, key: "3", modifiers: .command),
        Section(title: "Kit Care", item: .kit, key: "4", modifiers: .command),
        Section(title: "Watch", item: .media, key: "5", modifiers: .command),
        Section(title: "Audiobooks", item: .audiobooks, key: "6", modifiers: .command),
        Section(title: "Music", item: .music, key: "7", modifiers: .command),
        Section(title: "Books", item: .books, key: "8", modifiers: .command),
        Section(title: "Play", item: .games, key: "9", modifiers: .command),
        // ⌘0 is Fit Page in the PDF reader, so Prepare and Share use ⌥⌘.
        Section(title: "Prepare", item: .prepare, key: "p", modifiers: [.command, .option]),
        Section(title: "Share on Wi-Fi", item: .share, key: "s", modifiers: [.command, .option]),
    ]

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") { ask?.startOver() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(ask?.canStartOver != true)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { find?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(find == nil)
        }
        CommandMenu("Go") {
            ForEach(Self.sections, id: \.title) { section in
                Button(section.title) { navigation?.selection = section.item }
                    .keyboardShortcut(section.key, modifiers: section.modifiers)
                    .disabled(navigation == nil)
            }
        }
        // Esc is only taken while an answer is being made.
        CommandMenu("Ask") {
            Button("Stop Answer") { ask?.stop() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(ask?.isBusy != true)
        }
    }
}
