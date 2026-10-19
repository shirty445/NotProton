import Foundation
import Testing

@testable import NotProtonApp

// The check gates whether a runner may be cloned, so a wrong unlicensed verdict strands a user
// who holds a good license. Fixtures carry their own keypair, so it reads the same either way.
@Suite("CrossOver license")
struct CrossOverLicenseTests {

    // The tree hangs off a bundle so the layout check() is handed directly and the one
    // requireValid derives from a bundle are the same tree.
    private struct Fixture {
        let dir: URL
        let bundle: URL
        let local: URL
        let system: URL
        let key: URL

        var root: URL { SupportPaths.crossOverRoot(inBundle: bundle) }
        var publishedKey: URL { root.appending(path: "share/crossover/data/tie.pub") }
        var searchDirs: [URL] { [local, system] }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    private static let base = "com.codeweavers.CrossOver"

    private static let body = """
        [crossmac]
        customer=Test
        expires=2999/01/01
        [license]
        id=test

        """

    private static func fixture(withKey: Bool = true) throws -> Fixture {
        let fm = FileManager.default
        let dir = URL.temporaryDirectory.appending(path: "np-license-\(UUID().uuidString)")
        let fix = Fixture(
            dir: dir,
            bundle: dir.appending(path: "CrossOver.app"),
            local: dir.appending(path: "local"),
            system: dir.appending(path: "system"),
            key: dir.appending(path: "private.pem")
        )

        // The caller registers teardown on what it is handed, so a fixture that throws
        // half built has to take its own tree with it.
        do {
            for made in [
                fix.publishedKey.deletingLastPathComponent(), fix.local, fix.system,
            ] {
                try fm.createDirectory(at: made, withIntermediateDirectories: true)
            }
            try generate(key: fix.key, publishing: withKey ? fix.publishedKey : nil)
        } catch {
            fix.remove()
            throw error
        }
        return fix
    }

    // check, not run: openssl failing here leaves the fixture without the file the test
    // is about, and a test that then passes proves nothing.
    private static func generate(key: URL, publishing pub: URL?) throws {
        try Shell.check(
            CrossOverLicense.defaultOpenssl,
            ["genrsa", "-out", key.path(percentEncoded: false), "2048"]
        )
        guard let pub else { return }
        try Shell.check(CrossOverLicense.defaultOpenssl, [
            "rsa", "-in", key.path(percentEncoded: false),
            "-pubout", "-out", pub.path(percentEncoded: false),
        ])
    }

    @discardableResult
    private static func writeLicense(in dir: URL) throws -> URL {
        let license = dir.appending(path: "\(base).license")
        try body.write(to: license, atomically: true, encoding: .utf8)
        return license
    }

    private static func sign(
        _ license: URL, with key: URL, digest: String, sidecar: String
    ) throws {
        try Shell.check(CrossOverLicense.defaultOpenssl, [
            "dgst", digest, "-sign", key.path(percentEncoded: false),
            "-out", license.deletingLastPathComponent()
                .appending(path: "\(base).\(sidecar)").path(percentEncoded: false),
            license.path(percentEncoded: false),
        ])
    }

    @Test("A license signed by the bundle's key is accepted")
    func validLicenseIsAccepted() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(status.licensed)
    }

    @Test("A bundle carrying no verification key is named in the diagnostic")
    func missingKeyIsNamed() throws {
        let fix = try Self.fixture(withKey: false)
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!status.licensed)
        #expect(status.diagnostic == "no verification key in the CrossOver bundle")
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // Both read the same to the user, so the log is the only thing left that can tell an
    // install that never had a license from one whose license was refused.
    @Test("No license file reads apart from a license that fails")
    func absentLicenseReadsApartFromInvalid() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }

        let absent = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!absent.licensed)
        #expect(absent.diagnostic == "no CrossOver license file found")
        #expect(absent.detail == CrossOverLicense.notActivated)

        let license = try Self.writeLicense(in: fix.local)
        let other = fix.local.appending(path: "other.pem")
        try Self.generate(key: other, publishing: nil)
        try Self.sign(license, with: other, digest: "-sha256", sidecar: "sha256")

        let wrong = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!wrong.licensed)
        #expect(wrong.diagnostic.contains("verified against this bundle"))
        #expect(wrong.diagnostic != absent.diagnostic)
        #expect(wrong.detail == CrossOverLicense.notActivated)
    }

    @Test("A license with no signature beside it is named as such")
    func unsignedLicenseIsNamed() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        try Self.writeLicense(in: fix.local)

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!status.licensed)
        #expect(status.diagnostic.contains("has no signature beside it"))
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // The sidecar that verifies is not always the first one present, and taking only
    // the first turned a good license into an invalid one.
    @Test("A stale .sha256 does not condemn a license the .sig verifies")
    func staleSidecarDoesNotCondemnTheLicense() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha1", sidecar: "sig")
        try Data(repeating: 0x41, count: 256).write(
            to: fix.local.appending(path: "\(Self.base).sha256")
        )

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(status.licensed)
    }

    @Test("A license kept only in the system directory is found")
    func systemDirectoryIsSearched() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.system)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(status.licensed)
        #expect(status.diagnostic.contains(fix.system.path(percentEncoded: false)))
    }

    // Without the tool there is no verdict, and the user is told the same thing either way, so
    // the log is the only place a missing openssl reads apart from a CrossOver never activated.
    @Test("A missing openssl reads apart from an unactivated CrossOver in the log")
    func missingToolIsNotReportedAsUnlicensed() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        let status = CrossOverLicense.check(
            crossOverRoot: fix.root,
            searchDirs: fix.searchDirs,
            openssl: "/usr/bin/notproton-no-such-openssl"
        )
        #expect(!status.licensed)
        #expect(status.diagnostic.contains("could not run"))
        #expect(status.diagnostic.contains("notproton-no-such-openssl"))
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // The reason reaches the user only through the thrown failure. requireValid searches the
    // machine's own directories, so only the two agreeing is fixed, not the text itself.
    @Test("The refusal carries the reason the check found and nothing else")
    func refusalCarriesTheReason() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let install = CrossOverInstall(
            bundle: fix.bundle, releaseVersion: nil, support: .unreadable
        )

        // A key generated for this fixture verifies no license on this machine, and a
        // machine with no license has nothing to find either.
        let expected = CrossOverLicense.check(crossOverRoot: install.crossOverRoot, searchDirs: fix.searchDirs)
        #expect(!expected.licensed)

        do {
            try CrossOverLicense.requireValid(for: install, searchDirs: fix.searchDirs)
            Issue.record("requireValid accepted a bundle whose key verifies nothing")
        } catch let failure as StepFailure {
            #expect(failure.detail == expected.detail)
        }
    }

    // An unreadable key exits the same status as a signature that does not match, which
    // leaves the log as the only place the two are told apart.
    @Test("An unreadable verification key reads apart from a license that fails in the log")
    func unreadableKeyReadsApartFromInvalid() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")
        try Data("not a key".utf8).write(to: fix.publishedKey)

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!status.licensed)
        #expect(status.diagnostic == "the verification key in the CrossOver bundle could not be read")
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // Same exit status again, and the license here is the one thing known to be good.
    @Test("A signature openssl cannot read is not called an invalid license")
    func unreadableSidecarIsNotCalledInvalid() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: fix.local.appending(path: "\(Self.base).sha256")
                .path(percentEncoded: false)
        )

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!status.licensed)
        #expect(status.diagnostic.contains("could not be checked"))
        #expect(status.detail == CrossOverLicense.notActivated)
    }
    private func trial(_ firstRun: Any, in fix: Fixture) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["FirstRunDate": firstRun], format: .binary, options: 0)
        try data.write(to: fix.local.appending(path: "\(Self.base).plist"))
    }

    @Test("An active trial works without paid license files and expires at the boundary")
    func trialBoundaries() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try trial(start, in: fix)
        let expiry = start.addingTimeInterval(CrossOverLicense.trialDuration)
        for now in [start, expiry.addingTimeInterval(-1)] {
            let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs, now: now)
            #expect(status.licensed)
            #expect(status.trialExpiresAt == expiry)
        }
        for now in [start.addingTimeInterval(-1), expiry, expiry.addingTimeInterval(1)] {
            #expect(!CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs, now: now).licensed)
        }
    }

    @Test("Malformed dates and missing bundle verification keys cannot activate a trial")
    func invalidTrials() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        for value: Any in ["2026-10-19", 1234, true] {
            try trial(value, in: fix)
            #expect(!CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs).licensed)
        }
        try trial(Date(), in: fix)
        try FileManager.default.removeItem(at: fix.publishedKey)
        #expect(!CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs).licensed)
    }

    @Test("A paid license takes priority over an expired trial")
    func purchaseOverridesTrial() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        try trial(Date(timeIntervalSince1970: 0), in: fix)
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")
        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(status.licensed)
        #expect(status.trialExpiresAt == nil)
    }

    @Test("Preparing a trial runner records its original expiry and a purchase clears it")
    func recordsTrial() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let start = Date()
        try trial(start, in: fix)
        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        try CrossOverLicense.recordTrial(status, in: fix.root)
        let marker = fix.root.appending(path: CrossOverLicense.trialMarker)
        let fields = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isWhitespace)
        #expect(fields.count == 2)
        #expect(Int(fields[1]) == Int(start.addingTimeInterval(CrossOverLicense.trialDuration).timeIntervalSince1970))
        try CrossOverLicense.recordTrial(.init(licensed: true, detail: "paid", diagnostic: "test"), in: fix.root)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Wine tools cannot outlive the recorded trial even if preferences change")
    func toolsRespectRecordedExpiry() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = start.addingTimeInterval(CrossOverLicense.trialDuration)
        try trial(start, in: fix)
        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs, now: start)
        try CrossOverLicense.recordTrial(status, in: fix.root)
        try CrossOverLicense.requireRunnerAccess(fix.root, searchDirs: fix.searchDirs, now: start)
        try trial(expiry, in: fix)
        #expect(throws: StepFailure.self) {
            try CrossOverLicense.requireRunnerAccess(fix.root, searchDirs: fix.searchDirs, now: expiry)
        }
    }

}
