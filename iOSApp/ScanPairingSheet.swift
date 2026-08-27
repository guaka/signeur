import SwiftUI
import UIKit
import SignstrCore

struct ScanPairingSheet: View {
    @ObservedObject var viewModel: PairingViewModel
    let onPaired: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cameraMessage: String?
    @State private var isHandlingCode = false

    var body: some View {
        NavigationStack {
            ZStack {
                if cameraMessage == nil {
                    QRScannerView(
                        isPaused: isHandlingCode,
                        onCode: handle,
                        onFailure: { cameraMessage = $0 }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    viewfinder
                } else {
                    cameraUnavailable
                }
            }
            .navigationTitle("Scan to connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onDisappear {
            viewModel.reset()
        }
    }

    private var viewfinder: some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                .frame(width: 240, height: 240)
            Spacer()
            VStack(spacing: 8) {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.white)
                        .font(.footnote.bold())
                } else {
                    Text("Point the camera at the app's Nostr Connect code.")
                        .foregroundStyle(.white)
                        .font(.footnote)
                }
            }
            .multilineTextAlignment(.center)
            .padding()
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 32)
        }
        .padding()
    }

    private var cameraUnavailable: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(cameraMessage ?? "The camera is unavailable.")
                .multilineTextAlignment(.center)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settingsURL)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func handle(_ payload: String) {
        guard !isHandlingCode else { return }
        isHandlingCode = true
        Task {
            let paired = await viewModel.handleScannedPayload(payload)
            if paired {
                onPaired()
                dismiss()
            } else {
                // Keep the camera live so a corrected code can be scanned straight away.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                isHandlingCode = false
            }
        }
    }
}
