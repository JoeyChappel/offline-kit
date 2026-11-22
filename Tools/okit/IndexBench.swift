import Foundation

/// Answer-index build and query measurements on one archive, outside the app's background builder.
/// usage: okit --index-bench <file.zim> [--limit N] [--depth full|leads] [--questions q.txt]
///   Times reading, HTML-to-text and passage splitting per article, then writes the passages into a scratch
///   PassageStore (in the test home's caches) and times queries over the question list.
enum IndexBench {
    static func run(zim: String, limit: Int?, depth forced: AnswerIndexPolicy.Depth?, questionsFile: String?, reuse: Bool = false) {
        guard let archive = try? ZimArchive(path: zim) else { print("can't open \(zim)"); return }
        let depth = forced ?? AnswerIndexPolicy.depth(articleCount: Int(archive.articleCount))
        let total = min(Int(archive.entryCount), limit ?? Int.max)
        print("\(archive.title): \(archive.articleCount) articles, \(archive.entryCount) entries, depth \(depth.rawValue)")
        let url = KitLocation.caches.appending(path: "OfflineKit/index-bench.sqlite")
        if !reuse { for suffix in ["", "-journal", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        guard let store = try? PassageStore(url: url, depth: depth) else { print("can't create store"); return }
        defer { store.close() }
        if reuse { query(store, questionsFile); return }

        let chunk = AnswerIndexPolicy.chunk(depth), maxBytes = AnswerIndexPolicy.maxHTMLBytes(depth)
        var read = 0.0, text = 0.0, write = 0.0, articles = 0, passages = 0, htmlBytes = 0, leadChars = 0
        var cursor = 0
        let start = Date()
        while cursor < total {
            let t0 = Date()
            let batch = autoreleasepool { () -> [(path: String, title: String, passages: [PassageStore.Draft])] in
                let found = archive.articles(from: UInt(cursor), count: UInt(min(chunk, total - cursor)), maxBytes: UInt(maxBytes))
                let t1 = Date()
                read += t1.timeIntervalSince(t0)
                let out = PassageStore.drafts(found, depth: depth)
                for a in found { htmlBytes += a.html.count }
                text += Date().timeIntervalSince(t1)
                return out
            }
            articles += batch.count
            passages += batch.reduce(0) { $0 + $1.passages.count }
            leadChars += batch.reduce(0) { $0 + ($1.passages.first?.text.utf8.count ?? 0) }
            cursor += chunk
            let t2 = Date()
            try? store.append(batch, cursor: cursor, seconds: 0)
            write += Date().timeIntervalSince(t2)
            if articles > 0, articles % 50_000 < batch.count {
                print(String(format: "  %d articles, %.0f/s, %.1f MB", articles, Double(articles) / Date().timeIntervalSince(start), Double(store.bytes) / 1e6))
            }
        }
        let t3 = Date()
        store.optimize()
        let optimize = Date().timeIntervalSince(t3)
        let elapsed = Date().timeIntervalSince(start)
        let bytes = store.bytes
        print(String(format: "Indexed %d articles (%d passages, %.1f MB of HTML read) in %.1fs: %.0f articles/s", articles, passages,
                     Double(htmlBytes) / 1e6, elapsed, Double(articles) / elapsed))
        print(String(format: "  per article: read %.3f ms, HTML to passages %.3f ms, write %.3f ms; optimize %.1fs",
                     read * 1000 / Double(max(articles, 1)), text * 1000 / Double(max(articles, 1)),
                     write * 1000 / Double(max(articles, 1)), optimize))
        print(String(format: "  index %.1f MB: %.0f bytes per article, %.0f bytes per passage; lead text %.0f chars per article",
                     Double(bytes) / 1e6, Double(bytes) / Double(max(articles, 1)), Double(bytes) / Double(max(passages, 1)),
                     Double(leadChars) / Double(max(articles, 1))))

        query(store, questionsFile)
    }

    /// Times the index's search over each question (second of two passes, so word counts are remembered).
    static func query(_ store: PassageStore, _ questionsFile: String?) {
        guard let questionsFile else { return }
        let questions = ((try? String(contentsOfFile: questionsFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var times: [Double] = []
        for pass in 0..<2 {
            for q in questions {
                let terms = Retriever.terms(q)
                let s = Date()
                let hits = store.search(terms: terms, phrases: Retriever.phrases(terms), limit: Retriever.indexHits)
                let ms = Date().timeIntervalSince(s) * 1000
                if pass == 1 {
                    times.append(ms)
                    print(String(format: "  %7.2f ms %4d hits  %@  [%@]", ms, hits.count, q, hits.prefix(2).map(\.title).joined(separator: " | ")))
                }
            }
        }
        let sorted = times.sorted()
        if !sorted.isEmpty {
            print(String(format: "Index query (ms): median %.2f  p90 %.2f  max %.2f", sorted[sorted.count / 2],
                         sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)], sorted.last!))
        }
    }
}

/// Checks the byte scanner against the regular expressions it replaced, article by article, and times both.
/// usage: okit --html-check <file.zim> [--limit N entries] [--articles N]
///   OFFLINEKIT_HTML_LIST=1 lists every article that differs (to compare two builds); OFFLINEKIT_HTML_ONLY=<path>
///   checks that one article.
enum HTMLCheck {
    static let listsDifferences = ProcessInfo.processInfo.environment["OFFLINEKIT_HTML_LIST"] != nil
    static let onlyPath = ProcessInfo.processInfo.environment["OFFLINEKIT_HTML_ONLY"]

    static func run(zim: String, limit: Int?, articles wanted: Int = .max) {
        guard let archive = try? ZimArchive(path: zim) else { print("can't open \(zim)"); return }
        let total = min(Int(archive.entryCount), limit ?? Int.max)
        var cursor = 0, articles = 0, bytes = 0
        var same = [0, 0], different = [0, 0], shown = 0
        var oldTime = 0.0, newTime = 0.0
        while cursor < total, articles < wanted {
            autoreleasepool {
                for article in archive.articles(from: UInt(cursor), count: UInt(min(200, total - cursor)), maxBytes: UInt(AnswerIndexPolicy.maxHTMLBytes(.full))) {
                    if let only = onlyPath, article.path != only { continue }
                    articles += 1
                    bytes += article.html.count
                    for (k, leads) in [false, true].enumerated() {
                        let t0 = Date()
                        var html = String(decoding: article.html, as: UTF8.self)
                        if leads { html = LegacyHTMLText.leadHTML(html) }
                        let old = LegacyHTMLText.sections(html)
                        let t1 = Date()
                        let new: [(heading: String?, text: String)] = article.html.withUnsafeBytes { raw in
                            let all = raw.bindMemory(to: UInt8.self)
                            return HTMLText.sections(utf8: leads ? UnsafeBufferPointer(rebasing: all[..<PassageStore.leadEnd(all)]) : all)
                        }
                        let t2 = Date()
                        if !leads { oldTime += t1.timeIntervalSince(t0); newTime += t2.timeIntervalSince(t1) }
                        if old.count == new.count && zip(old, new).allSatisfy({ $0.heading == $1.heading && $0.text == $1.text }) {
                            same[k] += 1
                        } else {
                            different[k] += 1
                            if listsDifferences { print("different (\(leads ? "lead" : "full")) \(article.path)") }
                            if shown < 4 {
                                shown += 1
                                print("DIFFERENT (\(leads ? "lead" : "full")) \(article.path): \(old.count) vs \(new.count) paragraphs")
                                for (i, (o, n)) in zip(old, new).enumerated() where o.heading != n.heading || o.text != n.text {
                                    print("  old[\(i)] \(o.heading ?? "-") | \(o.text.prefix(300))\n  new[\(i)] \(n.heading ?? "-") | \(n.text.prefix(300))")
                                    break
                                }
                                if old.count != new.count {
                                    print("  old tail: \(old.suffix(1).map { $0.text.prefix(200) })\n  new tail: \(new.suffix(1).map { $0.text.prefix(200) })")
                                }
                            }
                        }
                    }
                }
            }
            cursor += 200
        }
        print(String(format: "%@: %d articles (%.0f KB of HTML each): full text same %d, different %d; lead same %d, different %d",
                     archive.title, articles, Double(bytes) / Double(max(articles, 1)) / 1024, same[0], different[0], same[1], different[1]))
        print(String(format: "  regular expressions %.3f ms an article, byte scanner %.3f ms (%.1fx)",
                     oldTime * 1000 / Double(max(articles, 1)), newTime * 1000 / Double(max(articles, 1)), oldTime / max(newTime, 1e-9)))
    }
}
