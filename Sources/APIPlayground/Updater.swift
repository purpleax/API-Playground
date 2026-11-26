import Combine
import Foundation
import Sparkle

/// Checks for new versions of the app and installs them, through Sparkle.
///
/// Updates are switched on by the build: a copy whose Info.plist names no update feed
/// (a development or test build) never looks for one.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    /// False while a check is already under way, or when this copy has no update feed.
    @Published private(set) var canCheck = false

    /// True when this copy of the app can update itself.
    var isAvailable: Bool { controller != nil }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        guard !feed.isEmpty, !key.isEmpty else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

