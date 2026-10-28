// NotProtonGPTK: reads D3DMetal out of Apple's Game Porting Toolkit DMG.
//
// Apple ships GPTK as an outer "Game Porting Toolkit" image holding a nested
// "Evaluation environment for Windows games" image, whose redist/lib is laid over a Wine
// runtime: redist/lib/external beside the runtime's lib/external, and
// redist/lib/wine/x86_64-windows over the runtime's D3D DLLs.

import Foundation

final class GPTKImage {

    static let step = wm("Patch in Game Porting Toolkit")
    static let appleDownloads = URL(string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")!

    let redist: URL
    let d3dMetalVersion: String
    private var mounts: [URL]

    private init(redist: URL, version: String, mounts: [URL]) {
        self.redist = redist
        self.d3dMetalVersion = version
        self.mounts = mounts
    }

    // The newest GPTK DMG in Downloads or on the Desktop, for the import button to offer.
    static func findDMG() -> URL? {
        let fm = FileManager.default
        let places = ["Downloads", "Desktop"].map { SupportPaths.home.appending(path: $0) }
        let found = places.flatMap { place in
            ((try? fm.contentsOfDirectory(at: place, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { isGPTKImage($0) }
        }
        return found.max { modified($0) < modified($1) }
    }

    static func isGPTKImage(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return url.pathExtension.lowercased() == "dmg"
            && (name.contains("porting") && name.contains("toolkit") || name.hasPrefix("evaluation environment"))
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    // A volume the user already mounted wins, then the DMG given (or found).
    static func open(dmg: URL?) throws -> GPTKImage {
        if let redist = mountedRedist() { return try GPTKImage(redist: redist, mounts: []) }
        guard let dmg = dmg ?? findDMG() else {
            throw StepFailure(step: step, detail: wm("No Game Porting Toolkit DMG was found. Download it from Apple, then choose it."))
        }
        var mounts: [URL] = []
        do {
            let outer = try attach(dmg)
            mounts.append(outer)
            if let redist = redist(in: outer) { return try GPTKImage(redist: redist, mounts: mounts) }
            let nested = ((try? FileManager.default.contentsOfDirectory(at: outer, includingPropertiesForKeys: nil)) ?? [])
                .first { $0.pathExtension.lowercased() == "dmg" && $0.lastPathComponent.lowercased().hasPrefix("evaluation environment") }
            guard let nested else {
                throw StepFailure(step: step, detail: wm("\(dmg.lastPathComponent) has no evaluation environment in it."))
            }
            let inner = try attach(nested)
            mounts.append(inner)
            guard let redist = redist(in: inner) else {
                throw StepFailure(step: step, detail: wm("\(nested.lastPathComponent) has no redist/lib folder."))
            }
            return try GPTKImage(redist: redist, mounts: mounts)
        } catch {
            mounts.reversed().forEach(detach)
            throw error
        }
    }

    private convenience init(redist: URL, mounts: [URL]) throws {
        let framework = redist.appending(path: "external/D3DMetal.framework")
        let plists = ["Versions/A/Resources/Info.plist", "Resources/Info.plist"].map { framework.appending(path: $0) }
        let version = plists.lazy.compactMap { url -> String? in
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return plist["CFBundleShortVersionString"] as? String
        }.first
        guard let version else {
            mounts.reversed().forEach(GPTKImage.detach)
            throw StepFailure(step: GPTKImage.step, detail: wm("The image has no D3DMetal.framework."))
        }
        self.init(redist: redist, version: version, mounts: mounts)
    }

    func close() {
        mounts.reversed().forEach(GPTKImage.detach)
        mounts = []
    }

    deinit { close() }

    // Merges rather than replaces: the runtime's lib/wine holds the core DLLs Apple's
    // overlay does not carry.
    func overlay(onto root: URL) throws {
        let lib = root.appending(path: "lib")
        let result = try Shell.run("/usr/bin/ditto", [redist.path(percentEncoded: false), lib.path(percentEncoded: false)])
        guard result.succeeded else {
            throw StepFailure(step: GPTKImage.step, detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        RunnerInstaller.scrubDownloadMarkers(at: lib)
        try linkForRosetta(root: root)
    }

    // CrossOver keeps libd3dshared in lib64/apple_gptk/external, and the run script only hands
    // its path to Wine (CX_APPLEGPTK_LIBD3DSHARED_PATH) from there. CrossOver's ntdll uses it
    // to register D3DMetal's code with Rosetta, so point that path at what was laid in.
    private func linkForRosetta(root: URL) throws {
        let fm = FileManager.default
        let folder = root.appending(path: "lib64/apple_gptk")
        let link = folder.appending(path: "external")
        guard !fm.fileExists(atPath: link.path(percentEncoded: false)) else { return }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: "../../lib/external")
    }

    private static func mountedRedist() -> URL? {
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(filePath: "/Volumes"), includingPropertiesForKeys: nil)) ?? []
        return volumes.filter { $0.lastPathComponent.lowercased().hasPrefix("evaluation environment") }
            .compactMap(redist(in:)).first
    }

    private static func redist(in volume: URL) -> URL? {
        let lib = volume.appending(path: "redist/lib")
        let present = FileManager.default.fileExists(
            atPath: lib.appending(path: "external/D3DMetal.framework").path(percentEncoded: false))
        return present ? lib : nil
    }

    private static func attach(_ dmg: URL) throws -> URL {
        let result = try Shell.run("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path(percentEncoded: false),
        ])
        guard result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: Data(result.stdout.utf8), format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw StepFailure(step: step, detail: wm("Could not open \(dmg.lastPathComponent). \(detail)"))
        }
        return URL(filePath: mount, directoryHint: .isDirectory)
    }

    private static func detach(_ mount: URL) {
        _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path(percentEncoded: false)])
    }
}
