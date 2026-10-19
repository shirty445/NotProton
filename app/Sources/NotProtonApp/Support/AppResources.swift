import Foundation

extension Bundle {
    static let notProtonResources: Bundle = {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(url: resources.appending(path: "NotProtonApp_NotProtonApp.bundle")) {
            return packaged
        }
        return .module
    }()
}
