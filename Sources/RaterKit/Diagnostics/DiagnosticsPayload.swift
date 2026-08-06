import Foundation

/// Diagnostics uploaded alongside a feedback.
///
/// Deliberately carries nothing that identifies a person — no IDFV, no advertising
/// identifier, no precise timestamps. The feedback form shows this list verbatim to
/// the user, so the set stays small and every field is easy to justify.
public struct DiagnosticsPayload: Codable, Sendable, Equatable {
    public var appVersion: String?
    public var build: String?
    public var bundleID: String?
    public var osVersion: String?
    public var deviceModel: String?
    public var locale: String?
    public var region: String?
    public var timezone: String?
    public var installDays: Int?
    public var launchCount: Int?

    enum CodingKeys: String, CodingKey {
        case build, locale, region, timezone
        case appVersion = "app_version"
        case bundleID = "bundle_id"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case installDays = "install_days"
        case launchCount = "launch_count"
    }

    public init() {}

    /// Collects the current device's facts. Returns an empty payload when `collectsDiagnostics` is off.
    public init(device: DeviceInfo = .current, state: RaterState, enabled: Bool = true) {
        guard enabled else { return }
        appVersion = device.appVersion
        build = device.build
        bundleID = device.bundleID
        osVersion = device.systemVersion
        deviceModel = device.deviceModel
        locale = device.locale
        region = device.region
        timezone = device.timeZone
        installDays = Calendar.current
            .dateComponents([.day], from: state.installDate, to: Date()).day ?? 0
        launchCount = state.launchCount
    }

    /// Rows for the form's "what gets sent" disclosure, in a fixed, readable order.
    public var displayItems: [(label: String, value: String)] {
        var items: [(String, String)] = []
        func add(_ key: String, _ fallback: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            // The key is a runtime string here, so this goes through
            // Bundle.localizedString rather than String(localized:), which needs a
            // compile-time constant.
            let localized = Bundle.module.localizedString(
                forKey: key, value: fallback, table: nil
            )
            items.append((localized, value))
        }
        add("rater.diag.appVersion", "App version",
            appVersion.map { "\($0) (\(build ?? "?"))" })
        add("rater.diag.bundleID", "Bundle ID", bundleID)
        add("rater.diag.os", "System version", osVersion)
        add("rater.diag.device", "Device", deviceModel)
        add("rater.diag.locale", "Language / Region",
            locale.map { "\($0) / \(region ?? "?")" })
        add("rater.diag.timezone", "Time zone", timezone)
        add("rater.diag.installDays", "Days installed", installDays.map(String.init))
        add("rater.diag.launchCount", "Launches", launchCount.map(String.init))
        return items
    }

    /// Whether there is anything to show — lets the form hide the whole section when collection is off.
    public var isEmpty: Bool {
        displayItems.isEmpty
    }
}
