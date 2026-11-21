import SwiftUI

/// Get Resources card for the built-in AI model (runs in the app; no Ollama or Apple Intelligence needed).
struct ModelPackCard: View {
    @Environment(Library.self) private var library
    @Environment(DownloadManager.self) private var downloads
    /// The chosen library folder; the model goes in its Models subfolder.
    let destination: URL?

    var body: some View {
        let _ = KitChanges.shared.models   // redraw when a model download finishes
        let installed = LocalModels.installed(libraryFolders: library.folders)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cpu")
                    .font(.title3).foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Optional: Offline Kit answer model").font(.headline)
                    Text(AppleEngine.isAvailable
                         ? "Not needed here: Apple Intelligence already answers questions. Get this if the library will be used on devices without it, or for fuller answers. It’s saved with your library."
                         : "Lets Ask answer questions on this device with no internet and no other software. It’s saved with your library, so it travels with a drive.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            ForEach(LocalModels.all.filter { candidate in candidate == LocalModels.recommended || installed.contains { $0.known == candidate } }) { model in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: installed.contains { $0.known == model } ? "checkmark.circle.fill" : "cpu")
                        .foregroundStyle(installed.contains { $0.known == model } ? Color.accentColor : .secondary)
                        .imageScale(.large)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Answer model (\(model.shortName))")
                        Text(model.recommendedOnPhone ? "Smaller and faster, made for iPhone and iPad." : "Reads more of your library and writes fuller answers.")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("\(model.detail) License: \(model.license).")
                    }
                    Spacer(minLength: 12)
                    trailing(model, installed: installed.contains { $0.known == model })
                }
                .padding(.vertical, 2)
            }
        }
        .card(padding: 18)
    }

    @ViewBuilder private func trailing(_ model: LocalModel, installed: Bool) -> some View {
        if installed {
            Pill(text: "Installed", symbol: "checkmark", tint: .accentColor)
        } else if let job = downloads.job(named: model.id) {
            Pill(text: job.state == .paused ? "Paused" : "\(Int(job.fraction * 100))%", symbol: "arrow.down", tint: .accentColor)
        } else {
            Button {
                guard let destination else { return }
                downloads.enqueue(model: model, to: LocalModels.folder(forLibrary: destination))
            } label: {
                Text("Get · \(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))")
            }
            .buttonStyle(.bordered)
            .disabled(destination == nil)
        }
    }
}
