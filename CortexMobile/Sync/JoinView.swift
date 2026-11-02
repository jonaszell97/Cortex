import SwiftUI
import VisionKit
import CortexCore

/// The first screen: join the Macs' sync with their pairing code, scanned
/// from Settings → Sync → Show Pairing Code on a Mac, or pasted.
struct JoinView: View {
    @Environment(MobileSyncService.self) private var sync
    @State private var isScanning = false
    @State private var isJoining = false
    @State private var error: String?

    private var canScan: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "brain")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Cortex")
                    .font(.largeTitle.bold())
                Text("Your knowledge base and reading list from your Macs, end-to-end encrypted through your sync server.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isJoining {
                ProgressView(sync.status == .syncing ? "Syncing for the first time…" : "Joining…")
            } else {
                VStack(spacing: 12) {
                    if canScan {
                        Button {
                            isScanning = true
                        } label: {
                            Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    PasteButton(payloadType: String.self) { codes in
                        guard let code = codes.first else { return }
                        Task { await join(code) }
                    }
                    .buttonBorderShape(.capsule)
                }
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Text("On a Mac: Settings → Sync → Show Pairing Code. The code holds the sync key, and the server must be reachable (Tailscale on).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        #if DEBUG
        // Simulator runs against a local server (docs/DEVELOPMENT.md, "The iOS
        // app"): SIMCTL_CHILD_CORTEX_PAIRING_CODE=… xcrun simctl launch …
        .task {
            if let code = ProcessInfo.processInfo.environment["CORTEX_PAIRING_CODE"] { await join(code) }
        }
        #endif
        .sheet(isPresented: $isScanning) {
            NavigationStack {
                PairingScanner { code in
                    isScanning = false
                    Task { await join(code) }
                }
                .ignoresSafeArea()
                .navigationTitle("Scan Pairing Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isScanning = false }
                    }
                }
            }
        }
    }

    private func join(_ code: String) async {
        guard !isJoining else { return }
        isJoining = true
        error = nil
        do {
            try await sync.join(pairingCode: code)
        } catch {
            self.error = SyncSetup.message(for: error)
        }
        isJoining = false
    }
}

/// The camera, looking for a QR code that holds a pairing code. Reports the
/// first one it sees, once; other QR codes are ignored.
private struct PairingScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let found: (String) -> Void
        private var reported = false

        init(found: @escaping (String) -> Void) {
            self.found = found
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard !reported, case .barcode(let barcode) = item,
                      let text = barcode.payloadStringValue, text.hasPrefix(SyncPairing.prefix)
                else { continue }
                reported = true
                dataScanner.stopScanning()
                found(text)
            }
        }
    }
}
