import AppKit
import Foundation
import Sparkle

final class SparkleFeedURLProvider: NSObject, SPUUpdaterDelegate {
    private let feedURL: String?

    init(feedURL: String?) {
        self.feedURL = feedURL
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURL
    }
}

enum AppMetadata {
    static let bundleIdentifier = "com.joowon.MST"
    static let currentVersion = "1.3.0"
    static let defaultFeedURL = "https://raw.githubusercontent.com/ducky8x/Mac-Speedrunning-Tools/main/appcast.xml"

    static func updateFeedURL(from infoDictionary: [String: Any], defaults: UserDefaults = .standard) -> String? {
        if let override = defaults.string(forKey: "macSpeedrunningTools.updateFeedURL"), !override.isEmpty {
            return override
        }

        return infoDictionary["SUFeedURL"] as? String
    }
}

@MainActor
final class AutoUpdaterController: NSObject, ObservableObject {
    static let shared = AutoUpdaterController()

    private let updaterController: SPUStandardUpdaterController
    private let updaterDelegate: SparkleFeedURLProvider
    private let userDefaults: UserDefaults

    @Published private(set) var updateState: UpdateStatus = .idle
    @Published private(set) var lastError: String?

    enum UpdateStatus: Equatable {
        case idle
        case checkingForUpdates
        case updateAvailable
        case noUpdateAvailable
        case downloading
        case installing
        case failed(String)
    }

    init(userDefaults: UserDefaults = .standard, updaterController: SPUStandardUpdaterController? = nil) {
        self.userDefaults = userDefaults

        if let updaterController {
            self.updaterController = updaterController
            self.updaterDelegate = SparkleFeedURLProvider(feedURL: nil)
        } else {
            let feedURL = AppMetadata.updateFeedURL(from: Bundle.main.infoDictionary ?? [:], defaults: userDefaults) ?? AppMetadata.defaultFeedURL
            let delegate = SparkleFeedURLProvider(feedURL: feedURL)
            let startingUpdater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
            self.updaterController = startingUpdater
            self.updaterDelegate = delegate
        }

        super.init()
    }

    var isEnabled: Bool {
        true
    }

    var statusText: String {
        switch updateState {
        case .idle:
            return "No update check has run yet."
        case .checkingForUpdates:
            return "Checking for updates…"
        case .updateAvailable:
            return "An update is available."
        case .noUpdateAvailable:
            return "You’re on the latest version."
        case .downloading:
            return "Downloading update…"
        case .installing:
            return "Installing update…"
        case .failed(let message):
            return message
        }
    }

    func startAutomaticChecks() {
        updaterController.startUpdater()
        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.automaticallyDownloadsUpdates = true
        updaterController.updater.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        updateState = .checkingForUpdates
        lastError = nil
        updaterController.checkForUpdates(nil)
    }

    func checkForUpdatesInBackground() {
        updateState = .checkingForUpdates
        lastError = nil
        updaterController.updater.checkForUpdatesInBackground()
    }

    func installUpdates() {
        updateState = .installing
        updaterController.updater.checkForUpdates()
    }

    func resetStatus() {
        updateState = .idle
        lastError = nil
    }
}
