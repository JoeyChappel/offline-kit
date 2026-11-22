import SwiftUI

/// Kit Care › References: how far the answer index has got, per reference, with Pause and Rebuild.
struct AnswerIndexCard: View {
    @State private var status = AnswerIndexStatus.shared
    @State private var confirmingRebuild = false

    private var snapshot: AnswerIndex.Snapshot { status.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KitCardHeader(symbol: "text.magnifyingglass", title: "Answer index",
                          subtitle: "Ask reads your references ahead of time, so answers start sooner.")
            Label(Self.summary(snapshot), systemImage: summarySymbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(isPaused ? Color.orange : .primary)
            if !snapshot.rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(snapshot.rows) { row in
                        Divider()
                        HStack(spacing: 10) {
                            Text(row.title).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 8)
                            if case .building(let done, let total) = row.state, total > 0 {
                                ProgressView(value: Double(done), total: Double(total))
                                    .frame(width: 70)
                                    .accessibilityHidden(true)
                            }
                            Text(Self.label(row)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { usage; Spacer(minLength: 8); controls }
                VStack(alignment: .leading, spacing: 10) { usage; controls }
            }
        }
        .card(padding: 18)
        .confirmationDialog("Rebuild the answer index?", isPresented: $confirmingRebuild) {
            Button("Rebuild") { AnswerIndex.shared.rebuild() }
        } message: {
            Text("Ask keeps working while it rebuilds, searching the usual way until each reference is ready again.")
        }
    }

    private var usage: some View {
        Text("\(kitBytes(snapshot.bytes)) on this device").font(.callout).monospacedDigit().foregroundStyle(.secondary)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if snapshot.userPaused {
                Button("Resume", systemImage: "play") { AnswerIndex.shared.setPaused(false) }
            } else {
                Button("Pause", systemImage: "pause") { AnswerIndex.shared.setPaused(true) }
                    .disabled(Self.isFinished(snapshot))
            }
            Button("Rebuild…", systemImage: "arrow.clockwise") { confirmingRebuild = true }
                .disabled(snapshot.rows.isEmpty)
        }
        .buttonStyle(.bordered)
    }

    private var isPaused: Bool { !Self.isFinished(snapshot) && (snapshot.userPaused || snapshot.powerPause != nil) }

    private var summarySymbol: String {
        if snapshot.rows.isEmpty { return "books.vertical" }
        if Self.isFinished(snapshot) { return "checkmark.circle" }
        if isPaused { return snapshot.powerPause == .battery ? "battery.25" : "pause.circle" }
        return "arrow.triangle.2.circlepath"
    }

    static func isFinished(_ s: AnswerIndex.Snapshot) -> Bool {
        s.rows.allSatisfy { row in
            switch row.state { case .waiting, .building: false; default: true }
        }
    }

    /// "Ready for fast answers", "Indexing 3 of 7 references, 42%", "Paused on battery".
    static func summary(_ s: AnswerIndex.Snapshot) -> String {
        if s.rows.isEmpty { return "References are indexed once they’re in your library." }
        if isFinished(s) { return "Ready for fast answers" }
        if s.userPaused { return "Paused" }
        switch s.powerPause {
        case .lowPower: return "Paused in Low Power Mode"
        case .battery: return "Paused on battery"
        default: break
        }
        let finished = s.rows.filter { row in
            switch row.state { case .waiting, .building: false; default: true }
        }.count
        let current = s.rows.first { if case .building = $0.state { true } else { false } }
        var text = "Indexing \(min(finished + 1, s.rows.count)) of \(s.rows.count) references"
        if case .building(let done, let total)? = current?.state, total > 0 {
            text += ", \(Int(Double(done) / Double(total) * 100))%"
        }
        return text
    }

    static func label(_ row: AnswerIndex.Snapshot.Row) -> String {
        switch row.state {
        case .ready: row.depth == .leads ? "Leads only (large)" : "Indexed"
        case .building(let done, let total): total > 0 ? "Indexing \(Int(Double(done) / Double(total) * 100))%" : "Indexing"
        case .waiting: "Waiting"
        case .tooLarge: "Searched the usual way (too large)"
        case .failed: "Searched the usual way"
        }
    }
}
