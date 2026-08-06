import Foundation

/// Static device and app facts. `current` is computed once on first access.
public struct DeviceInfo: Sendable, Equatable {
    /// Marketing name, e.g. "iPhone 16 Pro"; falls back to the raw identifier such as "iPhone17,1".
    public let deviceModel: String
    /// Raw hardware identifier.
    public let deviceIdentifier: String
    public let systemVersion: String
    public let appVersion: String
    public let build: String
    public let bundleID: String
    public let appName: String
    public let locale: String
    public let region: String
    public let timeZone: String

    public static let current = DeviceInfo()

    private init() {
        let identifier = Self.hardwareIdentifier()
        deviceIdentifier = identifier
        deviceModel = Self.marketingName(for: identifier) ?? identifier

        // Deliberately avoids UIDevice: it is @MainActor-isolated, and `current` is a
        // lazy static whose first access may well happen off the main thread.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osName = identifier.hasPrefix("iPad") ? "iPadOS" : "iOS"
        systemVersion = "\(osName) \(os.majorVersion).\(os.minorVersion)"
            + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")

        let info = Bundle.main.infoDictionary
        appVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        build = info?["CFBundleVersion"] as? String ?? "0"
        appName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "App"
        bundleID = Bundle.main.bundleIdentifier ?? "unknown"

        locale = Locale.preferredLanguages.first ?? Locale.current.identifier
        region = Locale.current.region?.identifier ?? "??"
        timeZone = TimeZone.current.identifier
    }

    /// Reads `hw.machine`. In the Simulator that reports the host Mac's architecture,
    /// so the Simulator-provided environment variable wins when present.
    private static func hardwareIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Marketing names for common models. Unknown identifiers pass through as-is —
    /// seeing "iPhone19,3" in the admin console for a brand new device is perfectly
    /// workable, and not worth a network call to avoid.
    private static func marketingName(for identifier: String) -> String? {
        Self.knownModels[identifier]
    }

    private static let knownModels: [String: String] = [
        // iPhone
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone 17 Plus",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone14,6": "iPhone SE (3rd gen)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        // iPad
        "iPad13,18": "iPad (10th gen)", "iPad14,1": "iPad mini (6th gen)",
        "iPad14,3": "iPad Pro 11-inch (4th gen)", "iPad14,5": "iPad Pro 12.9-inch (6th gen)",
        "iPad13,16": "iPad Air (5th gen)", "iPad14,8": "iPad Air 11-inch (M2)",
        "iPad14,10": "iPad Air 13-inch (M2)",
        "iPad16,3": "iPad Pro 11-inch (M4)", "iPad16,5": "iPad Pro 13-inch (M4)",
        "iPad16,1": "iPad mini (A17 Pro)",
    ]
}
