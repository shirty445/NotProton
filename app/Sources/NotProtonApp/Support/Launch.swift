import Foundation

@main
enum Launch {
    static func main() {
        if CommandLine.arguments.dropFirst().contains(RemoveEverythingCommand.flag) {
            RemoveEverythingCommand.run()
        }
        if CommandLine.arguments.dropFirst().contains("--verify-components") {
            do {
                let payload = try InstallPayload.locate()
                let bridge = try BridgePayload.locate()
                print("Components: \(try InstallPayload.root().path)")
                print("Verified \(payload.signatures.count) signatures, \(payload.fonts.count) fonts, \(bridge.sources.count) bridge binaries.")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        NotProtonApp.main()
    }
}
