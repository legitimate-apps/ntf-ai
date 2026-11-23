import Foundation

enum Config {
    static var appBaseUrl: String {
        string(for: "AppBaseURL")
    }
    
    /// Who runs the built-in server, for copy that names it. Shipped builds pin `AppBaseURL` to
    /// ntfy-me.com (scripts/verify-app-base-url.sh gates the archive), which this app's publisher runs.
    static var appServerDescription: String {
        String(localized: "\(shortUrl(url: normalizeBaseUrl(appBaseUrl))), a free public server run by the publisher of this app (not affiliated with ntfy.sh or the ntfy project)")
    }

    // MARK: - Build identity
    //
    // Set in Configuration/*.xcconfig and carried in both the app's and the extension's Info.plist,
    // so the source names no signing identity. Keychain items and the shared container are keyed by
    // these, so a shipped build must keep the values it shipped with.

    /// The app's bundle id; the prefix of every Keychain service name.
    static var bundleIdBase: String {
        string(for: "AppBundleIdBase")
    }

    /// App Group shared by the app and the notification extension.
    static var appGroupId: String {
        string(for: "AppGroupId")
    }

    /// Keychain access group shared by the app and the extension, without the team prefix.
    static var keychainGroup: String {
        string(for: "AppKeychainGroup")
    }

    /// The `upstream-base-url` line a self-hosted server needs so its messages reach this app instantly.
    static var upstreamConfigLine: String {
        "upstream-base-url: \(normalizeBaseUrl(appBaseUrl))"
    }

    /// The "Instant banners for ntfy.sh and other servers" setting (`NtfyShBridge`), on by default.
    /// Read here because Config also compiles into the extensions, which don't carry the bridge.
    static let ntfyShBridgeKey = "ntfyShBridgeEnabled"
    static var ntfyShBridgeEnabled: Bool {
        (UserDefaults(suiteName: appGroupId) ?? .standard).object(forKey: ntfyShBridgeKey) as? Bool ?? true
    }

    /// ntfy.sh pushes to the official app's Firebase project, not this app's, so banners for its
    /// topics come through the bridge (`NtfyShBridge`): on by default, and the copy says what it shares.
    static func ntfyShDeliveryHint(baseUrl: String, bridgeOn: Bool = ntfyShBridgeEnabled) -> String? {
        guard let host = URL(string: normalizeBaseUrl(baseUrl))?.host?.lowercased(), host == "ntfy.sh" || host == "www.ntfy.sh" else { return nil }
        if bridgeOn {
            return String(localized: "Topics on ntfy.sh get instant banners: \(shortUrl(url: normalizeBaseUrl(appBaseUrl))) watches them for this device and keeps no message text. You can turn this off in Settings. See \(migrateUrl).")
        }
        return String(localized: "Instant banners for ntfy.sh and other servers is off in Settings, so messages on ntfy.sh appear only when you open the app or refresh. See \(migrateUrl).")
    }

    static func subscriptionServerFooter(baseUrl: String, useAnother: Bool) -> String {
        if let hint = ntfyShDeliveryHint(baseUrl: baseUrl) { return hint }
        if useAnother {
            return selfHostedDeliveryHint
        }
        if normalizeBaseUrl(baseUrl) == normalizeBaseUrl(appBaseUrl) {
            return String(localized: "New topics use \(appServerDescription). Any ntfy server works: turn on \"Use another server\" or change the default in Settings. Your scripts must send to \(shortUrl(url: normalizeBaseUrl(appBaseUrl))); the same topic name on ntfy.sh is a different topic.")
        }
        return String(localized: "New topics use your default server, \(shortUrl(url: baseUrl)).")
    }

    /// The two-sentence footer for the built-in server; the full `subscriptionServerFooter` text
    /// (who runs it, and that ntfy.sh is a different server) sits behind "About this server".
    /// Nil wherever the full footer carries a delivery hint the user needs to see.
    static func subscriptionServerShortFooter(baseUrl: String, useAnother: Bool) -> String? {
        guard !useAnother, ntfyShDeliveryHint(baseUrl: baseUrl) == nil, normalizeBaseUrl(baseUrl) == normalizeBaseUrl(appBaseUrl) else { return nil }
        return String(localized: "New topics use \(shortUrl(url: normalizeBaseUrl(appBaseUrl))), a free public server. Any ntfy server works: turn on \"Use another server\".")
    }

    static func defaultServerFooter(baseUrl: String) -> String {
        let deliveryHint = ntfyShDeliveryHint(baseUrl: baseUrl)
            ?? selfHostedDeliveryHint
        return String(localized: "When subscribing to new topics, this server will be used as a default. Leave it empty to use \(appServerDescription). \(deliveryHint)")
    }

    static var selfHostedDeliveryHint: String { selfHostedDeliveryHint(bridgeOn: ntfyShBridgeEnabled) }

    static func selfHostedDeliveryHint(bridgeOn: Bool) -> String {
        let appServer = normalizeBaseUrl(appBaseUrl)
        if bridgeOn {
            return String(localized: "For instant banners from your own server, set upstream-base-url to https://ntfy.sh, the usual setting, which keeps the official ntfy app working too, or to \(appServer). With no upstream, messages arrive when you refresh. See \(selfHostingUrl).")
        }
        return String(localized: "For instant banners from your own server, set upstream-base-url to \(appServer). https://ntfy.sh, the usual setting, works only while Instant banners for ntfy.sh and other servers is on in Settings. With no upstream, messages arrive when you refresh. See \(selfHostingUrl).")
    }

    static var build: String {
        string(for: "CFBundleVersion")
    }
    
    static var version: String {
        string(for: "CFBundleShortVersionString")
    }
    
    static var osVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return String(os.majorVersion) + "." + String(os.minorVersion) + "." + String(os.patchVersion)
    }
    
    // MARK: - Outward links
    //
    // Single source of truth for every link the app opens. These used to be
    // string literals inline in AboutView, which is how a shipped build ended
    // up sending "Rate the app" to UPSTREAM's App Store listing and "Report a
    // bug" to upstream's issue tracker. Keeping them here means a fork-wide
    // rename touches one file, and a wrong id is visible next to the right one.

    /// This app's App Store id, from `APP_STORE_ID`; nil in a build that sets none.
    ///
    /// Upstream ntfy is `1625396347`. That is a DIFFERENT app on a different
    /// team — never point our review or listing links at it.
    static var appStoreId: String? {
        let id = (Bundle.main.infoDictionary?["AppStoreId"] as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return id.isEmpty ? nil : id
    }

    /// Deep link to the App Store review composer; nil without an App Store id.
    ///
    /// `?action=write-review` opens the review sheet directly. Without it the
    /// user lands on the listing and has to find "Write a Review" themselves,
    /// which is most of the reason a "Rate the app" button gets abandoned.
    static var reviewUrl: String? {
        appStoreId.map { "https://apps.apple.com/app/id\($0)?action=write-review" }
    }

    /// This app's App Store listing; nil without an App Store id.
    static var appStoreListingUrl: String? {
        appStoreId.map { "https://apps.apple.com/app/id\($0)" }
    }

    /// Moving a topic from the official app or keeping it on ntfy.sh.
    static let migrateUrl = "https://ntf-ai.app/docs/migrate"

    static let selfHostingUrl = "https://ntf-ai.app/docs/self-hosting"

    /// Where OUR users report OUR bugs. Reports about this fork must not land
    /// on upstream's tracker; they are a different project with a different
    /// maintainer who did not ship this code.
    ///
    /// Shipped builds before 1.16 link the support page on GitHub Pages, which
    /// now forwards here.
    static let supportUrl = "https://ntf-ai.app/docs/support"

    /// The quick start for this app's default server. It is the primary help link: its examples
    /// publish to ntfy-me.com, where new topics live. ntfy.sh's own pages publish to ntfy.sh, so a
    /// newcomer who followed them sent their first message to a server the app was not listening to.
    static let helpUrl = "https://ntf-ai.app/"


    static private func string(for key: String) -> String {
        Bundle.main.infoDictionary?[key] as! String
    }
}
