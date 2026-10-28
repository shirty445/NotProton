import Foundation
import Testing

@testable import NotProtonApp

@Suite("Steamclient forwarder")
struct SteamclientForwarderTests {

    @Test("A built forwarder reads back with every name, sorted", arguments: [UInt16(0x8664), 0x14c])
    func roundTrip(machine: UInt16) throws {
        let names = ["Steam_BGetCallback", "CreateInterface", "Breakpad_SteamSetAppID", "CreateInterface"]
        let dll = SteamclientForwarder.forwarder(named: "steamclient64.dll", machine: machine, exports: names)
        let image = try SteamclientForwarder.exports(of: dll)
        #expect(image.machine == machine)
        #expect(image.exports == ["Breakpad_SteamSetAppID", "CreateInterface", "Steam_BGetCallback"])
        #expect(dll.count % 0x200 == 0)
    }

    @Test("Every export is a forwarder string into lsteamclient")
    func forwards() throws {
        let dll = SteamclientForwarder.forwarder(named: "steamclient.dll", machine: 0x14c, exports: ["CreateInterface"])
        let text = String(decoding: dll, as: UTF8.self)
        #expect(text.contains("lsteamclient.CreateInterface"))
        #expect(text.contains("steamclient.dll"))
    }

    @Test("Wine internals are not forwarded")
    func skipsWineInternals() throws {
        let dll = SteamclientForwarder.forwarder(
            named: "x.dll", machine: 0x8664, exports: ["__wine_unix_call_funcs", "CreateInterface"])
        #expect(try SteamclientForwarder.exports(of: dll).exports == ["CreateInterface"])
    }

    @Test("Something that is not a PE image is refused")
    func refusesJunk() {
        #expect(throws: StepFailure.self) { try SteamclientForwarder.exports(of: Data("nope".utf8)) }
    }
}

@Suite("Wine catalog")
struct WineCatalogTests {

    private let feed = """
    [
      {"tag_name": "Game-Porting-Toolkit-3.0-beta5", "html_url": "https://example.com/b5",
       "published_at": "2025-10-10T00:00:00Z", "prerelease": true, "draft": false,
       "assets": [{"name": "game-porting-toolkit-3.0-beta5.tar.xz", "size": 10,
                   "browser_download_url": "https://example.com/b5.tar.xz"}]},
      {"tag_name": "Game-Porting-Toolkit-3.0-3", "html_url": "https://example.com/3",
       "published_at": "2026-03-03T00:00:00Z", "prerelease": false, "draft": false,
       "assets": [{"name": "game-porting-toolkit-3.0-3.tar.xz", "size": 20,
                   "browser_download_url": "https://example.com/3.tar.xz"}]},
      {"tag_name": "no-asset", "html_url": "https://example.com/x",
       "published_at": "2026-04-01T00:00:00Z", "prerelease": false, "draft": false, "assets": []}
    ]
    """

    @Test("Releases come back newest first, without ones that have no archive")
    func parses() throws {
        let releases = try WineCatalog.parse(Data(feed.utf8), source: .gptk)
        #expect(releases.map(\.version) == ["3.0-3", "3.0-beta5"])
        #expect(releases[0].name == "Game-Porting-Toolkit-3.0-3")
        #expect(releases[0].runnerID == "gptk-3.0-3")
        #expect(WineCatalog.latest(releases)?.version == "3.0-3")
    }

    @Test("Staging only takes the staging archive out of the shared feed")
    func stagingFilter() {
        #expect(WineSource.wineStaging.accepts(asset: "wine-staging-11.18-osx64.tar.xz"))
        #expect(!WineSource.wineStaging.accepts(asset: "wine-devel-11.18-osx64.tar.xz"))
    }

    @Test("NotProton Wine takes only its runner archive out of the fork's release feed")
    func notprotonFeed() throws {
        let feed = """
        [
          {"tag_name": "v1.4", "html_url": "https://example.com/app", "published_at": "2026-10-29T00:00:00Z",
           "prerelease": false, "draft": false,
           "assets": [{"name": "NotProton.zip", "size": 5, "browser_download_url": "https://example.com/a.zip"}]},
          {"tag_name": "wine-cx26.3.0-1", "html_url": "https://example.com/w", "published_at": "2026-10-28T00:00:00Z",
           "prerelease": false, "draft": false,
           "assets": [{"name": "notproton-wine-cx26.3.0-1.tar.xz.sha256", "size": 1,
                       "browser_download_url": "https://example.com/w.sha256"},
                      {"name": "notproton-wine-cx26.3.0-1.tar.xz", "size": 9,
                       "browser_download_url": "https://example.com/w.tar.xz"}]}
        ]
        """
        let releases = try WineCatalog.parse(Data(feed.utf8), source: .notproton)
        #expect(releases.map(\.version) == ["cx26.3.0-1"])
        #expect(releases[0].download.lastPathComponent == "notproton-wine-cx26.3.0-1.tar.xz")
        #expect(releases[0].runnerID == "npwine-cx26.3.0-1")
        #expect(releases[0].display == "NotProton Wine cx26.3.0-1")
        #expect(ManagedRunners.overlayID(base: releases[0], d3dMetal: "4.0b3") == "npwine-cx26.3.0-1-d3dmetal-4.0b3")
    }

    @Test("Only Wine 11 sources are offered, the Wine 7 and 8 ones are kept for removal")
    func offered() {
        #expect(WineSource.offered == [.notproton, .wineStaging])
        #expect(WineSource.offered.allSatisfy { $0.runsSteamGames })
        #expect(!WineSource.gptk.runsSteamGames && !WineSource.wineCrossover.runsSteamGames)
    }

    @Test("Runner ids stay inside what the run script and dylib accept")
    func runnerIDs() {
        let id = ManagedRunners.runnerID(source: .gptk, version: "4.0 beta 3/b")
        #expect(id == "gptk-4.0-beta-3-b")
        #expect(id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        let longest = ManagedRunners.runnerID(source: .wineStaging, version: String(repeating: "9", count: 100))
        #expect(longest.count == 48)
        #expect(ManagedRunners.toolName(forRunner: longest).count <= 63)
    }
}

@Suite("Managed runner layout")
struct ManagedRunnerLayoutTests {

    @Test("The Wine root is found inside the app bundle an archive unpacks")
    func findsWineRoot() throws {
        let dir = try scratchDirectory("wine-root")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appending(path: "Game Porting Toolkit.app/Contents/Resources/wine")
        try FileManager.default.createDirectory(at: root.appending(path: "lib/wine"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "bin/wineserver"))
        #expect(ManagedRunners.wineRoot(in: dir)?.standardizedFileURL == root.standardizedFileURL)
    }

    @Test("A Wine 8 runtime falls back to bin/wine64")
    func loaderFallback() throws {
        let dir = try scratchDirectory("wine-loader")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wine64 = dir.appending(path: "bin/wine64")
        try FileManager.default.createDirectory(at: wine64.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: wine64)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine64.path(percentEncoded: false))
        #expect(CrossOverSource.unixLoader(inRoot: dir) == wine64)
    }

    @Test("A CrossOver layout keeps its own loader")
    func crossOverLoader() throws {
        let dir = try scratchDirectory("wine-loader-cx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = dir.appending(path: "lib/wine/x86_64-unix/wine")
        try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: loader)
        #expect(CrossOverSource.unixLoader(inRoot: dir) == loader)
    }

    @Test("A manifest beside a runner turns it into a build with one Rosetta tool")
    func manifestBuild() throws {
        let dir = try scratchDirectory("wine-manifest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "gptk-4.0b3"
        let manifest = ManagedRunnerManifest(
            id: id, source: .gptk, version: "4.0b3", display: "Game Porting Toolkit 4.0b3 (D3DMetal)",
            loaderSHA256: "ab", installedAt: Date(timeIntervalSince1970: 0), origin: "x.dmg", base: "Game-Porting-Toolkit-3.0-3")
        let folder = SupportPaths.runnerRoot(forBuild: id, runners: dir)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appending(path: ManagedRunners.manifestName))

        #expect(ManagedRunners.manifests(runners: dir) == [manifest])
        let build = ManagedRunners.build(from: manifest)
        #expect(build.id == id)
        #expect(build.patchedNtdll.isEmpty)
        #expect(build.tools.map(\.name) == ["notproton-gptk-4.0b3"])
        #expect(build.tools.map(\.flavor) == [.rosetta])
    }
}
