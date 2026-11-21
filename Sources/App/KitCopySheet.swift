#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// Copy my kit: choose a drive or folder, see what will happen, copy with checks, read the report.
struct KitCopySheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var copier = KitCopier.shared
    @State private var sources: Set<URL> = []
    @State private var includeApp = true
    @State private var destination: URL?
    @State private var choosingFolder = false
    @State private var replaceConfirmed = false
    @State private var showSkipped = false
    #if DEBUG
    @State private var redid = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch copier.phase {
                    case .idle, .planning: setup
                    case .ready: review
                    case .copying, .paused, .verifying: progress
                    case .finished, .stopped: finished
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Design.canvas)
            .navigationTitle("Copy my kit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copier.isBusy ? "Hide" : "Close") { dismiss() }
                        .help(copier.isBusy ? "The copy keeps going. Open Copy My Kit again to see it." : "")
                }
            }
        }
        .frame(width: 640, height: 640)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { destination = url; copier.reset() }
        }
        .onAppear {
            if sources.isEmpty { sources = Set(library.folders) }
            #if DEBUG
            // Test hooks: -kitCopyTo <folder> plans a copy there; -kitCopyGo YES starts it (no replacements);
            // -kitCopyVerify YES checks the copy again once it's done (or right away if nothing needs copying).
            if let path = UserDefaults.standard.string(forKey: "kitCopyTo"), copier.phase == .idle {
                destination = URL(fileURLWithPath: path, isDirectory: true)
                includeApp = UserDefaults.standard.string(forKey: "kitCopyApp") != "NO"
                Task {
                    await prepare()
                    if UserDefaults.standard.bool(forKey: "kitCopyGo") {
                        if copier.plan?.toCopy.isEmpty == false {
                            copier.start(replace: false)
                            // -kitCopyPauseTest YES: pause shortly after starting, then resume 6 seconds later.
                            if UserDefaults.standard.bool(forKey: "kitCopyPauseTest") {
                                try? await Task.sleep(for: .milliseconds(150))
                                copier.pause()
                                try? await Task.sleep(for: .seconds(6))
                                copier.resume()
                            }
                        }
                        else if UserDefaults.standard.bool(forKey: "kitCopyVerify") { copier.verifyAgain() }
                    }
                }
            }
            #endif
        }
        #if DEBUG
        .onChange(of: copier.phase) {
            if copier.phase == .finished, copier.recheck == nil, UserDefaults.standard.bool(forKey: "kitCopyVerify") { copier.verifyAgain() }
            // -kitCopyRedo YES: after a check finds mismatches, copy those again once (then the check above runs again).
            if copier.phase == .finished, let recheck = copier.recheck, !recheck.mismatched.isEmpty, !redid,
               UserDefaults.standard.bool(forKey: "kitCopyRedo") {
                redid = true
                Task { await copier.recopyMismatched() }
            }
        }
        #endif
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            KitHeading(eyebrow: "SHARE YOUR KIT", title: "Copy my kit.",
                       subtitle: "Copies your library to another drive or folder so it works on another Mac. Every file is checked against the original after it’s copied. Nothing here is changed or deleted.")
            privacyNote
            VStack(alignment: .leading, spacing: 8) {
                Text("What to copy").font(.headline)
                ForEach(library.folders, id: \.self) { folder in
                    Toggle(isOn: Binding(get: { sources.contains(folder) },
                                         set: { if $0 { sources.insert(folder) } else { sources.remove(folder) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(driveName(folder))
                            Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Toggle("Include the Offline Kit app, so the copy opens on a Mac that doesn’t have it", isOn: $includeApp)
                Text("Unfinished downloads aren’t copied. More than one library folder is combined into one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .card(padding: 16)
            VStack(alignment: .leading, spacing: 8) {
                Text("Where to").font(.headline)
                ForEach(drives, id: \.self) { drive in
                    Button { destination = drive; copier.reset() } label: {
                        HStack {
                            Image(systemName: destination == drive ? "largecircle.fill.circle" : "circle").foregroundStyle(.tint)
                            Label("\(driveName(drive)) · \(kitBytes(KitCopy.freeSpace(near: drive))) free", systemImage: "externaldrive")
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                HStack {
                    Button("Choose a Folder…") { choosingFolder = true }
                    if let destination, !drives.contains(destination) {
                        Text(destination.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                if let destination {
                    Text("The copy goes in \(KitCopy.kitFolder(in: destination).path). Plugged into another Mac, Offline Kit finds it there.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let problem = destinationProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            }
            .card(padding: 16)
            HStack {
                Spacer()
                if copier.phase == .planning { ProgressView().controlSize(.small); Text("Looking at what to copy…").foregroundStyle(.secondary) }
                Button("Next") { Task { await prepare() } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(destination == nil || sources.isEmpty || destinationProblem != nil || copier.phase == .planning)
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill").foregroundStyle(.tint).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your private info stays here").font(.headline)
                Text("People, health notes, contacts and saved answers in Prepare are encrypted with a key kept in this Mac’s keychain. The copy won’t include them, and the key can’t be exported. Whoever gets the copy starts with an empty Prepare.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(padding: 16)
    }

    // MARK: Review

    @ViewBuilder private var review: some View {
        if let plan = copier.plan {
            KitHeading(eyebrow: "BEFORE COPYING", title: "Here’s the plan.",
                       subtitle: "To \(copier.destinationKit?.path ?? "")")
            VStack(alignment: .leading, spacing: 10) {
                fact("To copy", "\(plan.toCopy.count) \(plan.toCopy.count == 1 ? "file" : "files") · \(kitBytes(plan.toCopy.reduce(0) { $0 + $1.size }))")
                fact("Already there", "\(plan.identical.count) \(plan.identical.count == 1 ? "file" : "files") with the same size and date, skipped")
                fact("Free at destination", kitBytes(plan.freeAtDestination))
                if !plan.skipped.isEmpty {
                    DisclosureGroup("Not copied · \(plan.skipped.count)", isExpanded: $showSkipped) {
                        ForEach(plan.skipped, id: \.self) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.relative).lineLimit(1).truncationMode(.middle)
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .card(padding: 16)
            if !plan.replacing.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(plan.replacing.count) \(plan.replacing.count == 1 ? "file" : "files") at the destination differ from yours", systemImage: "exclamationmark.triangle")
                        .font(.headline).foregroundStyle(.orange)
                    ForEach(plan.replacing.prefix(12), id: \.self) { item in
                        Text(item.relative).font(.callout).lineLimit(1).truncationMode(.middle)
                    }
                    if plan.replacing.count > 12 { Text("and \(plan.replacing.count - 12) more").font(.caption).foregroundStyle(.secondary) }
                    Toggle("Replace these with my versions (the ones there now are deleted)", isOn: $replaceConfirmed)
                    Text("Leave this off to keep them as they are; everything else still copies.").font(.caption).foregroundStyle(.secondary)
                }
                .card(padding: 16)
            }
            if !plan.tooBigForFAT32.isEmpty {
                Label("This drive is formatted FAT32, which can’t hold files over 4 GB. \(plan.tooBigForFAT32.count) files are bigger. Reformat it as exFAT or APFS first.",
                      systemImage: "xmark.octagon").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            let needed = plan.toCopy.reduce(0) { $0 + $1.size } + (replaceConfirmed ? plan.replacing.reduce(0) { $0 + $1.size } : 0)
            let fits = plan.freeAtDestination > needed + (256 << 20)
            if !fits {
                Label("Not enough space: needs \(kitBytes(needed)), \(kitBytes(plan.freeAtDestination)) is free. Choose another drive or copy fewer folders.",
                      systemImage: "xmark.octagon").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Back") { copier.reset() }
                Spacer()
                Button(needed == 0 ? "Nothing to Copy" : "Copy \(kitBytes(needed))") { copier.start(replace: replaceConfirmed) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!fits || !plan.tooBigForFAT32.isEmpty || needed == 0)
                if needed == 0 && plan.identical.count > 0 {
                    Button("Check the Copy") { copier.verifyAgain() }.controlSize(.large)
                }
            }
        }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            KitHeading(eyebrow: copier.recheck == nil && copier.phase != .verifying ? "COPYING" : "CHECKING",
                       title: copier.phase == .paused ? "Paused." : copier.phase == .verifying ? "Checking the copy…" : "Copying your kit…",
                       subtitle: "Each file is read back from the destination and compared to the original.")
            ProgressView(value: copier.fraction)
            HStack {
                Text("\(kitBytes(copier.bytesDone / 2)) of \(kitBytes(copier.bytesTotal / 2))").monospacedDigit()
                Spacer()
                if copier.phase != .paused {
                    Text(copier.secondsLeft.map(DownloadSummary.timeLeft) ?? "working out time left…")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            Text(copier.current).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            HStack {
                if copier.phase == .paused {
                    Button("Resume", systemImage: "play.fill") { copier.resume() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Pause", systemImage: "pause.fill") { copier.pause() }
                }
                Button("Stop", role: .destructive) { copier.stop() }
                Spacer()
            }
            Text("You can close this window; the copy keeps going. Stopped copies pick up where they left off: files already copied are skipped next time.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Report

    @ViewBuilder private var finished: some View {
        let outcome = copier.outcome
        if let recheck = copier.recheck {
            KitHeading(eyebrow: "CHECK",
                       title: recheck.stopped && recheck.mismatched.isEmpty ? "Check stopped: \(recheck.checked) of \(recheck.total) checked."
                            : recheck.mismatched.isEmpty ? "Every file matches." : "Some files don’t match.",
                       subtitle: recheck.stopped ? "You stopped the check early, so the rest of the files weren’t read. Run it again to check them all."
                                                 : "Read every file on both sides again and compared checksums.")
            VStack(alignment: .leading, spacing: 8) {
                fact("Checked", "\(recheck.checked) \(recheck.checked == 1 ? "file" : "files")")
                fact("Match", "\(recheck.checked - recheck.mismatched.filter { $0.reason == "Doesn’t match the original" }.count)")
                if !recheck.mismatched.isEmpty {
                    Divider()
                    ForEach(recheck.mismatched, id: \.self) { item in failure(item) }
                }
            }
            .card(padding: 16)
            HStack {
                if !recheck.mismatched.isEmpty {
                    Button("Copy These Again") { Task { await copier.recopyMismatched() } }.buttonStyle(.borderedProminent)
                }
                Spacer()
                showButton
                Button("Done") { copier.reset(); dismiss() }
            }
        } else {
            let ok = outcome.failures.isEmpty && copier.phase == .finished
            KitHeading(eyebrow: "REPORT", title: copier.phase == .stopped ? "Copy stopped." : ok ? "Your kit is copied." : "Copied, with problems.",
                       subtitle: copier.destinationKit?.path ?? "")
            VStack(alignment: .leading, spacing: 8) {
                if let plan = copier.plan {
                    fact("Files", "\(outcome.copied) copied · \(plan.identical.count) already there")
                    fact("Size copied", kitBytes(copier.bytesTotal / 2))
                }
                fact("Verified OK", "\(outcome.verified) of \(outcome.copied)")
                fact("Failures", "\(outcome.failures.count)")
                if !copier.leftAlone.isEmpty { fact("Left as they were", "\(copier.leftAlone.count) (you chose not to replace them)") }
                if let skipped = copier.plan?.skipped, !skipped.isEmpty { fact("Not copied", "\(skipped.count) (private data, unfinished downloads, broken links, damaged archives)") }
                if !outcome.failures.isEmpty {
                    Divider()
                    ForEach(outcome.failures, id: \.self) { item in failure(item) }
                }
            }
            .card(padding: 16)
            privacyNote
            HStack {
                Button("Check the Copy Again") { copier.verifyAgain() }
                    .help("Reads every file on both sides again and compares them. Takes about as long as the copy.")
                Spacer()
                showButton
                Button("Done") { copier.reset(); dismiss() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var showButton: some View {
        Button("Show in Finder") {
            if let kit = copier.destinationKit { NSWorkspace.shared.activateFileViewerSelecting([kit]) }
        }
    }

    private func failure(_ item: KitCopy.Skipped) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(item.relative, systemImage: "xmark.circle.fill").foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
            Text(item.reason).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }

    // MARK: Logic

    /// Connected drives other than this Mac's (where a kit copy can go), as volume roots.
    private var drives: [URL] {
        SaveLocation.available().filter { $0.symbol == "externaldrive" }
            .map { $0.folder.deletingLastPathComponent().deletingLastPathComponent() }
    }

    private func driveName(_ url: URL) -> String {
        (try? KitCopy.nearestExisting(url).resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? url.lastPathComponent
    }

    /// The destination can't be one of the libraries being copied, or inside one, or hold one.
    private var destinationProblem: String? {
        guard let destination else { return nil }
        let target = KitCopy.kitFolder(in: destination).appending(path: "Library").standardizedFileURL.path + "/"
        for source in sources {
            let path = source.standardizedFileURL.path + "/"
            if target.hasPrefix(path) || path.hasPrefix(target) { return "That’s where this library already is. Choose another drive or folder." }
        }
        return nil
    }

    private func prepare() async {
        guard let destination else { return }
        replaceConfirmed = false
        let chosen = library.folders.filter(sources.contains)
        var app = Bundle.main.bundleURL
        #if DEBUG
        // Test hook: -kitCopyAppBundle <path> copies that app instead of this one (to test a signed, notarized build).
        if let path = UserDefaults.standard.string(forKey: "kitCopyAppBundle") { app = URL(fileURLWithPath: path) }
        #endif
        await copier.prepare(libraries: chosen, picked: destination, includeApp: includeApp, appBundle: app)
    }
}
#endif
