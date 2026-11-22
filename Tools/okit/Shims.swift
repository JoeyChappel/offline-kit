import Foundation

// okit compiles Sources/Core without Sources/App. Core's Share scope reads linked media (an App type);
// the command line never shares, so it sees none.
struct LinkedMediaShim: Sendable { var folder: String?; var tracks: [String] }

enum LinkedMedia {
    static func load(_ libraries: [URL]) -> [LinkedMediaShim] { [] }
}

/// Map names for the kit checkup (the App's copy also lays out the map picker, which needs SwiftUI).
enum MapRegions {
    static let wholeContinents = ["all", "north-america", "south-america", "europe", "africa", "asia", "australia-oceania"]
    static func slug(_ name: String) -> String { String(name.dropFirst("maps_en_".count)) }
}
