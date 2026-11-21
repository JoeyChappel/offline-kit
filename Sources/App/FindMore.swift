import SwiftUI

/// A free, legal place to get more games, video, audio or documents. Each opens in the browser.
struct FindMoreLink: Identifiable {
    let title: String
    let note: String
    let url: URL
    var id: String { url.absoluteString }

    init(_ title: String, _ note: String, _ url: String) {
        self.title = title
        self.note = note
        self.url = URL(string: url)!
    }
}

/// Vetted sources only: homebrew shared by its makers, public domain and Creative Commons.
/// Never add sites that copy commercial games, films or books.
enum FindMore {
    static let games: [FindMoreLink] = [
        .init("Homebrew Hub", "Free Game Boy and Game Boy Color games, shared by the people who made them.", "https://hh.gbdev.io"),
        .init("Game Boy games on itch.io", "Homemade Game Boy games. Many are free; some cost a few dollars.", "https://itch.io/games/tag-gameboy"),
        .init("NES homebrew on itch.io", "A collection of homemade NES games. Check each game’s price and license.", "https://itch.io/c/1024610/nes-homebrew-games"),
        .init("Pin Eight", "Free NES games and tools from a long-time homebrew developer.", "https://pineight.com/nes/"),
        .init("PC Engine games on itch.io", "Homemade PC Engine (TurboGrafx-16) games. Many cost money; check each one. Add the .pce file.", "https://itch.io/games/tag-pc-engine"),
        .init("Game Boy Advance games on itch.io", "Homemade Game Boy Advance games. Many are free; check each price. Add the .gba file.", "https://itch.io/games/tag-gameboy-advance"),
        .init("DOS games on itch.io", "New games made for DOS. Check each game’s price, and that its download says DOS. Add the game’s .zip as it is.", "https://itch.io/games/tag-ms-dos"),
        .init("ScummVM freeware games", "Classic adventures now free, like Beneath a Steel Sky and Flight of the Amazon Queen. Unzip the download, then choose Add ScummVM Game Folder.", "https://www.scummvm.org/games/"),
    ]

    static let watchAndListen: [FindMoreLink] = [
        .init("Internet Archive feature films", "Old feature films. Keep only ones marked Public Domain or Creative Commons, and choose the MPEG4 download.", "https://archive.org/details/feature_films"),
        .init("Blender Studio films", "Animated short films you can share with credit to Blender Studio (Creative Commons).", "https://studio.blender.org/films/"),
        .init("LibriVox", "Thousands more free audiobooks read by volunteers. Unzip the MP3 download into your Media folder.", "https://librivox.org"),
        .init("Musopen", "Free classical music recordings. Free accounts have a daily download limit.", "https://musopen.org"),
    ]

    static let books: [FindMoreLink] = [
        .init("Standard Ebooks", "Beautifully formatted classic books, free and public domain. Choose the EPUB download.", "https://standardebooks.org"),
        .init("Project Gutenberg", "Over 70,000 free public-domain books. Choose “EPUB3 (E-readers incl. Send-to-Kindle)”.", "https://www.gutenberg.org"),
    ]

    static let documents: [FindMoreLink] = [
        .init("OpenStax", "Free textbooks as PDFs: biology, chemistry, math, history and more.", "https://openstax.org"),
        .init("Ready.gov", "Free emergency plans and checklists you can print or save as PDFs.", "https://www.ready.gov"),
    ]
}

struct FindMoreCard: View {
    let title: String
    let intro: String
    let links: [FindMoreLink]
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "safari").font(.headline)
            Text(intro).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(links) { link in
                Link(destination: link.url) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.title).font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                            Text(link.note).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(link.url.absoluteString)
            }
            Text(footnote ?? "These open in your browser and need internet. Anything you download and add here works offline.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 18)
    }
}
