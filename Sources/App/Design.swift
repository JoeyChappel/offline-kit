import SwiftUI

/// Shared look: rounded cards, quiet borders, the green accent from the asset catalog.
enum Design {
    static let canvas = Color("KitCanvas")
    static let surface = Color("KitSurface")
    static let sidebar = Color("KitSidebar")
    static let ink = Color("KitInk")
    static let muted = Color("KitMuted")
    static let border = Color("KitBorder")
    static let corner: CGFloat = 14
    static let readableWidth: CGFloat = 760
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.surface, in: RoundedRectangle(cornerRadius: Design.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Design.corner, style: .continuous).strokeBorder(Design.border, lineWidth: 0.5))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardStyle(padding: padding)) }
}

/// Small capsule label, e.g. "Offline" or "11 archives".
struct Pill: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// What kind of archive a book is, for grouping and icons.
enum BookKind: Int, CaseIterable, Comparable {
    case encyclopedia, guides, survival, community, other

    init(name: String) {
        let n = name.lowercased()
        if n.contains("stackexchange") { self = .community }
        else if n.hasPrefix("wikipedia") || n.hasPrefix("mdwiki") || n.hasPrefix("wik") || n.hasPrefix("vikidia") { self = .encyclopedia }
        else if n.contains("prepper") || n.contains("zimgit") || n.contains("armypubs") || n.contains("ready.gov")
                    || n.contains("survivor") || n.contains("military") || n.contains("cd3wd") || n.contains("selfreliance") { self = .survival }
        else if n.hasPrefix("ifixit") || n.contains("appropedia") || n.contains("energypedia") { self = .guides }
        else { self = .other }
    }

    var title: String {
        switch self {
        case .encyclopedia: "Encyclopedias"
        case .guides: "Repair and how-to"
        case .survival: "Survival and preparedness"
        case .community: "Q&A communities"
        case .other: "Other"
        }
    }

    static func < (a: BookKind, b: BookKind) -> Bool { a.rawValue < b.rawValue }
}

extension Book {
    var kind: BookKind { BookKind(name: archive.name) }
    var isOnExternalDrive: Bool { url.path.hasPrefix("/Volumes/") }
    var volumeName: String? {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
    }
}

extension Int {
    /// 1.2M, 360K style counts.
    var compact: String { formatted(.number.notation(.compactName)) }
}


struct KitHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(Color.accentColor)
            Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(Design.ink)
            Text(subtitle).font(.body).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct KitSymbol: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        Image(systemName: name).font(.title3).foregroundStyle(Color.accentColor)
            .frame(width: 38, height: 38)
            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Right-click › "Show in Finder" for a file in the kit (Mac).
struct ShowInFinderButton: View {
    let url: URL
    var body: some View {
        #if os(macOS)
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        #endif
    }
}

extension View {
    /// Adds "Show in Finder" to the item's right-click menu on Mac.
    @ViewBuilder func showInFinderMenu(_ url: URL) -> some View {
        #if os(macOS)
        contextMenu { ShowInFinderButton(url: url) }
        #else
        self
        #endif
    }
}
