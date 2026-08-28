import SwiftUI

struct AppIconView: View {
    let appName: String?
    let appURL: String?
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let faviconURL = appFaviconURL(for: appURL) {
                AsyncImage(url: faviconURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.22))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityLabel("\(appName ?? "Unknown app") icon")
    }

    @ViewBuilder
    private var fallback: some View {
        if let initial = appName?.first {
            Text(String(initial).uppercased())
                .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: size * 0.42))
                .foregroundStyle(.secondary)
        }
    }
}

func appFaviconURL(for appURL: String?) -> URL? {
    guard
        let appURL,
        let canonicalURL = try? SecurityPolicy.canonicalMetadataURL(appURL),
        var components = URLComponents(string: canonicalURL),
        components.scheme == "https",
        let host = components.host,
        !SecurityPolicy.isLoopback(host: host)
    else {
        return nil
    }

    components.path = "/favicon.ico"
    components.query = nil
    return components.url
}
