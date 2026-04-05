import Foundation

enum AppEdition: String {
    case appStore
    case pro

    static let current: AppEdition = {
        #if PRO_EDITION
        return .pro
        #else
        return .appStore
        #endif
    }()

    var displayName: String {
        switch self {
        case .appStore:
            return "QuickPreview"
        case .pro:
            return "QuickPreview PRO"
        }
    }

    var supportsFinderIntegration: Bool {
        self == .pro
    }

    var showsProMessaging: Bool {
        self == .appStore
    }

    var urlScheme: String {
        switch self {
        case .appStore:
            return "quickpreview"
        case .pro:
            return "quickpreview-pro"
        }
    }

    var sharedContainerIdentifier: String {
        switch self {
        case .appStore:
            return "group.com.jboive.quickpreview.shared"
        case .pro:
            return "group.com.jboive.quickpreview.pro.shared"
        }
    }

    var helperBundleIdentifier: String {
        switch self {
        case .appStore:
            return "com.jboive.quickpreview.launcher"
        case .pro:
            return "com.jboive.quickpreview.pro.launcher"
        }
    }

    var helperAppName: String {
        "QuickPreviewLauncher"
    }

    var accountPortalURL: URL? {
        switch self {
        case .appStore:
            return URL(string: "https://quickpreview.boive.se/pro/")
        case .pro:
            return URL(string: "https://quickpreview.boive.se/pro/download/")
        }
    }

    var proDownloadURL: URL? {
        URL(string: "https://quickpreview.boive.se/pro/download/")
    }

    var supportURL: URL? {
        URL(string: "https://quickpreview.boive.se/support/")
    }

    /// Hosts only `/api/bridge/*` (Vercel). Marketing HTML stays on `quickpreview.boive.se`.
    /// Match **Vercel → Project → Domains** (prefer the stable `*.vercel.app` without a deployment hash when listed).
    var bridgeAPIBaseURL: URL? {
        URL(string: "https://quick-preview-iaidg1nz5-joacim-boives-projects.vercel.app/api/bridge/")
    }
}
