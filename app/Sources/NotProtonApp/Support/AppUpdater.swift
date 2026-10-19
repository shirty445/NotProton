import Foundation
import Sparkle

@MainActor
final class AppUpdater {

    private let controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            return
        }
        #if DEBUG
        let scheduling = false
        #else
        let scheduling = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: scheduling,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func check() {
        #if !DEBUG
        controller?.checkForUpdates(nil)
        #endif
    }
}
