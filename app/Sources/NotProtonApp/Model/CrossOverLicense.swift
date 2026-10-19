// Checks paid license signatures and active CrossOver trials.

import Foundation

enum CrossOverLicense {

    struct Status: Sendable {
        let licensed: Bool
        let detail: String
        // The real reason, for the log.
        let diagnostic: String
        var trialExpiresAt: Date? = nil
    }

    static let defaultSearchDirs: [URL] = {
        let home = URL(filePath: NSHomeDirectory())
        return [
            home.appending(path: "Library/Preferences"),
            URL(filePath: "/Library/Preferences"),
        ]
    }()

    private static let licenseBase = "com.codeweavers.CrossOver"

    static let notActivatedTitle = String(localized: "CrossOver does not appear to be activated.")
    static let trialAdvice = String(localized: "A paid license or an active 14-day CrossOver trial is required.")
    static let notActivatedAdvice = "\(String(localized: "Please run CrossOver and try again.")) \(trialAdvice)"
    static var notActivated: String { "\(notActivatedTitle) \(notActivatedAdvice)" }

    static let trialDuration: TimeInterval = 14 * 24 * 60 * 60
    static let trialMarker = "notproton-trial-expires"

    static let defaultOpenssl = "/usr/bin/openssl"

    static func check(
        crossOverRoot: URL,
        searchDirs: [URL] = defaultSearchDirs,
        openssl: String = defaultOpenssl,
        now: Date = Date()
    ) -> Status {
        let paid = evaluate(
            crossOverRoot: crossOverRoot, searchDirs: searchDirs, openssl: openssl
        )
        let status = paid.licensed ? paid : trialStatus(
            crossOverRoot: crossOverRoot, searchDirs: searchDirs, now: now
        ) ?? paid
        AppLog.note("license: \(status.diagnostic)")
        return status
    }

    private static func evaluate(
        crossOverRoot: URL,
        searchDirs: [URL],
        openssl: String
    ) -> Status {
        let keyFile = crossOverRoot.appending(
            path: "share/crossover/data/tie.pub"
        ).path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: keyFile) else {
            return Status(
                licensed: false,
                detail: notActivated,
                diagnostic: "no verification key in the CrossOver bundle"
            )
        }

        var rejection: String?

        for dir in searchDirs {
            let label = dir.path(percentEncoded: false)
            let license = dir.appending(path: "\(licenseBase).license")
                .path(percentEncoded: false)

            guard FileManager.default.fileExists(atPath: license) else { continue }

            let signatures = sidecars(in: dir)
            guard !signatures.isEmpty else {
                rejection = "the license in \(label) has no signature beside it"
                continue
            }

            var unchecked: String?

            for signature in signatures {
                let result: CommandResult
                do {
                    result = try Shell.run(openssl, [
                        "dgst", signature.digest, "-verify", keyFile,
                        "-signature", signature.path, license,
                    ])
                } catch {
                    return Status(
                        licensed: false,
                        detail: notActivated,
                        diagnostic: "could not run \(openssl) to verify the license"
                    )
                }

                if result.succeeded {
                    return Status(
                        licensed: true,
                        detail: String(localized: "CrossOver is activated."),
                        diagnostic: "valid license in \(label)"
                    )
                }

                let trouble = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trouble.isEmpty {
                    if trouble.localizedCaseInsensitiveContains("unable to load key") {
                        return Status(
                            licensed: false,
                            detail: notActivated,
                            diagnostic: "the verification key in the CrossOver bundle could not be read"
                        )
                    }
                    unchecked = "the license in \(label) could not be checked"
                }
            }

            rejection = unchecked
                ?? "no signature beside the license in \(label) verified against this bundle"
        }

        return Status(
            licensed: false,
            detail: notActivated,
            diagnostic: rejection ?? "no CrossOver license file found"
        )
    }

    static func requireValid(
        for install: CrossOverInstall, searchDirs: [URL] = defaultSearchDirs
    ) throws {
        let status = check(crossOverRoot: install.crossOverRoot, searchDirs: searchDirs)
        guard status.licensed else {
            throw StepFailure(
                step: String(localized: "Verify CrossOver license"),
                detail: status.detail
            )
        }
    }

    private static func trialStatus(crossOverRoot: URL, searchDirs: [URL], now: Date) -> Status? {
        guard FileManager.default.fileExists(atPath: crossOverRoot
            .appending(path: "share/crossover/data/tie.pub").path) else { return nil }
        // CrossOver records this date when its trial is first started.
        guard let dir = searchDirs.first,
              let data = try? Data(contentsOf: dir.appending(path: "\(licenseBase).plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let firstRun = (plist as? [String: Any])?["FirstRunDate"] as? Date
        else { return nil }
        let expiry = firstRun.addingTimeInterval(trialDuration)
        guard firstRun <= now, now < expiry else {
            return Status(licensed: false, detail: notActivated,
                diagnostic: firstRun > now ? "CrossOver trial start date is in the future" : "CrossOver trial has expired")
        }
        return Status(licensed: true,
            detail: String(localized: "CrossOver trial is active until \(expiry.formatted(date: .abbreviated, time: .shortened))."),
            diagnostic: "active CrossOver trial", trialExpiresAt: expiry)
    }

    static func recordTrial(_ status: Status, in root: URL) throws {
        let marker = root.appending(path: trialMarker)
        if let expiry = status.trialExpiresAt {
            let start = Int(expiry.addingTimeInterval(-trialDuration).timeIntervalSince1970)
            let end = Int(expiry.timeIntervalSince1970)
            try atomicReplace(marker, with: Data("\(start) \(end)\n".utf8), step: "Record CrossOver trial")
        } else if status.licensed, FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    static func requireRunnerAccess(
        _ root: URL, searchDirs: [URL] = defaultSearchDirs, now: Date = Date()
    ) throws {
        let marker = root.appending(path: trialMarker)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        let status = check(crossOverRoot: root, searchDirs: searchDirs, now: now)
        if status.licensed, status.trialExpiresAt == nil { return }
        let fields = (try? String(contentsOf: marker, encoding: .utf8))?
            .split(whereSeparator: \.isWhitespace) ?? []
        if status.licensed, fields.count == 2,
           let start = Int64(fields[0]), let end = Int64(fields[1]), start >= 0, end >= start,
           end - start == Int64(trialDuration),
           now.timeIntervalSince1970 >= Double(start), now.timeIntervalSince1970 < Double(end) { return }
        throw StepFailure(step: String(localized: "Verify CrossOver license"), detail: notActivated)
    }

    private static func sidecars(in dir: URL) -> [(path: String, digest: String)] {
        let candidates: [(path: String, digest: String)] = [
            (dir.appending(path: "\(licenseBase).sha256").path(percentEncoded: false), "-sha256"),
            (dir.appending(path: "\(licenseBase).sig").path(percentEncoded: false), "-sha1"),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
