import SwiftUI

public struct LoadingSigningView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Signing request...")
                .font(.headline)
            Text("Your key stays on this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
