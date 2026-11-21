import SwiftUI
import VisionKit
import AVFoundation

/// Scans one barcode with the camera (VisionKit). Works with no internet; the code is all it reads.
/// On devices without a supported camera (and in the Simulator) it explains that and offers typing instead.
struct BarcodeScanSheet: View {
    let found: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cameraDenied = AVCaptureDevice.authorizationStatus(for: .video) == .denied

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    unavailable("This device can’t scan barcodes",
                                "Scanning needs an iPhone or iPad camera that supports Live Text. Type the numbers under the barcode instead.")
                } else if cameraDenied {
                    unavailable("Camera access is off",
                                "Turn on the camera for Offline Kit in Settings › Privacy & Security › Camera, or type the barcode instead.")
                } else {
                    ScannerView(found: found)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .bottom) {
                            Text("Point the camera at a barcode")
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.bottom, 30)
                        }
                }
            }
            .navigationTitle("Scan Barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            guard DataScannerViewController.isSupported,
                  AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
            cameraDenied = !(await AVCaptureDevice.requestAccess(for: .video))
        }
    }

    private func unavailable(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "barcode.viewfinder", description: Text(detail))
    }
}

private struct ScannerView: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode()], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        // Scanning can only start once the view is on screen.
        Task { @MainActor in if !scanner.isScanning { try? scanner.startScanning() } }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning, DataScannerViewController.isAvailable { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            report(added)
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            report([item])
        }

        private func report(_ items: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let barcode) = item, let code = barcode.payloadStringValue, !code.isEmpty {
                    done = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    found(code)
                    return
                }
            }
        }
    }
}
