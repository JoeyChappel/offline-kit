import SwiftUI

/// Kit: a checkup of the library (dates, space, problems, what's missing), Refresh everything,
/// and on a Mac, Copy my kit.
struct KitCareView: View {
    @Environment(KitNavigation.self) private var navigation
    @Environment(Library.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(MediaLibrary.self) private var media
    @Environment(GameLibrary.self) private var games
    @State private var report: CheckupReport?
    @State private var scanning = false
    @State private var section = CareSection.overview
    @State private var showingRecommendations = false
    private enum CareSection: String, CaseIterable, Identifiable {
        case overview = "Overview", references = "References", storage = "Storage"
        var id: Self { self }
    }
    /// A checkup was asked for while one ran (a fix finished, the library changed): run once more after it.
    @State private var scanAgain = false
    @State private var staleMonths = KitSettings.shared.string(forKey: "staleMonths").flatMap(Int.init) ?? KitCheckup.defaultStaleMonths
    #if os(macOS)
    @State private var copying = false
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    KitHeading(eyebrow: "KIT CARE", title: "Keep your kit ready.",
                               subtitle: "Review problems, check saved references, and manage storage.")
                    Picker("Kit Care section", selection: $section) {
                        ForEach(CareSection.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 620)
                    if let report {
                        switch section {
                        case .overview:
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: 20) {
                                    overviewMain(report).frame(minWidth: 420, maxWidth: .infinity)
                                    overviewSide(report).frame(minWidth: 280, maxWidth: 340)
                                }
                                VStack(alignment: .leading, spacing: 20) { overviewMain(report); overviewSide(report) }
                            }
                        case .references:
                            savedReferences(report)
                            AnswerIndexCard().id("answer-index")
                            RefreshCard().id("refresh")
                            AgesCard(ages: report.ages, staleMonths: $staleMonths).id("ages")
                        case .storage:
                            HealthCard(report: report, rescan: rescan).id("health")
                            SpaceCard(spaces: report.spaces).id("space")
                            #if os(macOS)
                            CopyKitCard { copying = true }.id("copy")
                            #endif
                        }
                        Label("Checks cover saved files; they don’t measure household preparedness.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        // Shaped like the summary and the first cards.
                        VStack(alignment: .leading, spacing: 16) {
                            SkeletonBlock(height: 96, corner: 16)
                            SkeletonBlock(height: 150, corner: 16)
                            SkeletonBlock(height: 110, corner: 16)
                            SkeletonBlock(height: 110, corner: 16)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Checking your kit")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Design.canvas)
            #if DEBUG
            // Test hook: -kitScrollTo health|refresh|copy|ages|recommended|space|answer-index
            .task(id: report == nil) {
                guard report != nil, let target = UserDefaults.standard.string(forKey: "kitScrollTo") else { return }
                if ["refresh", "ages", "answer-index"].contains(target) { section = .references }
                else if ["copy", "space"].contains(target) { section = .storage }
                if target == "recommended" { showingRecommendations = true }
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(target, anchor: .top)
            }
            #endif
        }
        .navigationTitle("Kit Care")
        .toolbar {
            ToolbarItem {
                Button { rescan() } label: { Label("Check Again", systemImage: "stethoscope") }
                    .disabled(scanning || library.isLoading)
                    .help("Run the checkup again")
            }
        }
        .onChange(of: library.isLoading, initial: true) {
            // A library scan can restart while this view appears. Keep the checkup task independent
            // of SwiftUI's task cancellation when that loading flag changes.
            if !library.isLoading { Task { await scan() } }
        }
        .onChange(of: staleMonths) { KitSettings.shared.set(String(staleMonths), forKey: "staleMonths") }
        .onAppear {
            KitRefresh.shared.onReplaced = { Task { await library.reload() } }
            KitRefresh.shared.watch(downloads: downloads)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "kitRefreshCheck") { section = .references }
            if UserDefaults.standard.bool(forKey: "kitConfirmModel") { showingRecommendations = true }
            #endif
        }
        #if os(macOS)
        .sheet(isPresented: $copying) { KitCopySheet() }
        // Settings › Copy Offline Kit to a Drive opens the copy sheet here.
        .onChange(of: navigation.wantsKitCopy, initial: true) {
            guard navigation.wantsKitCopy else { return }
            navigation.wantsKitCopy = false
            copying = true
        }
        #if DEBUG
        .onAppear { if UserDefaults.standard.string(forKey: "kitCopyTo") != nil { copying = true } }
        #endif
        #endif
    }

    private func overviewMain(_ report: CheckupReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HealthCard(report: report, rescan: rescan).id("health")
            savedReferences(report)
            DisclosureGroup(isExpanded: $showingRecommendations) {
                RecommendedCard(rescan: rescan).padding(.top, 12)
            } label: {
                KitCardHeader(symbol: "square.stack.3d.up", title: "Recommended additions",
                              subtitle: "Review emergency essentials, a local map, and an answer model.")
            }.card(padding: 18).id("recommended")
        }
    }

    private func overviewSide(_ report: CheckupReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                KitCardHeader(symbol: "internaldrive", title: "Storage", subtitle: "Room on the drives holding your library.")
                if report.spaces.isEmpty {
                    Text("No library storage found yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(report.spaces) { space in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(space.driveName).font(.headline)
                        Label(space.isLow ? "Low space" : "\(kitBytes(space.free)) free", systemImage: space.isLow ? "exclamationmark.triangle" : "internaldrive")
                            .font(.callout).foregroundStyle(space.isLow ? Color.orange : Color.secondary)
                    }
                }
                Button("View storage", systemImage: "arrow.right") { section = .storage }.buttonStyle(.bordered)
            }.card(padding: 18)
            #if os(macOS)
            CopyKitCard { copying = true }.id("copy")
            #endif
        }
    }

    private func savedReferences(_ report: CheckupReport) -> some View {
        let archives = report.ages.filter { $0.kind != .model }
        let stale = archives.filter { $0.isStale(months: staleMonths) }.count
        let undated = archives.filter { $0.contentDate == nil }.count
        return VStack(alignment: .leading, spacing: 14) {
            Label("Saved references", systemImage: "book.closed").font(.headline)
            if library.books.isEmpty {
                Text("No references saved yet").font(.title3.weight(.semibold))
                Text("Add trusted references before checking for newer editions.").font(.callout).foregroundStyle(.secondary)
                Button("Get Resources", systemImage: "arrow.right") { navigation.getResources() }.buttonStyle(.borderedProminent)
            } else {
                Text("\(library.books.count) saved \(library.books.count == 1 ? "reference or map" : "references and maps")").font(.title3.weight(.semibold))
                Text(stale > 0 ? "\(stale) older than \(staleMonths) months." : "No dated references older than \(staleMonths) months.")
                    .font(.callout).foregroundStyle(stale > 0 ? Color.orange : Color.secondary)
                if undated > 0 { Text("\(undated) \(undated == 1 ? "file has" : "files have") no content date.").font(.caption).foregroundStyle(.secondary) }
                if section != .references {
                    Button("Review references and updates", systemImage: "arrow.right") { section = .references }.buttonStyle(.bordered)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 18)
    }

    private func rescan() {
        Task {
            await library.reload()
            // Fixes can remove files from Media and Games too (broken links, partial downloads).
            await media.reload(library: library)
            await games.reload(library: library)
            KitChanges.shared.modelsChanged()
            await scan()
        }
    }

    private func scan() async {
        // One checkup at a time; a request during one runs it again afterwards, so the report is never older than the fix.
        if scanning { scanAgain = true; return }
        scanning = true
        defer { scanning = false }
        repeat {
            scanAgain = false
            let folders = library.folders
            let books = library.books.map { (archive: $0.archive, url: $0.url, size: $0.fileSize) }
            let models = LocalModels.installed(libraryFolders: folders).filter { !$0.inPlace }
                .map { (url: $0.url, title: $0.shortName, size: $0.size) }
            let unreadable = library.skipped.filter { $0.reason != "Still downloading" }
                .map { CheckupReport.Unreadable(url: $0.url, reason: $0.reason) }
            let files = library.books.map { (url: $0.url, size: $0.fileSize) }
            report = await Task.detached(priority: .userInitiated) {
                CheckupReport(ages: KitCheckup.ages(of: books, models: models),
                              spaces: folders.map(KitCheckup.space(of:)),
                              health: KitCheckup.health(of: folders),
                              olderCopies: KitCheckup.olderCopies(files),
                              unreadable: unreadable)
            }.value
        } while scanAgain
    }
}

struct CheckupReport: Sendable {
    struct Unreadable: Identifiable, Hashable, Sendable {
        let url: URL
        let reason: String
        var id: String { url.path }
    }
    var ages: [KitCheckup.Dated]
    var spaces: [KitCheckup.Space]
    var health: KitCheckup.Health
    var olderCopies: [KitCheckup.OlderCopy]
    var unreadable: [Unreadable]

    var problemCount: Int { health.brokenLinks.count + health.partials.count + olderCopies.count + unreadable.count }
}

/// Card header used across Kit Care.
struct KitCardHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            KitSymbol(symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

func kitBytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

// MARK: - Health

private struct HealthCard: View {
    @Environment(DownloadManager.self) private var downloads
    let report: CheckupReport
    let rescan: () -> Void
    @State private var confirming: Removal?
    @State private var message: String?

    struct Removal: Identifiable {
        let title: String
        let explanation: String
        let files: [(url: URL, size: Int64?)]
        var cancelJobs: [DownloadJob] = []
        var id: String { title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KitCardHeader(symbol: report.problemCount > 0 ? "exclamationmark.triangle" : "stethoscope", title: report.problemCount > 0 ? "Needs attention" : "File check",
                          subtitle: report.problemCount > 0 ? "\(report.problemCount) file issues to review. Nothing is removed until you confirm." : "Checks for unreadable files, broken links and unfinished downloads.")
            Divider()
            if report.problemCount == 0 {
                Label("No saved file issues found.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
            if !report.unreadable.isEmpty {
                section("Won’t open", count: report.unreadable.count, symbol: "exclamationmark.triangle") {
                    ForEach(report.unreadable) { item in
                        issueRow(item.url.lastPathComponent, detail: item.reason, url: item.url, action: "Review damaged file…") {
                            confirming = Removal(title: "Remove damaged archive?", explanation: "This file can’t be opened. You can download it again from Get Resources.", files: [(item.url, size(item.url))])
                        }
                    }
                    if report.unreadable.count > 1 {
                        Button("Remove Damaged Archives…") {
                            confirming = Removal(title: "Remove damaged archives?",
                                                 explanation: "These files can’t be opened. Removing them frees the space; you can download them again from Get Resources.",
                                                 files: report.unreadable.map { ($0.url, size($0.url)) })
                        }
                    }
                }
            }
            if !report.health.brokenLinks.isEmpty {
                section("Broken links", count: report.health.brokenLinks.count, symbol: "link.badge.plus") {
                    ForEach(report.health.brokenLinks) { link in
                        issueRow(link.link.lastPathComponent, detail: "Linked file is missing: \(link.target). Removing this link won’t delete the original file.", url: link.link.deletingLastPathComponent(), action: "Review broken link…") {
                            confirming = Removal(title: "Remove broken link?", explanation: "Only this link is removed. No film, song or book is deleted.", files: [(link.link, nil)])
                        }
                    }
                    if report.health.brokenLinks.count > 1 {
                        Button("Remove Broken Links…") {
                            confirming = Removal(title: "Remove broken links?",
                                                 explanation: "Only the links are removed. They point to nothing, so no film, song or book is deleted.",
                                                 files: report.health.brokenLinks.map { ($0.link, nil) })
                        }
                    }
                }
            }
            if !report.health.partials.isEmpty {
                let active = report.health.partials.filter(isRunning)
                let leftover = report.health.partials.filter { !isRunning($0) }
                section("Unfinished downloads", count: report.health.partials.count, symbol: "arrow.down.circle.dotted") {
                    ForEach(report.health.partials) { partial in
                        if isRunning(partial) {
                            row(partial.fileName, detail: "\(kitBytes(partial.size)) · Downloading now", url: partial.folder)
                        } else {
                            issueRow(partial.fileName, detail: "\(kitBytes(partial.size)) · " + partialStatus(partial), url: partial.folder, action: "Review partial download…") {
                                confirming = partialRemoval([partial])
                            }
                        }
                    }
                    if leftover.count > 1 {
                        Button("Remove Partial Downloads…") { confirming = partialRemoval(leftover) }
                    }
                    if !active.isEmpty {
                        Text("Downloads in progress are left alone.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !report.olderCopies.isEmpty {
                section("Older copies", count: report.olderCopies.count, symbol: "doc.on.doc") {
                    ForEach(report.olderCopies) { copy in
                        issueRow(copy.old.lastPathComponent, detail: "\(kitBytes(copy.size)) · Replaced by \(copy.newer.lastPathComponent)", url: copy.old, action: "Review older copy…") {
                            confirming = Removal(title: "Remove older copy?", explanation: "A newer version is installed beside it. The newer file stays.", files: [(copy.old, copy.size)])
                        }
                    }
                    if report.olderCopies.count > 1 {
                        Button("Remove Older Copies…") {
                            confirming = Removal(title: "Remove older copies?",
                                                 explanation: "A newer version of each is installed beside it. The newer ones stay.",
                                                 files: report.olderCopies.map { ($0.old, $0.size) })
                        }
                    }
                }
            }
        }
        .card(padding: 18)
        #if DEBUG
        // Test hook: -kitShowRemoval YES opens the partial-download removal list (nothing is removed).
        .task {
            guard UserDefaults.standard.bool(forKey: "kitShowRemoval") else { return }
            try? await Task.sleep(for: .seconds(1))
            let leftover = report.health.partials.filter { !isRunning($0) }
            if !leftover.isEmpty { confirming = partialRemoval(leftover) }
        }
        #endif
        .sheet(item: $confirming) { removal in
            RemovalSheet(removal: removal) { remove(removal) }
        }
        .alert("Kit checkup", isPresented: .constant(message != nil)) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func partialRemoval(_ leftover: [KitCheckup.Partial]) -> Removal {
        Removal(title: "Remove partial downloads?",
                explanation: "These downloads didn’t finish. Removing them frees \(kitBytes(leftover.reduce(0) { $0 + $1.size })). Anything paused in Downloads is cancelled.",
                files: leftover.flatMap { $0.files.map { ($0, size($0)) } },
                cancelJobs: leftover.compactMap(job(for:)))
    }

    private func job(for partial: KitCheckup.Partial) -> DownloadJob? {
        downloads.jobs.first { $0.fileName == partial.fileName && $0.folder.standardizedFileURL.path == partial.folder.standardizedFileURL.path && !$0.isFinished }
    }

    private func partialStatus(_ partial: KitCheckup.Partial) -> String {
        guard let job = job(for: partial) else { return "Left over" }
        if case .failed = job.state { return "Stopped in Downloads with an error" }
        return "Paused in Downloads"
    }

    private func isRunning(_ partial: KitCheckup.Partial) -> Bool {
        guard let job = job(for: partial) else { return false }
        return job.isActive || job.state == .queued
    }

    private func size(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    private func remove(_ removal: Removal) {
        confirming = nil
        for job in removal.cancelJobs { downloads.cancel(job) }
        let urls = removal.files.map(\.url)
        Task {
            // Give a cancelled download a moment to let go of its files.
            if !removal.cancelJobs.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            let result = await Task.detached { KitCheckup.remove(urls.filter { (try? $0.checkResourceIsReachable()) == true || (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil }) }.value
            if !result.failed.isEmpty {
                message = "Removed \(result.removed). Couldn’t remove \(result.failed.count): " + result.failed.map { "\($0.0.lastPathComponent) (\($0.1))" }.joined(separator: ", ")
            }
            rescan()
        }
    }

    @ViewBuilder
    private func section(_ title: String, count: Int, symbol: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(title) · \(count)", systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            content()
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 4)
    }

    private func issueRow(_ title: String, detail: String, url: URL, action: String, review: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) { row(title, detail: detail, url: url).frame(minWidth: 240, alignment: .leading); Spacer(minLength: 8); Button(action, action: review) }
            VStack(alignment: .leading, spacing: 8) { row(title, detail: detail, url: url); Button(action, action: review) }
        }.padding(.vertical, 4)
    }

    private func row(_ title: String, detail: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(1).truncationMode(.middle)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .showInFinderMenu(url)
    }
}

/// Lists exactly what will be removed, with a Remove button. Nothing happens until it's pressed.
private struct RemovalSheet: View {
    let removal: HealthCard.Removal
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(removal.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                List(removal.files, id: \.url) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(file.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if let size = file.size { Text(kitBytes(size)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
                .frame(minHeight: 160)
                let total = removal.files.compactMap(\.size).reduce(0, +)
                Text("\(removal.files.count) \(removal.files.count == 1 ? "item" : "items")" + (total > 0 ? " · \(kitBytes(total))" : "") + " · This can’t be undone.")
                    .font(.callout.weight(.medium))
            }
            .padding(20)
            .navigationTitle(removal.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Remove", role: .destructive) { confirm() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 420)
        #endif
    }
}

// MARK: - Ages

private struct AgesCard: View {
    let ages: [KitCheckup.Dated]
    @Binding var staleMonths: Int
    @State private var showAll = false

    var body: some View {
        let stale = ages.filter { $0.isStale(months: staleMonths) }
        let shown = showAll ? ages : Array(ages.prefix(8))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                KitCardHeader(symbol: "calendar", title: "How current is it?",
                              subtitle: "When each reference, map and model was made, oldest first. Refresh everything gets newer versions.")
                Spacer()
                Picker("Flag older than", selection: $staleMonths) {
                    ForEach([6, 12, 18, 24], id: \.self) { Text("\($0) months").tag($0) }
                }
                .fixedSize()
            }
            Divider()
            if ages.isEmpty {
                Text("No references, maps or models saved yet.").foregroundStyle(.secondary)
            } else {
                if !stale.isEmpty {
                    Label("\(stale.count) older than \(staleMonths) months", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange).font(.subheadline.weight(.semibold))
                }
                ForEach(shown) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: item.kind == .map ? "map" : item.kind == .model ? "cpu" : "book.closed")
                            .foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).lineLimit(1)
                            Text(detail(item)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 10)
                        if item.isStale(months: staleMonths) {
                            Pill(text: "Older than \(staleMonths) months", symbol: "clock", tint: .orange)
                        }
                    }
                    .showInFinderMenu(item.url)
                }
                if ages.count > 8 {
                    Button(showAll ? "Show Fewer" : "Show All \(ages.count)") { showAll.toggle() }.buttonStyle(.borderless)
                }
            }
        }
        .card(padding: 18)
    }

    private func detail(_ item: KitCheckup.Dated) -> String {
        guard let date = item.contentDate else { return "\(kitBytes(item.size)) · No date in the file" }
        let when = date.formatted(.dateTime.month(.wide).year())
        if item.kind == .model { return "\(kitBytes(item.size)) · Saved \(when). Model files carry no release date." }
        let months = item.monthsOld() ?? 0
        let age = months < 1 ? "this month" : months == 1 ? "1 month old" : "\(months) months old"
        return "\(kitBytes(item.size)) · Made \(when) (\(age))" + (item.dateSource == "file name" ? " · from the file name" : "")
    }
}

// MARK: - Space

private struct SpaceCard: View {
    let spaces: [KitCheckup.Space]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KitCardHeader(symbol: "internaldrive", title: "Space",
                          subtitle: "What each library folder holds, and the room left on its drive.")
            ForEach(spaces) { space in
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(space.driveName).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(kitBytes(space.total)) used · \(kitBytes(space.free)) free")
                            .font(.callout).monospacedDigit().foregroundStyle(space.isLow ? Color.orange : .secondary)
                    }
                    Text(space.folder.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    bar(space)
                    ForEach(KitCheckup.SpaceKind.allCases.filter { (space.bytes[$0] ?? 0) > 0 }) { kind in
                        HStack(spacing: 8) {
                            Circle().fill(color(kind)).frame(width: 8, height: 8)
                            Label(kind.label, systemImage: kind.symbol).font(.callout)
                            Spacer()
                            Text(kitBytes(space.bytes[kind] ?? 0)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if space.isLow {
                        Label("Running low on space. New downloads may not fit. Remove partial downloads or older copies above, or choose another drive in Get Resources.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .card(padding: 18)
    }

    private func bar(_ space: KitCheckup.Space) -> some View {
        let whole = max(1, space.total + space.free)
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(KitCheckup.SpaceKind.allCases.filter { (space.bytes[$0] ?? 0) > 0 }) { kind in
                    Rectangle().fill(color(kind))
                        .frame(width: max(2, geo.size.width * CGFloat(space.bytes[kind] ?? 0) / CGFloat(whole)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Color.secondary.opacity(0.15))
        .clipShape(Capsule())
    }

    private func color(_ kind: KitCheckup.SpaceKind) -> Color {
        switch kind {
        case .references: .accentColor
        case .maps: .teal
        case .media: .purple
        case .games: .pink
        case .models: .orange
        case .documents: .blue
        case .other: .gray
        }
    }
}

// MARK: - Recommended

private struct RecommendedCard: View {
    @Environment(Library.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(Household.self) private var household
    @Environment(StarterFilms.self) private var films
    @Environment(MediaLibrary.self) private var media
    @Environment(KitNavigation.self) private var navigation
    let rescan: () -> Void
    @State private var catalog: Catalog?
    @State private var catalogMissing = false
    @State private var booksMissing = StarterBooks.missingCount
    /// A download waiting on "Download it?" with its size and the room left, so one click never starts gigabytes.
    @State private var pending: PendingDownload?

    struct PendingDownload: Identifiable {
        let title: String
        let size: Int64
        let folder: URL
        let start: () -> Void
        var id: String { title }
        var free: Int64 { KitCopy.freeSpace(near: folder) }
        var fits: Bool { size < free - (1 << 30) }
    }

    var body: some View {
        let _ = KitChanges.shared.models   // redraw when an answer model is added or removed
        let packs = missingPacks
        let map = areaMap
        let model = LocalModels.installed(libraryFolders: library.folders).isEmpty ? LocalModels.recommended : nil
        let filmsMissing = films.missing.count
        let nothing = packs.isEmpty && map == nil && model == nil && booksMissing == 0 && filmsMissing == 0
        VStack(alignment: .leading, spacing: 10) {
            KitCardHeader(symbol: "sparkles", title: "Recommended, not installed",
                          subtitle: "The emergency essentials, a map for where you live, the answer model and the starter books and films.")
            Divider()
            if catalogMissing {
                Label("Sizes and downloads need the online download list. Connect to the internet and open this again.", systemImage: "wifi.slash")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if nothing && !catalogMissing {
                Label("Everything recommended is installed.", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
            }
            ForEach(packs) { entry in
                item(entry.title, note: "Emergency essentials", size: entry.size, job: downloads.job(named: entry.name)) {
                    confirm(entry.title, size: entry.size, folder: KitStorage.primaryLibrary) {
                        downloads.enqueue(entry, to: KitStorage.primaryLibrary)
                    }
                }
            }
            if let map {
                item(map.title, note: "A map for \(household.data.home.area)", size: map.size, job: downloads.job(named: map.name)) {
                    confirm(map.title, size: map.size, folder: KitStorage.primaryLibrary) {
                        downloads.enqueue(map, to: KitStorage.primaryLibrary)
                    }
                }
            } else if household.data.home.area.trimmingCharacters(in: .whitespaces).isEmpty && !hasMaps {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A map for your area")
                        Text("Add where you live in Prepare › Home to get a suggestion.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Home") { navigation.prepare(.home) }.buttonStyle(.bordered)
                }
            }
            if let model {
                item("Answer model (\(model.shortName))", note: "Lets Ask answer with no internet", size: model.size, job: downloads.job(named: model.id)) {
                    let folder = LocalModels.folder(forLibrary: KitStorage.primaryLibrary)
                    confirm("the answer model", size: model.size, folder: KitStorage.primaryLibrary) {
                        downloads.enqueue(model: model, to: folder)
                    }
                }
            }
            if booksMissing > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(booksMissing) starter \(booksMissing == 1 ? "book" : "books")")
                        Text("Classic books that came with the app. Copied from the app, no internet needed.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Put Back") {
                        Task {
                            await StarterBooks.copyMissing()
                            booksMissing = StarterBooks.missingCount
                            await media.reload(library: library)
                        }
                    }.buttonStyle(.bordered)
                }
            }
            if filmsMissing > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(filmsMissing) free \(filmsMissing == 1 ? "film" : "films") from Blender Studio")
                        Text(filmStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Get · \(kitBytes(films.missingBytes))") {
                        confirm("\(filmsMissing) free \(filmsMissing == 1 ? "film" : "films")", size: films.missingBytes,
                                folder: KitStorage.primaryLibrary) {
                            films.getAll { Task { await media.reload(library: library) } }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDownloadingFilms)
                }
            }
        }
        .card(padding: 18)
        .task { await loadCatalog() }
        #if DEBUG
        // Test hook: -kitConfirmModel YES presses the answer model's Add button (shows the confirmation only).
        .task {
            guard UserDefaults.standard.bool(forKey: "kitConfirmModel"), let model else { return }
            try? await Task.sleep(for: .seconds(2))
            confirm("the answer model", size: model.size, folder: KitStorage.primaryLibrary) {}
        }
        #endif
        .confirmationDialog(pending.map { "Download \($0.title)?" } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { item in
            if item.fits {
                Button("Download \(kitBytes(item.size))") { item.start(); pending = nil }
            }
            Button(item.fits ? "Not Now" : "OK", role: .cancel) { pending = nil }
        } message: { item in
            Text(item.fits
                 ? "It’s \(kitBytes(item.size)) and needs the internet while it downloads. \(kitBytes(item.free)) is free where it will be saved. It downloads in the background and can be paused in Get Resources."
                 : "It’s \(kitBytes(item.size)), but only \(kitBytes(item.free)) is free where it would be saved. Free up some space or choose another drive in Get Resources first.")
        }
    }

    private func confirm(_ title: String, size: Int64, folder: URL, start: @escaping () -> Void) {
        pending = PendingDownload(title: title, size: size, folder: folder, start: start)
    }

    private var filmStatus: String {
        switch films.state {
        case .downloading(let index, let title): "Downloading \(index) of \(films.missing.count + index - 1): \(title)"
        case .failed(let message): message
        default: "Short films that play in Watch."
        }
    }

    private var isDownloadingFilms: Bool { if case .downloading = films.state { true } else { false } }

    private func item(_ title: String, note: String, size: Int64, job: DownloadJob?, add: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let job {
                Pill(text: job.state == .paused ? "Paused" : "\(Int(job.fraction * 100))%", symbol: "arrow.down", tint: .accentColor)
            } else {
                Button("Add · \(kitBytes(size))", action: add).buttonStyle(.bordered)
            }
        }
    }

    private func isInstalled(_ name: String) -> Bool {
        library.books.contains { $0.archive.name == name || $0.archive.name.hasPrefix(name + "_") }
    }

    private var hasMaps: Bool { library.books.contains { $0.archive.name.hasPrefix("maps_") } }

    private var missingPacks: [CatalogEntry] {
        guard let catalog else { return [] }
        let pictures = PictureChoice(rawValue: KitSettings.shared.string(forKey: "pictures") ?? "") ?? .full
        return Interests.all.filter(\.startsSelected).flatMap(\.packs)
            .filter { !isInstalled($0.name) }
            .compactMap { catalog.entry(for: $0.name, pictures: pictures) }
    }

    private var areaMap: CatalogEntry? {
        guard let catalog, !hasMaps else { return nil }
        let names = Set(catalog.entries.map(\.name).filter { $0.hasPrefix("maps_") })
        guard let name = KitCheckup.mapName(forArea: household.data.home.area, mapNames: names) else { return nil }
        return catalog.entry(for: name, pictures: .full)
    }

    /// The cached catalog first (instant, works offline), else the live one.
    private func loadCatalog() async {
        let cache = KitRefresh.catalogCache
        if let data = try? Data(contentsOf: cache), let parsed = try? await Task.detached(operation: { try Catalog.parse(data) }).value,
           !parsed.entries.isEmpty {
            catalog = parsed
            return
        }
        catalog = try? await Catalog.load(cache: cache)
        catalogMissing = catalog == nil
    }
}

// MARK: - Refresh

private struct RefreshCard: View {
    @Environment(Library.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @State private var refresh = KitRefresh.shared
    @State private var network = NetworkWatch.shared
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KitCardHeader(symbol: "arrow.triangle.2.circlepath", title: "Refresh everything",
                          subtitle: "Looks for newer versions of every installed reference and map. You see the list and the total size before anything downloads.")
            Divider()
            HStack(spacing: 12) {
                Button {
                    Task { await refresh.check(books: library.books) }
                } label: {
                    Label(refresh.phase == .checking ? "Checking…" : "Check for Updates", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!network.isOnline || refresh.phase == .checking || library.books.isEmpty)
                if refresh.phase == .checking { ProgressView().controlSize(.small) }
                Spacer()
            }
            if !network.isOnline {
                Label("Checking for updates needs internet. Everything already saved keeps working offline; connect and come back to refresh.",
                      systemImage: "wifi.slash")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            switch refresh.phase {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            case .checked(let when):
                results(checkedAt: when)
            default:
                EmptyView()
            }
            if !refresh.pending.isEmpty {
                Label("\(refresh.pending.count) \(refresh.pending.count == 1 ? "update is" : "updates are") downloading. Each old file is deleted only after its new version is downloaded, checked and opens.",
                      systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DownloadsCard()
            }
            ForEach(Array(refresh.log.suffix(6).enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 18)
        .confirmationDialog("Download \(refresh.updates.count) \(refresh.updates.count == 1 ? "update" : "updates")?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Download \(kitBytes(refresh.totalBytes))") { refresh.start(refresh.updates, downloads: downloads) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("They download in the background and can be paused. Each old version is replaced only once its new file is downloaded and checked.")
        }
        #if DEBUG
        // Test hook: -kitRefreshCheck YES runs the update check when the screen opens (no downloads).
        .task(id: library.books.count) {
            guard UserDefaults.standard.bool(forKey: "kitRefreshCheck"), refresh.phase == .idle, !library.books.isEmpty else { return }
            await refresh.check(books: library.books)
            // -kitRefreshGo YES also downloads what it found (only use on a test library with small updates).
            if UserDefaults.standard.bool(forKey: "kitRefreshGo"), !refresh.updates.isEmpty {
                refresh.start(refresh.updates, downloads: downloads)
            }
        }
        #endif
    }

    @ViewBuilder private func results(checkedAt: Date) -> some View {
        if refresh.updates.isEmpty {
            Label("Everything is up to date. Checked \(checkedAt.formatted(date: .omitted, time: .shortened)).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.tint)
        } else {
            let free = KitCopy.freeSpace(near: KitStorage.primaryLibrary)
            ForEach(refresh.updates) { update in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(update.title).lineLimit(1)
                        Text("\(update.installedDate?.formatted(.dateTime.month(.abbreviated).year()) ?? "Undated") → \(KitCheckup.parseDate(update.entry.issued)?.formatted(.dateTime.month(.abbreviated).year()) ?? update.entry.issued)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(kitBytes(update.entry.size)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(refresh.updates.count) \(refresh.updates.count == 1 ? "update" : "updates") · \(kitBytes(refresh.totalBytes))").font(.headline)
                    Text("Downloads into the same folder as each old file. Old files are freed as each finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download Updates…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!network.isOnline)
            }
            if refresh.totalBytes > free {
                Label("Needs \(kitBytes(refresh.totalBytes)) at once and \(kitBytes(free)) is free. Updates run one at a time and free their old file as they go, but the biggest one needs room for both versions.",
                      systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        if !refresh.unmatched.isEmpty {
            Text("Not checked (not in the online download list, or renamed): \(refresh.unmatched.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Copy (card)

#if os(macOS)
private struct CopyKitCard: View {
    let open: () -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                heading.frame(minWidth: 300)
                Spacer()
                copyButton
            }
            VStack(alignment: .leading, spacing: 14) { heading; copyButton }
        }
        .card(padding: 18)
    }

    private var heading: some View {
        KitCardHeader(symbol: "externaldrive.badge.plus", title: "Copy my kit",
                      subtitle: "Make a checked copy on another drive or in a folder, including the app. " + Self.privacyNote)
    }
    private var copyButton: some View { Button("Copy My Kit…", action: open).buttonStyle(.borderedProminent) }

    /// Where the private household details are, which the copy never includes.
    static var privacyNote: String {
        PrivateStore.usesPassphrase
            ? "Your private household info stays on this drive, locked with your passphrase, and isn’t copied."
            : "Your private household info stays on this Mac and isn’t copied."
    }
}
#endif
