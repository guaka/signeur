import SwiftUI

public struct LoadingSigningView: View {
    public init() {}

    public var body: some View {
        VStack(alignment: contentAlignment, spacing: 16) {
            ProgressView()
            Text("Signing request...")
                .font(.headline)
            Text("Your key stays on this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
        .padding()
    }

    private var contentAlignment: HorizontalAlignment {
#if os(macOS)
        .leading
#else
        .center
#endif
    }

    private var frameAlignment: Alignment {
#if os(macOS)
        .topLeading
#else
        .center
#endif
    }
}
