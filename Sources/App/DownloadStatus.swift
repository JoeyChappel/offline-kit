import SwiftUI

/// Compact download status pinned to the bottom of the sidebar, so progress is visible from every screen.
struct DownloadStatusCard: View {
    @Environment(DownloadManager.self) private var downloads
    let open: () -> Void

    var body: some View {
        if let summary = downloads.summary {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: symbol(summary))
                        .foregroundStyle(summary.failed > 0 && !summary.isRunning ? Color.orange : Color.accentColor)
                    Text(summary.headline).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if summary.isComplete {
                        Button("Clear") { downloads.clearFinished() }
                            .buttonStyle(.borderless).font(.caption)
                    } else if summary.isPaused {
                        Button("Resume") { downloads.resumeAll() }
                            .buttonStyle(.borderless).font(.caption)
                    } else if summary.failed > 0 && !summary.isRunning {
                        Button("Retry All") { downloads.retryAll() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
                if !summary.isComplete {
                    ProgressView(value: summary.fraction).controlSize(.small)
                }
                Text(summary.detail)
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.10)))
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .help("Show each download")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Show downloads", open)
            .padding(.horizontal, 10).padding(.top, 10)
        }
    }

    private func symbol(_ s: DownloadSummary) -> String {
        if s.isComplete { return "checkmark.circle.fill" }
        if s.failed > 0 && !s.isRunning { return "exclamationmark.triangle.fill" }
        if s.isPaused { return "pause.circle.fill" }
        return "arrow.down.circle.fill"
    }
}

/// Large progress panel for Library, Ask and Get Resources while the library is downloading.
struct DownloadProgressPanel: View {
    @Environment(DownloadManager.self) private var downloads
    /// Shows a button that opens Get Resources (off when already there).
    var showsOpenButton = true
    var open: () -> Void = {}

    var body: some View {
        if let summary = downloads.summary {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label(title(summary), systemImage: summary.isComplete ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(summary.fraction * 100))%").font(.headline).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: summary.fraction)
                Text("\(summary.headline) · \(summary.detail)")
                    .font(.callout).monospacedDigit()
                if let current = summary.current {
                    Text("Now: \(current)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if !summary.isComplete {
                    Text(note(summary)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if summary.isPaused {
                        Button("Resume Downloads", systemImage: "play.fill") { downloads.resumeAll() }
                            .buttonStyle(.borderedProminent)
                    } else if summary.failed > 0 && !summary.isRunning {
                        Button("Retry All", systemImage: "arrow.clockwise") { downloads.retryAll() }
                            .buttonStyle(.borderedProminent)
                    }
                    if showsOpenButton {
                        Button("See Each Download", systemImage: "list.bullet") { open() }
                    }
                }
            }
            .card(padding: 20)
        }
    }

    private func title(_ s: DownloadSummary) -> String {
        if s.isComplete { return "Your library is ready" }
        if s.isPaused { return "Your library download is paused" }
        return "Your library is downloading"
    }

    private func note(_ s: DownloadSummary) -> String {
        #if os(macOS)
        let device = "this Mac"
        #else
        let device = "this device"
        #endif
        if s.isPaused { return "Nothing is lost. Downloads pick up where they left off when you resume." }
        return "Each reference appears in Library as soon as it finishes, so you can start using it before the rest are done. Keep \(device) online and awake; if it sleeps, downloads continue where they left off."
    }
}
