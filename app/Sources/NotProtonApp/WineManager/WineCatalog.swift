// NotProtonGPTK: the GitHub release feeds the Wine Manager downloads runners from

import Foundation

enum WineSource: String, CaseIterable, Identifiable, Sendable, Codable {
    case gptk
    case wineCrossover
    case wineStaging

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gptk: "Game-Porting-Toolkit"
        case .wineCrossover: "Wine-Crossover"
        case .wineStaging: "Wine-Staging-macOS"
        }
    }

    var blurb: String {
        switch self {
        case .gptk:
            String(localized: "Game Porting Toolkit is developed by Apple and is recommended for Apple Silicon Macs. It works best for newer games that use DX12. Builds are packaged by Gcenx; GPTK 4 betas can be patched in from Apple's DMG.")
        case .wineCrossover:
            String(localized: "Wine-Crossover is CodeWeavers' open source Wine tree, built by Gcenx. It uses DXMT/DXVK-style translation rather than D3DMetal and suits older DX9-DX11 games.")
        case .wineStaging:
            String(localized: "Wine-Staging is upstream Wine with the staging patch set, built for macOS by Gcenx. It is the newest Wine, but has no D3DMetal.")
        }
    }

    // Kept short: the build id and tool name both have to fit in 63 characters.
    var idPrefix: String {
        switch self {
        case .gptk: "gptk"
        case .wineCrossover: "winecx"
        case .wineStaging: "wine-staging"
        }
    }

    var repo: String {
        switch self {
        case .gptk: "Gcenx/game-porting-toolkit"
        case .wineCrossover: "Heroic-Games-Launcher/wine-crossover"
        case .wineStaging: "Gcenx/macOS_Wine_builds"
        }
    }

    func accepts(asset name: String) -> Bool {
        guard name.hasSuffix(".tar.xz") else { return false }
        switch self {
        case .gptk, .wineCrossover: return true
        case .wineStaging: return name.hasPrefix("wine-staging-")
        }
    }

    func version(fromTag tag: String) -> String {
        switch self {
        case .gptk: tag.replacingOccurrences(of: "Game-Porting-Toolkit-", with: "")
        case .wineCrossover, .wineStaging: tag
        }
    }

    func display(version: String) -> String {
        switch self {
        case .gptk: "Game Porting Toolkit \(version)"
        case .wineCrossover: "Wine-Crossover \(version)"
        case .wineStaging: "Wine-Staging \(version)"
        }
    }
}

struct WineRelease: Identifiable, Sendable, Hashable {
    let source: WineSource
    let tag: String
    let version: String
    let published: Date
    let size: Int64
    let download: URL
    let page: URL
    let prerelease: Bool

    var id: String { runnerID }
    var name: String { "\(source.title)-\(version)" }
    var runnerID: String { ManagedRunners.runnerID(source: source, version: version) }
    var display: String { source.display(version: version) }
}

enum WineCatalog {

    static let step = String(localized: "List Wine versions")

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let published_at: Date
        let prerelease: Bool
        let draft: Bool
        let assets: [Asset]
    }

    static func fetch(_ source: WineSource, session: URLSession = .shared) async throws -> [WineRelease] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(source.repo)/releases?per_page=100")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NotProtonGPTK", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = http.statusCode == 403
                ? String(localized: "GitHub's rate limit was reached. Try again in a few minutes.")
                : String(localized: "GitHub answered \(http.statusCode).")
            throw StepFailure(step: step, detail: detail)
        }
        return try parse(data, source: source)
    }

    static func parse(_ data: Data, source: WineSource) throws -> [WineRelease] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Release].self, from: data)
            .filter { !$0.draft }
            .compactMap { release in
                guard let asset = release.assets.first(where: { source.accepts(asset: $0.name) }) else { return nil }
                return WineRelease(
                    source: source, tag: release.tag_name, version: source.version(fromTag: release.tag_name),
                    published: release.published_at, size: asset.size, download: asset.browser_download_url,
                    page: release.html_url, prerelease: release.prerelease)
            }
            .sorted { $0.published > $1.published }
    }

    // What "latest" means for a source: the newest release that is not a beta.
    static func latest(_ releases: [WineRelease]) -> WineRelease? {
        releases.first { !$0.prerelease } ?? releases.first
    }
}
