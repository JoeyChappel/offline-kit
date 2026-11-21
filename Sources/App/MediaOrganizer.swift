import Foundation
import AVFoundation
import Observation

// "Organize with AI" fills in genre, studio/publisher/author, year, series, an age rating and a one-line description.
// Order of trust, field by field:
//   1. What the file itself says (tags, EPUB metadata, a game cartridge's internal name).
//   2. An article in the offline library (a Wikipedia archive): the model only extracts from it, and a value is
//      labeled as coming from the article only when it's actually written there.
//   3. The model's own knowledge, always labeled "AI guess".
// Results wait in a review screen; nothing in the catalog changes until approved. Files are never renamed or moved.

/// One thing to organize, gathered on the main actor and worked on in the background.
struct OrganizeTarget: Sendable, Identifiable {
    let key: String
    let title: String
    let kind: CatalogKind
    let files: [URL]
    let owner: URL
    /// What a person already set (never replaced).
    let userKeys: Set<CatalogDetails.Key>
    /// Artist or author from the tags, to tell same-named titles apart.
    var creatorHint: String?
    var yearHint: Int?
    var system: String?
    var id: String { key }
}

@MainActor @Observable
final class MediaOrganizer {
    static let shared = MediaOrganizer()

    enum State: Equatable { case idle, running, paused, finished }
    private(set) var state: State = .idle
    private(set) var done = 0
    private(set) var total = 0
    private(set) var current = ""
    private(set) var engineName: String?
    private(set) var grounding: String?
    private(set) var message: String?
    var scope: CatalogKind?
    /// Also look again at items already organized (fields a person edited are still never touched).
    var redo = false

    @ObservationIgnored private var task: Task<Void, Never>?

    var isWorking: Bool { state == .running || state == .paused }

    func pause() { if state == .running { state = .paused } }
    func resume() { if state == .paused { state = .running } }
    func stop() { task?.cancel(); task = nil; if isWorking { state = .finished; message = "Stopped. \(done) of \(total) looked at; run again to continue." } }

    /// The library folder an item's catalog details are saved in (the one it lives in, so they travel together).
    static func owner(of item: MediaItem) -> URL {
        if item.linkID == nil, item.root.lastPathComponent == "Media" { return item.root.deletingLastPathComponent() }
        return KitStorage.primaryLibrary
    }

    func targets(media: MediaLibrary, games: GameLibrary) -> [OrganizeTarget] {
        let catalog = KitCatalog.shared
        var list: [OrganizeTarget] = []
        for item in media.items where item.unavailable == nil {
            let info = media.info[item.progressKey]
            let kind: CatalogKind = switch MediaCatalog.category(item, info) {
            case .video: .video
            case .music: .music
            case .audiobooks: .audiobook
            default: .book
            }
            guard scope == nil || scope == kind else { continue }
            let key = KitCatalog.mediaKey(item)
            if catalog.suggestions[key] != nil { continue }
            if !redo, catalog.details[key] != nil { continue }
            let user = Set(CatalogDetails.Key.allCases.filter { catalog.details[key]?[$0]?.source == .user })
            list.append(OrganizeTarget(key: key, title: MediaCatalog.title(item, info), kind: kind, files: item.tracks, owner: Self.owner(of: item),
                                       userKeys: user, creatorHint: info?.albumArtist ?? info?.artist ?? info?.author, yearHint: info?.year))
        }
        if scope == nil || scope == .game {
            for game in games.games {
                let key = KitCatalog.gameKey(game)
                if catalog.suggestions[key] != nil { continue }
                if !redo, catalog.details[key] != nil { continue }
                let user = Set(CatalogDetails.Key.allCases.filter { catalog.details[key]?[$0]?.source == .user })
                list.append(OrganizeTarget(key: key, title: game.title, kind: .game, files: [game.url],
                                           owner: GameLibrary.gamesRoot(containing: game.url).deletingLastPathComponent(),
                                           userKeys: user, system: game.system.name))
            }
        }
        return list
    }

    func start(library: Library, media: MediaLibrary, games: GameLibrary, model: AskModel) {
        guard !isWorking else { return }
        KitCatalog.shared.reload(library)
        done = 0; total = 0; message = nil; current = "your library"
        state = .running
        model.libraryFolders = library.folders
        // Wikipedia archives in the kit (the movies archive included) ground the answers. Read-only.
        let archives = library.books.map(\.archive).filter { $0.name.lowercased().hasPrefix("wikipedia") }
        #if DEBUG
        let noGrounding = ProcessInfo.processInfo.environment["OFFLINEKIT_ORGANIZE_NO_GROUNDING"] == "1"
        #else
        let noGrounding = false
        #endif
        let usable = noGrounding ? [] : archives
        grounding = usable.isEmpty ? nil : usable.map { $0.title }.joined(separator: ", ")
        task = Task { [weak self] in
            guard let self else { return }
            // Play may not have been opened yet this launch: read the games too.
            if self.scope == nil || self.scope == .game { await games.reload(library: library) }
            let targets = self.targets(media: media, games: games)
            self.total = targets.count
            guard !targets.isEmpty else {
                self.state = .finished
                self.message = "Everything here is organized already. Turn on “Look again” to refresh it."
                self.task = nil
                return
            }
            let engine = await model.resolveEngine()
            self.engineName = engine?.displayName
            for target in targets {
                while self.state == .paused && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled, self.state == .running else { break }
                self.current = target.title
                let suggestion = await Task.detached(priority: .utility) {
                    await Self.organize(target, engine: engine, archives: usable)
                }.value
                guard !Task.isCancelled else { break }
                if let suggestion { KitCatalog.shared.addSuggestion(suggestion, owner: target.owner) }
                self.done += 1
            }
            if self.state == .running {
                self.state = .finished
                let waiting = KitCatalog.shared.suggestions.count
                self.message = engine == nil
                    ? "No answer model is set up, so only details from the files themselves were used. \(waiting) waiting for review."
                    : "Done. \(waiting) \(waiting == 1 ? "suggestion is" : "suggestions are") waiting for your review."
            }
            self.current = ""
            self.task = nil
        }
    }

    // MARK: - One item

    nonisolated static func organize(_ target: OrganizeTarget, engine: AnswerEngine?, archives: [ZimArchive]) async -> CatalogSuggestion? {
        var context: [String] = []
        let embedded = await embeddedDetails(target, context: &context)
        var names = [cleanTitle(target.title)]
        if names[0] != MediaCatalog.displayTitle(target.title) { names.append(MediaCatalog.displayTitle(target.title)) }
        if let rom = context.first(where: { $0.hasPrefix("Cartridge name: ") })?.dropFirst("Cartridge name: ".count) {
            let pretty = String(rom).capitalized
            if pretty.count >= 3, !names.contains(where: { $0.caseInsensitiveCompare(pretty) == .orderedSame }) { names.append(pretty) }
        }
        let article = findArticle(names: names, kind: target.kind, year: embedded.year.flatMap { Int($0.value) } ?? target.yearHint,
                                  creator: target.creatorHint, archives: archives)

        var proposed = CatalogDetails()
        // 1. The file's own tags.
        for key in CatalogDetails.Key.allCases where !target.userKeys.contains(key) {
            if let value = embedded[key] { proposed[key] = value }
        }
        // 2 and 3. The model, reading the article when there is one.
        let missing = CatalogDetails.Key.allCases.filter { proposed[$0] == nil && !target.userKeys.contains($0) }
        if let engine, !missing.isEmpty, let reply = await ask(engine, target: target, context: context, embedded: embedded, article: article) {
            for key in missing {
                guard let (value, fromArticle) = reply[key] else { continue }
                if fromArticle, let article, supports(article.text, value: value, key: key) {
                    proposed[key] = CatalogField(value: value, source: .library, article: article.title)
                } else if key != .ageRating {
                    // An age rating is never a guess: without the file or an article saying so, it stays empty.
                    proposed[key] = CatalogField(value: value, source: .aiGuess)
                }
            }
        }
        guard !proposed.isEmpty else { return nil }
        return CatalogSuggestion(key: target.key, title: target.title, kind: target.kind, proposed: proposed, article: article?.title)
    }

    /// A file name's noise taken off for looking it up: "Tears of Steel copy", "Sintel (1)", "Big Buck Bunny 1080p".
    nonisolated static func cleanTitle(_ title: String) -> String {
        var t = MediaCatalog.displayTitle(title)
        let noise = [#"\s+copy(\s+\d+)?$"#, #"\s*[\(\[]\d{1,2}[\)\]]$"#,
                     #"(?i)[\s._-]+(1080p|720p|480p|2160p|4k|uhd|hd|x264|x265|h264|hevc|bluray|blu-ray|dvdrip|webrip|web-dl|final)\b.*$"#]
        for _ in 0..<2 { for pattern in noise { t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive]) } }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? MediaCatalog.displayTitle(title) : t
    }

    // MARK: 1. The file itself

    nonisolated static func embeddedDetails(_ target: OrganizeTarget, context: inout [String]) async -> CatalogDetails {
        var details = CatalogDetails()
        func file(_ value: String?) -> CatalogField? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return CatalogField(value: value, source: .file)
        }
        guard let first = target.files.first else { return details }
        context.append("File: \(first.lastPathComponent)")
        switch target.kind {
        case .music, .audiobook:
            let tag = await AudioTags.read(first)
            let spoken = ["audiobook", "audiobooks", "audio book", "speech", "spoken word", "books & spoken", "podcast", "other", "unknown", "genre"]
            if let genre = tag.genre, !spoken.contains(genre.lowercased()) { details.genre = file(genre) }
            if let year = tag.year, year > 1800 { details.year = file(String(year)) }
            let who = tag.albumArtist ?? tag.artist
            if target.kind == .audiobook { details.creator = file(who) } else if let who { context.append("Artist: \(who)") }
            if let album = tag.album { context.append("Album: \(album)") }
            context.append("Tracks: \(target.files.count)")
        case .video:
            let asset = AVURLAsset(url: first)
            for entry in (try? await asset.load(.metadata)) ?? [] {
                guard let value = try? await entry.load(.stringValue), !value.isEmpty else { continue }
                let id = entry.identifier?.rawValue.lowercased() ?? "", common = entry.commonKey?.rawValue.lowercased() ?? ""
                if id.contains("genre") || id.hasSuffix("gen") { details.genre = details.genre ?? file(value) }
                else if common == "publisher" { details.creator = details.creator ?? file(value) }
                else if common == "description", value.count < 300 { details.summary = details.summary ?? file(value) }
                else if id.contains("year") || id.contains("day") || id.contains("creationdate"), let year = Int(value.prefix(4)), year > 1880 {
                    details.year = details.year ?? file(String(year))
                }
            }
            if details.year == nil, let year = MediaCatalog.year(in: target.title) { details.year = file(String(year)) }
            if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 { context.append("Length: \(Int(d.seconds / 60)) minutes") }
        case .book:
            if first.pathExtension.lowercased() == "epub" {
                let opf = epubMetadata(first)
                details.creator = file(opf["creator"])
                // dc:date is usually this edition's date (an ebook from 2014 of an 1813 novel), not first publication.
                if let date = opf["date"], let year = Int(date.prefix(4)), year > 1000 { context.append("This edition’s date (not first publication): \(year)") }
                details.series = file(opf["series"])
                if details.series != nil { details.seriesOrder = file(opf["series_index"].map { $0.hasSuffix(".0") ? String($0.dropLast(2)) : $0 }) }
                if let subjects = opf["subjects"], !subjects.isEmpty {
                    details.genre = file(MediaInfoStore.friendlyGenre(subjects.components(separatedBy: "|")))
                    context.append("Subjects: \(subjects.replacingOccurrences(of: "|", with: "; "))")
                }
                if let publisher = opf["publisher"] { context.append("Publisher of this edition: \(publisher)") }
            }
        case .game:
            if let system = target.system { context.append("System: \(system)") }
            if let name = romName(first) { context.append("Cartridge name: \(name)") }
        }
        return details
    }

    /// dc:creator, dc:date, dc:publisher, subjects and Calibre's series fields from an EPUB's package file.
    nonisolated static func epubMetadata(_ url: URL) -> [String: String] {
        guard let zip = ZipReader(url: url), let container = zip.data("META-INF/container.xml") else { return [:] }
        let text = String(decoding: container, as: UTF8.self)
        guard let range = text.range(of: #"full-path\s*=\s*"([^"]+)""#, options: .regularExpression) else { return [:] }
        let path = String(text[range]).components(separatedBy: "\"")[1]
        guard let data = zip.data(path) else { return [:] }
        let opf = String(decoding: data, as: UTF8.self)
        func first(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: opf, range: NSRange(opf.startIndex..., in: opf)),
                  let r = Range(match.range(at: 1), in: opf) else { return nil }
            let value = HTMLText.decodeEntities(HTMLText.stripTags(String(opf[r]))).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        var out: [String: String] = [:]
        out["creator"] = first(#"<dc:creator[^>]*>(.*?)</dc:creator>"#)
        out["date"] = first(#"<dc:date[^>]*>(.*?)</dc:date>"#)
        out["publisher"] = first(#"<dc:publisher[^>]*>(.*?)</dc:publisher>"#)
        out["series"] = first(#"name="calibre:series"\s+content="([^"]+)""#)
        out["series_index"] = first(#"name="calibre:series_index"\s+content="([^"]+)""#)
        // EPUB 3 collections count only when marked as a series: Standard Ebooks also lists reading lists
        // ("The Guardian’s 100 Best Novels") as collections of type "set".
        if out["series"] == nil, let regex = try? NSRegularExpression(pattern: #"<meta[^>]*id="([^"]+)"[^>]*property="belongs-to-collection"[^>]*>(.*?)</meta>"#, options: [.dotMatchesLineSeparators]) {
            for match in regex.matches(in: opf, range: NSRange(opf.startIndex..., in: opf)) {
                guard let i = Range(match.range(at: 1), in: opf), let n = Range(match.range(at: 2), in: opf) else { continue }
                let id = NSRegularExpression.escapedPattern(for: String(opf[i]))
                let refines = ##"\s+refines="#"## + id + #""[^>]*>"#
                guard first(#"property="collection-type""# + refines + #"\s*(series)\s*<"#) != nil else { continue }
                out["series"] = HTMLText.decodeEntities(String(opf[n])).trimmingCharacters(in: .whitespacesAndNewlines)
                out["series_index"] = first(#"property="group-position""# + refines + #"(.*?)<"#)
                break
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"<dc:subject[^>]*>(.*?)</dc:subject>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let subjects = regex.matches(in: opf, range: NSRange(opf.startIndex..., in: opf)).compactMap { Range($0.range(at: 1), in: opf).map { String(opf[$0]) } }
            if !subjects.isEmpty { out["subjects"] = subjects.joined(separator: "|") }
        }
        return out
    }

    /// The name stored inside a Game Boy, Game Boy Color or Game Boy Advance cartridge image.
    nonisolated static func romName(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let range: Range<Int>
        switch ext {
        case "gb", "gbc": range = 0x134..<0x144
        case "gba": range = 0xA0..<0xAC
        default: return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(range.lowerBound))) != nil, let data = try? handle.read(upToCount: range.count) else { return nil }
        let text = String(decoding: data.prefix { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.count >= 3 ? text : nil
    }

    // MARK: 2. The offline library

    struct Article: Sendable { let title: String; let text: String }

    /// Looks the title up in the kit's Wikipedia archives: a title match first ("Sintel", "Sintel (film)"), then the
    /// library search Ask uses. The article must be about the right kind of thing (a film, an album, a novel…).
    nonisolated static func findArticle(names: [String], kind: CatalogKind, year: Int?, creator: String?, archives: [ZimArchive]) -> Article? {
        guard !archives.isEmpty else { return nil }
        let kindWords: [String] = switch kind {
        case .video: ["film", "movie", "series", "animated", "short", "documentary", "television", "episode"]
        case .music: ["album", "band", "singer", "song", "musician", "record", "soundtrack", "composer"]
        case .audiobook, .book: ["novel", "book", "author", "story", "stories", "writer", "poem", "play"]
        case .game: ["game", "video game", "nintendo", "atari", "developed", "published"]
        }
        var best: (score: Int, archive: ZimArchive, path: String, title: String)?
        func consider(_ archive: ZimArchive, path: String, title: String, name: String) {
            let t = normalized(title), n = normalized(name)
            guard !n.isEmpty else { return }
            var score = 0
            if t == n { score = 3 }
            else if t.hasPrefix(n + " ") {
                let bracket = t.dropFirst(n.count).trimmingCharacters(in: .whitespaces)
                if kind.disambiguators.contains(where: { bracket.contains(normalized($0)) }) { score = 5 }
                if let year, bracket.contains(String(year)) { score += 1 }
            }
            guard score > 0, score > (best?.score ?? 0) else { return }
            best = (score, archive, path, title)
        }
        for name in names {
            for archive in archives {
                for hit in archive.suggest(name, limit: 12) { consider(archive, path: hit.path, title: hit.title, name: name) }
            }
        }
        if best == nil, let name = names.first {
            // The library search Ask uses, read-only: a full-text search when the title alone doesn't match.
            let question = ([name, kind.disambiguators.first ?? ""] + [creator].compactMap { $0 }).joined(separator: " ")
            for source in Retriever.retrieve(question: question, archives: archives, budgetChars: 1_500, maxSources: 4) {
                guard let archive = archives.first(where: { $0.uuid.lowercased() == source.ref.bookID.lowercased() }) else { continue }
                consider(archive, path: source.ref.path, title: source.ref.title, name: name)
            }
        }
        guard let best, let content = best.archive.content(atPath: best.path), content.mimeType.hasPrefix("text/html"),
              let html = String(data: content.data, encoding: .utf8) else { return nil }
        let infobox = infoboxLines(html)
        let paragraphs = HTMLText.paragraphs(html, minLength: 40)
        let lead = paragraphs.prefix(4).joined(separator: "\n")
        // Wrong kind of article ("Sintel" the character, a town, a person): not used.
        let opening = (infobox.prefix(6).joined(separator: " ") + " " + lead.prefix(700)).lowercased()
        guard kindWords.contains(where: opening.contains) else { return nil }
        var text = infobox.isEmpty ? "" : infobox.joined(separator: "\n") + "\n\n"
        text += lead
        return Article(title: best.title, text: String(text.prefix(3_800)))
    }

    /// "Directed by: Ian Hubert" lines from a Wikipedia infobox.
    nonisolated static func infoboxLines(_ html: String) -> [String] {
        guard let table = html.range(of: #"<table[^>]*class="[^"]*infobox[^"]*"[^>]*>.*?</table>"#, options: [.regularExpression]) else { return [] }
        let box = String(html[table])
        guard let row = try? NSRegularExpression(pattern: #"<th[^>]*>(.*?)</th>\s*<td[^>]*>(.*?)</td>"#, options: [.dotMatchesLineSeparators]) else { return [] }
        return row.matches(in: box, range: NSRange(box.startIndex..., in: box)).compactMap { match in
            guard let l = Range(match.range(at: 1), in: box), let v = Range(match.range(at: 2), in: box) else { return nil }
            let clean = { (s: Substring) in
                HTMLText.decodeEntities(HTMLText.stripTags(String(s).replacingOccurrences(of: "<br", with: ", <br")))
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespacesAndNewlines))
            }
            let label = clean(box[l]), value = clean(box[v])
            return label.isEmpty || value.isEmpty ? nil : "\(label): \(value.prefix(200))"
        }
    }

    /// True when the article really says it. Years and names must appear in the text; a description and an age
    /// rating are the model's reading of the article, so the description counts and a rating needs the letters.
    nonisolated static func supports(_ article: String, value: String, key: CatalogDetails.Key) -> Bool {
        let text = normalized(article)
        switch key {
        case .summary: return true
        case .year: return value.count == 4 && text.contains(value)
        case .ageRating: return text.contains("rated " + normalized(value)) || text.contains("rating " + normalized(value))
        case .seriesOrder: return text.contains(normalized(value))
        case .creator:
            // "Blender Foundation, Blender Institute": every named part must be there.
            let parts = value.components(separatedBy: CharacterSet(charactersIn: ",;&/")).map(normalized).filter { $0.count >= 2 }
            return !parts.isEmpty && parts.allSatisfy { text.contains($0) }
        default:
            let v = normalized(value)
            return !v.isEmpty && (text.contains(v) || text.contains(v.hasSuffix("s") ? String(v.dropLast()) : v + "s"))
        }
    }

    nonisolated static func normalized(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: 3. The model

    nonisolated static func instructions(for kind: CatalogKind) -> String {
        """
        You fill in catalog details for one item in a family's offline media library. Reply with one JSON object only.
        Rules:
        - If an ARTICLE is given, take each detail from it when it's there, and set "from" to "article" only for values \
        written in the article. Copy names and years exactly as the article writes them.
        - Without an article, fill a detail only if you are certain of it for this exact title, with "from": "knowledge". \
        Many files are home videos, short or independent films, open-source films, school recordings or obscure titles: \
        for anything you don't recognize with certainty, use null for every field. Never work out a studio, series or \
        genre from the words in the title, and never borrow details from a different, better-known title with a similar \
        name. A wrong studio, series or year is much worse than null; an empty field is always acceptable.
        - genre: one broad genre, like Animation, Comedy, Drama, Documentary, Science Fiction, Fantasy, Action, Mystery, \
        Horror, Romance, Family, Rock, Pop, Jazz, Classical, Folk, Children’s, Adventure, Platformer, Puzzle, Sports, Role-playing.
        - subgenre: a narrower genre, or null.
        - creator: the \(kind.creatorLabel.lowercased())\(kind == .video ? " (production company or studio, not a person)" : "").
        - year: four digits, first release.
        - series and series_number: only for a numbered series or franchise; else null.
        - age: G, PG, Teen or Mature, only when the ARTICLE states a rating or audience; otherwise null.
        - summary: one plain sentence of at most 25 words, no spoilers.
        Format (every key required, value null when unknown):
        {"genre":{"value":"…","from":"article"},"subgenre":…,"creator":…,"year":…,"series":…,"series_number":…,"age":…,"summary":…}
        """
    }

    nonisolated static func ask(_ engine: AnswerEngine, target: OrganizeTarget, context: [String], embedded: CatalogDetails,
                                article: Article?) async -> [CatalogDetails.Key: (String, Bool)]? {
        var prompt = "Kind: \(target.kind == .video ? "video (film, show or short)" : target.kind.rawValue)\nTitle: \(cleanTitle(target.title))\n"
        if let creator = target.creatorHint { prompt += "\(target.kind == .music ? "Artist" : "By"): \(creator)\n" }
        prompt += context.joined(separator: "\n") + "\n"
        let known = CatalogDetails.Key.allCases.compactMap { key in embedded[key].map { "\(key.rawValue): \($0.value)" } }
        if !known.isEmpty { prompt += "Already known from the file: " + known.joined(separator: "; ") + "\n" }
        if let article { prompt += "\nARTICLE (“\(article.title)”, from the offline library):\n\(article.text)\n" }
        else { prompt += "\nNo article about it was found in the offline library.\n" }
        var reply = ""
        do { for try await text in engine.stream(instructions: instructions(for: target.kind), prompt: prompt) { reply = text } } catch { return nil }
        guard let json = jsonObject(in: reply) else { return nil }
        let names: [CatalogDetails.Key: String] = [.genre: "genre", .subgenre: "subgenre", .creator: "creator", .year: "year",
                                                    .series: "series", .seriesOrder: "series_number", .ageRating: "age", .summary: "summary"]
        var out: [CatalogDetails.Key: (String, Bool)] = [:]
        for (key, name) in names {
            var raw: Any? = json[name]
            var from = "knowledge"
            if let object = raw as? [String: Any] { raw = object["value"]; from = (object["from"] as? String ?? "knowledge").lowercased() }
            var value: String
            switch raw {
            case let s as String: value = s
            case let n as NSNumber: value = n.stringValue
            default: continue
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = value.lowercased()
            guard !value.isEmpty, !["null", "unknown", "n/a", "none", "?", "-"].contains(lower) else { continue }
            switch key {
            case .year:
                guard let match = value.range(of: #"(1[5-9]|20)\d\d"#, options: .regularExpression) else { continue }
                value = String(value[match])
            case .ageRating:
                guard let rating = CatalogDetails.ageRatings.first(where: { lower.hasPrefix($0.lowercased()) }) else { continue }
                value = rating
            case .seriesOrder:
                guard let number = Double(value.filter { $0.isNumber || $0 == "." }) else { continue }
                value = number == number.rounded() ? String(Int(number)) : String(number)
            default: value = String(value.prefix(key == .summary ? 220 : 80))
            }
            out[key] = (value, from.hasPrefix("article"))
        }
        // A series number without a series means nothing.
        if out[.series] == nil { out[.seriesOrder] = nil }
        return out
    }

    /// The first {...} object in a reply (small models sometimes wrap JSON in prose or code fences).
    nonisolated static func jsonObject(in reply: String) -> [String: Any]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
