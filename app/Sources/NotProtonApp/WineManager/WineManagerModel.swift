// NotProtonGPTK: state behind the Wine Manager pane

import AppKit
import Foundation

@MainActor
@Observable
final class WineManagerModel {

    struct Job: Equatable {
        let id: String
        var label: String
        var fraction: Double?
    }

    var source: WineSource = .gptk
    var search = ""
    private(set) var releases: [WineSource: [WineRelease]] = [:]
    private(set) var installed: [ManagedRunnerManifest] = []
    private(set) var loading: Set<WineSource> = []
    private(set) var job: Job?
    private(set) var failure: String?
    private(set) var outcome: String?
    private(set) var foundDMG: URL?
    private var work: Task<Void, Never>?

    static let gptkOverlayJob = "gptk-overlay"

    var visibleReleases: [WineRelease] {
        let all = releases[source] ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    // Installed runners of this source that the feed does not list, such as a GPTK 4 overlay.
    var unlistedInstalled: [ManagedRunnerManifest] {
        let listed = Set((releases[source] ?? []).map(\.runnerID))
        return installed.filter { $0.source == source && !listed.contains($0.id) }
    }

    var latestBase: WineRelease? { WineCatalog.latest(releases[.gptk] ?? []) }

    func manifest(for release: WineRelease) -> ManagedRunnerManifest? {
        installed.first { $0.id == release.runnerID }
    }

    func appear() async {
        reloadInstalled()
        if releases[source] == nil { await load(source) }
        if source != .gptk, releases[.gptk] == nil { await load(.gptk) }
    }

    func select(_ new: WineSource) async {
        source = new
        if releases[new] == nil { await load(new) }
    }

    func refresh() async {
        reloadInstalled()
        await load(source)
    }

    private func reloadInstalled() {
        installed = ManagedRunners.manifests()
        foundDMG = GPTKImage.findDMG()
    }

    private func load(_ source: WineSource) async {
        guard !loading.contains(source) else { return }
        loading.insert(source)
        defer { loading.remove(source) }
        do {
            releases[source] = try await WineCatalog.fetch(source)
        } catch {
            failure = error.localizedDescription
        }
    }

    func install(_ release: WineRelease) {
        run(id: release.runnerID, first: String(localized: "Downloading \(release.name)")) { report in
            let manifest = try await ManagedRunners.install(release, report: report)
            return String(localized: "\(manifest.display) is ready. Restart Steam, then pick it under Properties > Compatibility.")
        }
    }

    func importGPTK(dmg: URL?) {
        guard let base = latestBase else {
            failure = String(localized: "The Game Porting Toolkit list has not loaded yet, so there is no runtime to patch.")
            return
        }
        run(id: Self.gptkOverlayJob, first: String(localized: "Preparing Game Porting Toolkit")) { report in
            let manifest = try await ManagedRunners.installGPTKOverlay(dmg: dmg, base: base, report: report)
            return String(localized: "\(manifest.display) is ready, built on \(base.name). Restart Steam, then pick it under Properties > Compatibility.")
        }
    }

    func chooseDMG() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diskImage]
        panel.directoryURL = SupportPaths.home.appending(path: "Downloads")
        panel.message = String(localized: "Choose Apple's Game Porting Toolkit DMG")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importGPTK(dmg: url)
    }

    func openAppleDownloads() {
        NSWorkspace.shared.open(GPTKImage.appleDownloads)
    }

    func remove(_ id: String) {
        run(id: id, first: String(localized: "Removing")) { _ in
            try await Task.detached { try ManagedRunners.remove(id) }.value
            return String(localized: "Removed. Restart Steam to update its list of compatibility tools.")
        }
    }

    func reveal(_ id: String) {
        let root = SupportPaths.runnerRoot(forBuild: id)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func cancel() {
        work?.cancel()
    }

    func dismissMessages() {
        failure = nil
        outcome = nil
    }

    private func run(
        id: String, first: String,
        _ body: @escaping @Sendable (@escaping ManagedRunners.Report) async throws -> String
    ) {
        guard job == nil else { return }
        dismissMessages()
        job = Job(id: id, label: first, fraction: nil)
        work = Task {
            do {
                outcome = try await body { progress in
                    Task { @MainActor in
                        guard self.job?.id == id else { return }
                        self.job = Job(id: id, label: progress.label, fraction: progress.fraction)
                    }
                }
            } catch is CancellationError {
                outcome = String(localized: "Cancelled.")
            } catch let error as URLError where error.code == .cancelled {
                outcome = String(localized: "Cancelled.")
            } catch {
                failure = error.localizedDescription
            }
            job = nil
            work = nil
            reloadInstalled()
        }
    }
}
