// NotProtonGPTK: runners the Wine Manager downloads, kept beside the cloned CrossOver builds.
//
// A managed runner lives at runners/crossover-<id>/CrossOver like a clone does, so the run
// script, prefix templates and tool list treat it the same way. What sets it apart is the
// manifest next to it, and the forwarders folder that stands in for the ntdll patch.

import Foundation
import Synchronization

struct ManagedRunnerManifest: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let source: WineSource
    let version: String
    let display: String
    let loaderSHA256: String
    let installedAt: Date
    let origin: String
    // GPTK 4 overlays: the Gcenx runtime D3DMetal was laid over.
    var base: String?
}

enum ManagedRunners {

    static let manifestName = "notproton-managed.json"
    static let forwardersFolder = "forwarders"
    static let step = wm("Install Wine version")

    // MARK: Registry

    private static let cache = Mutex<[RunnerBuild]?>(nil)

    static func builds() -> [RunnerBuild] {
        if let cached = cache.withLock({ $0 }) { return cached }
        let loaded = manifests().map(build(from:))
        cache.withLock { $0 = loaded }
        return loaded
    }

    static func invalidate() {
        cache.withLock { $0 = nil }
    }

    static func build(from manifest: ManagedRunnerManifest) -> RunnerBuild {
        RunnerBuild(
            bundleVersion: manifest.id, releaseVersion: manifest.version, flavor: nil,
            loaderSHA256: manifest.loaderSHA256, cleanNtdll: [:], patchedNtdll: [:],
            tools: [CompatTool(name: toolName(forRunner: manifest.id), flavor: .rosetta, display: manifest.display)]
        )
    }

    static func manifests(runners: URL = SupportPaths.runners) -> [ManagedRunnerManifest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return RunnerStore.clonedBuilds(in: runners).compactMap { id in
            let file = SupportPaths.runnerRoot(forBuild: id, runners: runners).appending(path: manifestName)
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? decoder.decode(ManagedRunnerManifest.self, from: data),
                  manifest.id == id
            else { return nil }
            return manifest
        }
        .sorted { $0.installedAt > $1.installedAt }
    }

    static func runnerID(source: WineSource, version: String) -> String {
        let cleaned = String(version.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") ? $0 : "-" })
        return String("\(source.idPrefix)-\(cleaned)".prefix(48))
    }

    static func toolName(forRunner id: String) -> String { "notproton-\(id)" }

    static func overlayID(base: WineRelease, d3dMetal version: String) -> String {
        runnerID(source: base.source, version: "\(base.version)-d3dmetal-\(version)")
    }

    // Wine 8 era runtimes have no lib/wine/x86_64-unix/wine, only bin/wine64.
    static func fallbackLoader(for loader: URL, inRoot root: URL) -> URL {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: loader.path(percentEncoded: false)) else { return loader }
        for name in ["bin/wine64", "bin/wine"] {
            let candidate = root.appending(path: name)
            if fm.isExecutableFile(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return loader
    }

    // MARK: Install

    struct Progress: Sendable {
        let label: String
        let fraction: Double?
    }

    typealias Report = @Sendable (Progress) -> Void

    static func install(_ release: WineRelease, report: @escaping Report) async throws -> ManagedRunnerManifest {
        let archive = try await download(release, report: report)
        return try await Task.detached(priority: .userInitiated) {
            try assemble(
                id: release.runnerID, source: release.source, version: release.version,
                display: release.display, origin: release.download.absoluteString, base: nil,
                archive: archive, customize: nil, report: report)
        }.value
    }

    // GPTK 4 betas are not redistributable, so the user brings Apple's DMG and its D3DMetal is
    // laid over NotProton Wine, as Apple's Read Me describes laying it over a Wine runtime.
    static func installGPTKOverlay(
        dmg: URL?, base: WineRelease, report: @escaping Report
    ) async throws -> ManagedRunnerManifest {
        let archive = try await download(base, report: report)
        return try await Task.detached(priority: .userInitiated) {
            report(Progress(label: wm("Opening Apple's Game Porting Toolkit"), fraction: nil))
            let mount = try GPTKImage.open(dmg: dmg)
            defer { mount.close() }
            let version = mount.d3dMetalVersion
            return try assemble(
                id: overlayID(base: base, d3dMetal: version),
                source: base.source, version: "\(base.version)+d3dmetal-\(version)",
                display: "\(base.display) + D3DMetal \(version)",
                origin: dmg?.lastPathComponent ?? mount.redist.path(percentEncoded: false),
                base: base.name, archive: archive,
                customize: { root in
                    report(Progress(label: wm("Patching in D3DMetal \(version)"), fraction: nil))
                    try mount.overlay(onto: root)
                },
                report: report)
        }.value
    }

    static func remove(_ id: String) throws {
        defer { invalidate() }
        try RunnerInstaller.removeClone(forBuild: id)
    }

    static var downloads: URL {
        SupportPaths.home.appending(path: "Library/Caches/\(SupportPaths.supportDirName)/wine-downloads")
    }

    private static func download(_ release: WineRelease, report: @escaping Report) async throws -> URL {
        let target = downloads.appending(path: release.download.lastPathComponent)
        let path = target.path(percentEncoded: false)
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64,
           size == release.size {
            return target
        }
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let label = wm("Downloading \(release.name)")
        report(Progress(label: label, fraction: 0))
        let temporary = try await Downloader.fetch(release.download) { report(Progress(label: label, fraction: $0)) }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    private static func assemble(
        id: String, source: WineSource, version: String, display: String, origin: String, base: String?,
        archive: URL, customize: ((URL) throws -> Void)?, report: Report
    ) throws -> ManagedRunnerManifest {
        let fm = FileManager.default
        let runners = SupportPaths.runners
        let bridge = SupportPaths.bridge
        guard fm.fileExists(atPath: bridge.appending(path: "x86_64-windows/lsteamclient.dll").path(percentEncoded: false)) else {
            throw StepFailure(step: step, detail: wm("Install NotProton from the Status pane before adding Wine versions."))
        }

        let lock = try DeploymentContent.acquireInstallationLock()
        defer { lock.release() }

        let target = SupportPaths.runnerRoot(forBuild: id, runners: runners)
        if RunnerInstaller.isRunning(from: target) {
            throw StepFailure(step: step, detail: wm("A game or Wine tool is running on \(display). Quit it first."))
        }
        try fm.createDirectory(at: runners, withIntermediateDirectories: true)
        let staging = runners.appending(path: ".crossover-\(id).new")
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        let unpacked = staging.appending(path: "unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)

        report(Progress(label: wm("Extracting \(archive.lastPathComponent)"), fraction: nil))
        let tar = try Shell.run("/usr/bin/tar", ["-xf", archive.path(percentEncoded: false), "-C", unpacked.path(percentEncoded: false)])
        guard tar.succeeded else {
            throw StepFailure(step: step, detail: wm("Extracting failed. \(tar.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
        guard let wine = wineRoot(in: unpacked) else {
            throw StepFailure(step: step, detail: wm("\(archive.lastPathComponent) has no Wine runtime in it."))
        }
        let root = staging.appending(path: "CrossOver")
        try fm.moveItem(at: wine, to: root)
        try? fm.removeItem(at: unpacked)
        RunnerInstaller.scrubDownloadMarkers(at: root)

        try customize?(root)

        report(Progress(label: wm("Preparing \(display)"), fraction: nil))
        try signLoaders(in: root)
        try SteamclientForwarder.install(into: staging.appending(path: forwardersFolder), bridge: bridge)

        let loader = CrossOverSource.unixLoader(inRoot: root)
        guard let hash = Digest.sha256IfPresent(loader) else {
            throw StepFailure(step: step, detail: wm("\(display) has no Wine loader."))
        }
        let manifest = ManagedRunnerManifest(
            id: id, source: source, version: version, display: display, loaderSHA256: hash,
            installedAt: Date(), origin: origin, base: base)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appending(path: manifestName))

        if fm.fileExists(atPath: target.path(percentEncoded: false)) {
            let trash = runners.appending(path: ".crossover-\(id).\(UUID().uuidString).removing")
            try fm.moveItem(at: target, to: trash)
            try? fm.removeItem(at: trash)
        }
        try fm.moveItem(at: staging, to: target)
        invalidate()

        let build = build(from: manifest)
        do {
            _ = try RunnerSetup.prepare(
                build,
                license: { _ in CrossOverLicense.Status(licensed: true, detail: "", diagnostic: "managed runner") },
                report: { report(Progress(label: $0.label, fraction: nil)) })
        } catch {
            AppLog.note("managed runner \(id) did not set up: \(error.localizedDescription)")
            throw error
        }
        return manifest
    }

    // The folder holding bin/ and lib/wine, wherever the archive put its app bundle.
    static func wineRoot(in folder: URL) -> URL? {
        let fm = FileManager.default
        var queue = [(folder, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            if fm.fileExists(atPath: dir.appending(path: "lib/wine").path(percentEncoded: false)),
               fm.fileExists(atPath: dir.appending(path: "bin/wineserver").path(percentEncoded: false)) {
                return dir
            }
            guard depth < 5 else { continue }
            let children = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
            for child in children.sorted(by: { $0.path < $1.path }) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }

    // RunnerPatcher extends a loader's entitlements but will not invent them. The downloaded
    // loaders are unsigned, so sign them ad hoc with what Wine needs plus the dyld entitlement.
    private static func signLoaders(in root: URL) throws {
        let entitlements = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
        <key>com.apple.security.cs.allow-jit</key><true/>
        <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
        <key>com.apple.security.cs.disable-library-validation</key><true/>
        </dict></plist>
        """
        let plist = FileManager.default.temporaryDirectory.appending(path: "np-managed-\(UUID().uuidString).plist")
        try Data(entitlements.utf8).write(to: plist)
        defer { try? FileManager.default.removeItem(at: plist) }
        for loader in RunnerPatcher.unixLoaders(in: root) {
            let result = try Shell.run("/usr/bin/codesign", [
                "-f", "-s", "-", "--entitlements", plist.path(percentEncoded: false), loader.path(percentEncoded: false),
            ])
            guard result.succeeded else {
                throw StepFailure(step: step, detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

// URLSession's async download reports no progress, so this wraps the delegate form.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, any Error>?
    private var lastReported = -1.0

    private init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    static func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = Downloader(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard expected > 0 else { return }
        let fraction = Double(written) / Double(expected)
        guard fraction - lastReported >= 0.005 else { return }
        lastReported = fraction
        progress(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(StepFailure(step: ManagedRunners.step, detail: wm("The download answered \(http.statusCode)."))))
            return
        }
        // The file at location is deleted when this returns.
        let kept = FileManager.default.temporaryDirectory.appending(path: "np-wine-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
