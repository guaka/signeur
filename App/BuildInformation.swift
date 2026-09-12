import Foundation

public enum BuildInformation {
    public static func displayBuildTime(bundle: Bundle = .main) -> String {
        let configuredValue = bundle.object(forInfoDictionaryKey: "SigneurBuildTime") as? String
        let executableDate = bundle.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return displayBuildTime(configuredValue: configuredValue, fallbackDate: executableDate)
    }

    public static func displayBuildTime(configuredValue: String?, fallbackDate: Date?) -> String {
        if let configuredValue,
           !configuredValue.isEmpty,
           !configuredValue.hasPrefix("$(") {
            return configuredValue
        }

        guard let fallbackDate else {
            return "Unknown"
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter.string(from: fallbackDate)
    }
}
