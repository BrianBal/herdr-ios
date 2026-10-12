import HerdrKit
import SwiftUI
import VisionKit

struct PairView: View {
    @Environment(AppModel.self) private var app
    /// Set when shown as a sheet (adding another gateway, re-pairing); called once paired.
    var onPaired: (() -> Void)?
    @State private var urlText = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var error: String?
    @State private var scanning = false

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.tint)
                        Text("Connect to herdr")
                            .font(.title2.bold())
                        Text("On your Mac, open the pairing code from the iOS Gateway plugin:")
                            .foregroundStyle(.secondary)
                        Text("herdr plugin pane open --plugin bal.ios-gateway --entrypoint pair")
                            .font(.caption.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                        Text("Then scan it here or with the Camera app. Tailscale must be on.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    if scannerAvailable {
                        Button { scanning = true } label: {
                            Label("Scan pairing QR code", systemImage: "qrcode.viewfinder")
                        }
                    }
                    Button { pastePairingLink() } label: {
                        Label("Paste pairing link", systemImage: "doc.on.clipboard")
                    }
                }

                Section("Or enter manually") {
                    TextField("wss://host.tailnet.ts.net:8443/ws", text: $urlText)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Token", text: $token)
                        // Plain text, not SecureField: iOS offers to save a secure field in Passwords.
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        connect { try GatewayEndpoint(urlString: urlText, token: token) }
                    } label: {
                        HStack {
                            Text("Connect")
                            if connecting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(connecting || urlText.isEmpty || token.isEmpty)
                }

                if let message = error ?? app.pairingError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onPaired {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onPaired) }
                }
            }
            .sheet(isPresented: $scanning) {
                QRScannerView { payload in
                    scanning = false
                    connect { try GatewayEndpoint(pairingLink: payload) }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func pastePairingLink() {
        guard let text = UIPasteboard.general.string else {
            error = "The clipboard is empty."
            return
        }
        connect { try GatewayEndpoint(pairingLink: text) }
    }

    private func connect(_ make: () throws -> GatewayEndpoint) {
        error = nil
        let endpoint: GatewayEndpoint
        do { endpoint = try make() } catch {
            self.error = error.localizedDescription
            return
        }
        connecting = true
        Task {
            defer { connecting = false }
            do {
                try await app.pair(endpoint)
                onPaired?()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Live camera QR scanner; calls `onScan` once with the first herdr pairing link it sees.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var done = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                guard !done, case .barcode(let code) = item, let payload = code.payloadStringValue,
                      payload.hasPrefix("\(GatewayEndpoint.scheme)://") else { continue }
                done = true
                scanner.stopScanning()
                onScan(payload)
            }
        }
    }
}
