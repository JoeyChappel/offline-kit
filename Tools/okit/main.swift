import Foundation

// Test harness for the shared core: same retrieval and engines as the app.
// usage: okit [--engine apple|ollama|builtIn|auto] [--model <id>] [--sources-only] "question"
//        okit --bench <questions.txt> [--ttfw] [--out results.json]   retrieval and first-word timings
//        OFFLINEKIT_GREEDY=1 okit --llama-bench <questions.txt> [--tokens 128] [--out r.json]   model speed and memory
//        okit --html-check <file.zim> [--limit N] [--articles N]   HTML-to-text against the old regular expressions
//        okit --index-bench <file.zim> [--limit N] [--depth full|leads] [--questions q.txt] [--reuse]   index build and query timings
//        okit --models                      list answer models (Models folders + ones used in place)
//        okit --add-model <file.gguf> [place]  check and add a GGUF (copies into the library unless "place")

@MainActor
func run() async {
    var args = Array(CommandLine.arguments.dropFirst())
    var choice = EngineChoice.auto
    var sourcesOnly = false
    var builtInModel: String?
    while let first = args.first, first.hasPrefix("--") {
        args.removeFirst()
        switch first {
        case "--engine": choice = EngineChoice(rawValue: args.removeFirst()) ?? .auto
        case "--sources-only": sourcesOnly = true
        case "--model": builtInModel = args.removeFirst()
        case "--index-bench":
            let zim = args.removeFirst()
            let limit = args.firstIndex(of: "--limit").flatMap { Int(args[$0 + 1]) }
            let depth = args.firstIndex(of: "--depth").flatMap { AnswerIndexPolicy.Depth(rawValue: args[$0 + 1]) }
            let questions = args.firstIndex(of: "--questions").map { args[$0 + 1] }
            // --qos background|utility measures at the builder's own priority.
            let qos: QualityOfService = switch args.firstIndex(of: "--qos").map({ args[$0 + 1] }) {
            case "background": .background
            case "utility": .utility
            default: .userInitiated
            }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let thread = Thread {
                    IndexBench.run(zim: zim, limit: limit, depth: depth, questionsFile: questions, reuse: args.contains("--reuse"))
                    done.resume()
                }
                thread.qualityOfService = qos
                thread.stackSize = 8 << 20
                thread.start()
            }
            return
        case "--html-check":
            let zim = args.removeFirst()
            HTMLCheck.run(zim: zim, limit: args.firstIndex(of: "--limit").flatMap { Int(args[$0 + 1]) },
                          articles: args.firstIndex(of: "--articles").flatMap { Int(args[$0 + 1]) } ?? .max)
            return
        case "--llama-bench":
            let file = args.removeFirst()
            let tokens = args.firstIndex(of: "--tokens").flatMap { Int(args[$0 + 1]) } ?? 128
            let out = args.firstIndex(of: "--out").map { args[$0 + 1] }
            await LlamaBench.run(questionsFile: file, maxTokens: tokens, out: out)
            return
        case "--prefix-check":
            await Bench.prefixCheck(questionsFile: args.removeFirst())
            return
        case "--bench":
            let file = args.removeFirst()
            let ttfw = args.contains("--ttfw")
            let out = args.firstIndex(of: "--out").map { args[$0 + 1] }
            await Bench.run(questionsFile: file, ttfw: ttfw, out: out)
            return
        case "--models":
            let library = Library(); await library.reload()
            let chosen = KitSettings.shared.string(forKey: "builtInModel") ?? ""
            print("Memory budget: \(ModelFit.gigabytes(ModelFit.memoryBudget))")
            for m in LocalModels.installed(libraryFolders: library.folders) {
                let mark = LocalModels.selected(libraryFolders: library.folders, id: chosen) == m ? "*" : " "
                print("\(mark) \(m.id)  \(m.shortName)  [\(m.summary)]  \(m.plan)\(m.inPlace ? "  (in place)" : "")\n    \(m.url.path)")
                if let i = m.info {
                    print("    arch=\(i.architecture) ctx=\(i.contextLength ?? 0) layers=\(i.layers ?? 0) kvHeads=\(i.kvHeads ?? 0) kv/token=\(i.kvBytesPerToken) template=\(i.chatTemplate.map { "\($0.count) chars" } ?? "none")")
                }
            }
            return
        case "--add-model":
            let file = URL(fileURLWithPath: args.removeFirst())
            let inPlace = args.first == "place"
            do {
                let (info, size) = try LocalModels.check(file)
                print("OK \(info.displayName ?? file.lastPathComponent): \(ModelFit.gigabytes(size)), \(info.parameterText ?? "?"), \(info.quantization ?? "?"), \(ModelFit.plan(info: info, fileSize: size))")
                let id = try LocalModels.add(file, toLibrary: KitStorage.primaryLibrary, inPlace: inPlace)
                KitSettings.shared.set(id, forKey: "builtInModel")
                print("Added as \(id)\(inPlace ? " (in place)" : " to \(LocalModels.folder(forLibrary: KitStorage.primaryLibrary).path)")")
            } catch {
                print("REFUSED: \(error.localizedDescription)")
            }
            return
        case "--catalog":
            let cache = FileManager.default.temporaryDirectory.appending(path: "okit-catalog.xml")
            let catalog = try! await Catalog.load(cache: cache)
            print("Catalog: \(catalog.entries.count) entries")
            for interest in Interests.all {
                print("\n\(interest.title)")
                for pack in interest.packs {
                    if let e = catalog.entry(for: pack.name, pictures: .full) {
                        print("  \(pack.label): \(e.fileName) \(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))")
                    } else {
                        print("  \(pack.label): MISSING (\(pack.name))")
                    }
                }
            }
            for pack in Interests.encyclopedia {
                let e = catalog.entry(for: pack.name, pictures: .noPictures)
                print("Encyclopedia \(pack.label): \(e?.fileName ?? "MISSING")")
            }
            return
        case "--download":
            // okit --download <name> <folder> [full|noPictures|summaries]
            let name = args.removeFirst(), folder = URL(fileURLWithPath: args.removeFirst())
            let pictures = args.first.flatMap(PictureChoice.init(rawValue:)) ?? .full
            let cache = FileManager.default.temporaryDirectory.appending(path: "okit-catalog.xml")
            let catalog = try! await Catalog.load(cache: cache)
            guard let entry = catalog.entry(for: name, pictures: pictures) else { print("not in catalog"); return }
            let meta = try! await Metalink.fetch(entry.metalink)
            print("\(meta.fileName): \(meta.size) bytes, \(meta.mirrors.count) mirrors, \(meta.pieceSHA1.count) pieces of \(meta.pieceLength ?? 0)")
            let dl = ChunkedDownload(metalinkURL: entry.metalink, title: entry.title, meta: meta, folder: folder)
            let start = Date()
            do {
                let url = try await dl.run { p in
                    let pct = p.total > 0 ? Double(p.done) / Double(p.total) * 100 : 0
                    print(String(format: "  %@ %.1f%% %.1f MB/s mirrors=%d", "\(p.phase)", pct, p.bytesPerSecond / 1e6, p.mirrorsActive))
                }
                print(String(format: "DONE %@ in %.1fs", url.path, Date().timeIntervalSince(start)))
            } catch {
                print("FAILED: \(error.localizedDescription)")
            }
            return
        case "--download-model":
            // okit --download-model gemma-4-e4b <library folder>   (saves into <folder>/Models)
            let id = args.removeFirst(), library = URL(fileURLWithPath: args.removeFirst())
            guard let model = LocalModels.model(id: id) else { print("unknown model; try: \(LocalModels.all.map(\.id))"); return }
            let dl = ChunkedDownload(metalinkURL: model.url, title: model.title, meta: model.metalink,
                                     folder: LocalModels.folder(forLibrary: library))
            let start = Date()
            let throttle = PrintThrottle()
            do {
                let url = try await dl.run { p in
                    guard throttle.due(seconds: 15, always: p.phase != .downloading) else { return }
                    print(String(format: "  %@ %.1f%% %.1f MB/s", "\(p.phase)", Double(p.done) / Double(max(p.total, 1)) * 100, p.bytesPerSecond / 1e6))
                }
                print(String(format: "DONE %@ in %.0fs (SHA-256 verified)", url.path, Date().timeIntervalSince(start)))
            } catch {
                print("FAILED: \(error.localizedDescription)")
            }
            return
        case "--epub":
            guard let path = args.first, let (book, zip) = EPUBBook.open(URL(fileURLWithPath: path)) else { print("could not open"); return }
            print("title: \(book.title)\nauthor: \(book.author ?? "-")\nsubjects: \(book.subjects)\ncover: \(book.coverPath ?? "-") \(book.coverPath.flatMap { zip.data($0)?.count } ?? 0) bytes")
            for c in book.chapters { print("chapter: \(c.title) [\(c.path)] \(zip.data(c.path)?.count ?? -1) bytes") }
            return
        case "--reload-stress":
            let library = Library()
            let fds = { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
            print("start: \(fds()) open files")
            for pass in 1...5 {
                await library.reload()
                print("pass \(pass): \(library.books.count) books, \(fds()) open files, skipped \(library.skipped.count)")
            }
            // Overlapping calls, as happens at app launch.
            async let a: Void = library.reload(); async let b: Void = library.reload(); async let c: Void = library.reload()
            _ = await (a, b, c)
            print("overlapping: \(library.books.count) books, \(fds()) open files")
            for s in library.skipped { print("skipped \(s.url.lastPathComponent): \(s.reason)") }
            return
        case "--pdfs":
            let library = Library(); await library.reload()
            for b in library.books {
                let pdfs = b.archive.entries(withMimePrefix: "application/pdf", limit: 500)
                if !pdfs.isEmpty { print("\(b.title): \(pdfs.count) PDFs, e.g. \(pdfs.prefix(3).map(\.title))") }
            }
            return
        case "--suggest":
            let q = args.joined(separator: " ")
            let library = Library(); await library.reload()
            for b in library.books {
                for h in b.archive.suggest(q, limit: 3) { print("suggest \(b.title): \(h.title) [\(h.path)]") }
                for h in b.archive.search(q, limit: 3) { print("search  \(b.title): \(h.title) score=\(h.score)") }
            }
            return
        default: break
        }
    }
    let question = args.joined(separator: " ")

    let library = Library()
    await library.reload()
    print("Archives: \(library.books.map(\.title).joined(separator: ", "))")
    for s in library.skipped { print("Skipped: \(s.url.lastPathComponent) (\(s.reason))") }
    guard !question.isEmpty else { return }

    let model = AskModel()
    model.choice = choice
    if let builtInModel { model.builtInModel = builtInModel }
    if sourcesOnly {
        // Wait for PDF libraries to be read (first run builds the cache).
        await Bench.prepare(library: library)
        let start = Date()
        let sources = Retriever.retrieve(question: question, archives: library.books.map(\.archive), budgetChars: 5000)
        print(String(format: "Retrieved %d sources in %.2fs", sources.count, Date().timeIntervalSince(start)))
        for s in sources { print("[\(s.id)] \(s.ref.title) (\(s.bookTitle)) \(s.text.count) chars\n    \(s.text.prefix(160))…") }
        return
    }
    let start = Date()
    model.ask(question, library: library)
    while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
    guard let turn = model.turns.last else { return }
    print("Engine: \(turn.engine)  (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
    for s in turn.sources { print("[\(s.id)] \(s.ref.title) · \(s.bookTitle)") }
    if let e = turn.error { print("ERROR: \(e)") }
    print("\n\(turn.answer)")
}

/// At most one progress line every few seconds, from whichever thread reports progress.
final class PrintThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func due(seconds: TimeInterval, always: Bool = false) -> Bool {
        lock.withLock {
            guard always || Date().timeIntervalSince(last) > seconds else { return false }
            last = Date()
            return true
        }
    }
}

await run()
LlamaRuntime.shared.shutdown()
