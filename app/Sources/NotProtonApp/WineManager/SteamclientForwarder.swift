// NotProtonGPTK: builds steamclient(64).dll forwarders for runners without the ntdll patch.
//
// Pinned CrossOver builds get an ntdll detour that points Valve's steamclient64.dll at
// lsteamclient while it loads. A downloaded Wine has no pinned hook sites, so instead the
// prefix gets a steamclient that is nothing but an export table forwarding every name to
// lsteamclient. That is how Proton worked before it moved to the ntdll hook; the cost is
// that DRM which inspects steamclient64.dll on disk sees this file and not Valve's.

import Foundation

enum SteamclientForwarder {

    static let step = wm("Build steamclient forwarders")

    struct Image {
        let machine: UInt16
        let exports: [String]
    }

    static func exports(of dll: Data) throws -> Image {
        let b = [UInt8](dll)
        func u16(_ o: Int) throws -> UInt16 {
            guard o >= 0, o + 2 <= b.count else { throw bad("truncated") }
            return UInt16(b[o]) | UInt16(b[o + 1]) << 8
        }
        func u32(_ o: Int) throws -> UInt32 {
            guard o >= 0, o + 4 <= b.count else { throw bad("truncated") }
            return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        }
        guard try u16(0) == 0x5a4d else { throw bad("not a PE image") }
        let pe = Int(try u32(0x3c))
        guard try u32(pe) == 0x4550 else { throw bad("not a PE image") }
        let machine = try u16(pe + 4)
        let sections = Int(try u16(pe + 6))
        let optSize = Int(try u16(pe + 20))
        let opt = pe + 24
        let dirs = opt + (try u16(opt) == 0x20b ? 112 : 96)
        let exportRVA = Int(try u32(dirs))
        let table = opt + optSize

        func offset(_ rva: Int) throws -> Int {
            for i in 0..<sections {
                let s = table + i * 40
                let va = Int(try u32(s + 12)), vsize = Int(try u32(s + 8))
                let raw = Int(try u32(s + 20)), rawSize = Int(try u32(s + 16))
                if rva >= va && rva < va + max(vsize, rawSize) { return rva - va + raw }
            }
            throw bad("RVA \(rva) is outside every section")
        }
        func string(_ rva: Int) throws -> String {
            var o = try offset(rva)
            var bytes: [UInt8] = []
            while o < b.count, b[o] != 0 { bytes.append(b[o]); o += 1 }
            return String(decoding: bytes, as: UTF8.self)
        }

        guard exportRVA != 0 else { return Image(machine: machine, exports: []) }
        let dir = try offset(exportRVA)
        let count = Int(try u32(dir + 24))
        let names = try offset(Int(try u32(dir + 32)))
        let exports = try (0..<count).map { try string(Int(try u32(names + $0 * 4))) }
            .filter { !$0.hasPrefix("__wine") && $0.allSatisfy { $0.isASCII && !$0.isWhitespace } }
        return Image(machine: machine, exports: exports)
    }

    // An image with one read-only section holding an export directory, no code, no imports
    // and no entry point. Every export lies inside the export directory, which is what makes
    // the loader treat it as a forwarder.
    static func forwarder(named dllName: String, machine: UInt16, exports: [String], to target: String = "lsteamclient") -> Data {
        let is64 = machine != 0x14c
        let names = Array(Set(exports)).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        let n = names.count
        let sectionRVA = 0x1000, headerSize = 0x400

        var body: [UInt8] = []
        func put16(_ v: Int) { body += [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        func put32(_ v: Int) { put16(v & 0xffff); put16(v >> 16 & 0xffff) }

        let eat = 40, npt = eat + 4 * n, ord = npt + 4 * n
        let strings = ord + 2 * n
        var pool: [UInt8] = []
        func intern(_ s: String) -> Int {
            let at = strings + pool.count
            pool += Array(s.utf8) + [0]
            return sectionRVA + at
        }
        let dllNameRVA = intern(dllName)
        let nameRVAs = names.map(intern)
        let forwardRVAs = names.map { intern("\(target).\($0)") }

        put32(0); put32(0); put16(0); put16(0)
        put32(dllNameRVA); put32(1); put32(n); put32(n)
        put32(sectionRVA + eat); put32(sectionRVA + npt); put32(sectionRVA + ord)
        forwardRVAs.forEach(put32)
        nameRVAs.forEach(put32)
        (0..<n).forEach(put16)
        body += pool
        let rawSize = (body.count + 0x1ff) & ~0x1ff
        let imageSize = sectionRVA + ((body.count + 0xfff) & ~0xfff)

        var h: [UInt8] = []
        func h16(_ v: Int) { h += [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        func h32(_ v: Int) { h16(v & 0xffff); h16(v >> 16 & 0xffff) }
        func h64(_ v: UInt64) { h32(Int(v & 0xffff_ffff)); h32(Int(v >> 32)) }

        h16(0x5a4d); h += [UInt8](repeating: 0, count: 0x3a); h32(0x40)
        h32(0x4550)
        h16(Int(machine)); h16(1); h32(0); h32(0); h32(0)
        h16(is64 ? 0xf0 : 0xe0); h16(is64 ? 0x2022 : 0x2102)
        h16(is64 ? 0x20b : 0x10b); h16(0)
        h32(0); h32(rawSize); h32(0)
        h32(0); h32(sectionRVA)
        if is64 { h64(0x1_8000_0000) } else { h32(sectionRVA); h32(0x1000_0000) }
        h32(0x1000); h32(0x200)
        h16(6); h16(0); h16(0); h16(0); h16(6); h16(0); h32(0)
        h32(imageSize); h32(headerSize); h32(0)
        h16(2); h16(0x0100)
        if is64 { h64(0x100000); h64(0x1000); h64(0x100000); h64(0x1000) } else {
            h32(0x100000); h32(0x1000); h32(0x100000); h32(0x1000)
        }
        h32(0); h32(16)
        h32(sectionRVA); h32(body.count)
        h += [UInt8](repeating: 0, count: 15 * 8)
        h += Array(".rdata".utf8) + [0, 0]
        h32(body.count); h32(sectionRVA); h32(rawSize); h32(headerSize)
        h32(0); h32(0); h16(0); h16(0); h32(0x4000_0040)
        h += [UInt8](repeating: 0, count: headerSize - h.count)

        return Data(h + body + [UInt8](repeating: 0, count: rawSize - body.count))
    }

    // Writes forwarders/steamclient64.dll and forwarders/steamclient.dll beside a runner.
    static func install(into folder: URL, bridge: URL = SupportPaths.bridge) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (arch, name) in [("x86_64-windows", "steamclient64.dll"), ("i386-windows", "steamclient.dll")] {
            let source = bridge.appending(path: "\(arch)/lsteamclient.dll")
            guard let data = try? Data(contentsOf: source) else {
                throw StepFailure(step: step, detail: wm("\(arch)/lsteamclient.dll is not in the bridge. Install NotProton from Status first."))
            }
            let image = try exports(of: data)
            guard !image.exports.isEmpty else { throw bad("\(arch)/lsteamclient.dll exports nothing") }
            try forwarder(named: name, machine: image.machine, exports: image.exports)
                .write(to: folder.appending(path: name), options: .atomic)
        }
    }

    private static func bad(_ detail: String) -> StepFailure {
        StepFailure(step: step, detail: detail)
    }
}
