import Compression
import Foundation

/// Files in an export, whether the user picked the ZIP or an unzipped folder.
protocol ExportFiles {
    var paths: [String] { get }
    func read(_ path: String) throws -> Data?
}

/// Read-only ZIP archive (stored and deflated entries, Zip64) over a
/// memory-mapped file. Sizes come from the central directory, so entries
/// written with data descriptors (as Strava's are) read fine.
struct ZipReader: ExportFiles {
    struct Entry {
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var localOffset: Int
    }

    enum ZipError: Error {
        case notZip
        case corrupt
        case unsupportedMethod(UInt16)
    }

    private let data: Data
    private let entries: [String: Entry]

    var paths: [String] { Array(entries.keys) }

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        let bytes = Bytes(data: data)
        guard let eocd = Self.findEndOfCentralDirectory(bytes) else { throw ZipError.notZip }
        var count = Int(try bytes.u16(eocd + 10))
        var dirOffset = Int(try bytes.u32(eocd + 16))
        if count == 0xFFFF || dirOffset == 0xFFFF_FFFF {
            // Zip64 locator sits just before the classic end record.
            let locator = eocd - 20
            guard locator >= 0, try bytes.u32(locator) == 0x0706_4B50 else { throw ZipError.corrupt }
            let record = Int(try bytes.u64(locator + 8))
            guard try bytes.u32(record) == 0x0606_4B50 else { throw ZipError.corrupt }
            count = Int(try bytes.u64(record + 32))
            dirOffset = Int(try bytes.u64(record + 48))
        }

        var entries: [String: Entry] = [:]
        var p = dirOffset
        for _ in 0..<count {
            guard try bytes.u32(p) == 0x0201_4B50 else { throw ZipError.corrupt }
            let method = try bytes.u16(p + 10)
            var compressed = Int(try bytes.u32(p + 20))
            var size = Int(try bytes.u32(p + 24))
            let nameLength = Int(try bytes.u16(p + 28))
            let extraLength = Int(try bytes.u16(p + 30))
            let commentLength = Int(try bytes.u16(p + 32))
            var local = Int(try bytes.u32(p + 42))
            let name = String(decoding: try bytes.slice(p + 46, nameLength), as: UTF8.self)

            // Zip64 extra field: only the saturated values are present, in order.
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let tag = try bytes.u16(e)
                let length = Int(try bytes.u16(e + 2))
                if tag == 0x0001 {
                    var f = e + 4
                    if size == 0xFFFF_FFFF { size = Int(try bytes.u64(f)); f += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = Int(try bytes.u64(f)); f += 8 }
                    if local == 0xFFFF_FFFF { local = Int(try bytes.u64(f)) }
                }
                e += 4 + length
            }

            if !name.hasSuffix("/") {
                entries[name] = Entry(
                    method: method, compressedSize: compressed, size: size, localOffset: local
                )
            }
            p = extraEnd + commentLength
        }
        self.data = data
        self.entries = entries
    }

    func read(_ path: String) throws -> Data? {
        guard let entry = entries[path] else { return nil }
        let bytes = Bytes(data: data)
        let p = entry.localOffset
        guard try bytes.u32(p) == 0x0403_4B50 else { throw ZipError.corrupt }
        let start = p + 30 + Int(try bytes.u16(p + 26)) + Int(try bytes.u16(p + 28))
        let payload = try bytes.slice(start, entry.compressedSize)
        switch entry.method {
        case 0:
            return Data(payload)
        case 8:
            return try Self.inflate(payload, size: entry.size)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    /// Raw DEFLATE (RFC 1951) — what `COMPRESSION_ZLIB` decodes.
    static func inflate(_ input: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, size,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw ZipError.corrupt }
        return output
    }

    private static func findEndOfCentralDirectory(_ bytes: Bytes) -> Int? {
        let last = bytes.count - 22
        guard last >= 0 else { return nil }
        // The record is followed by a comment of at most 65535 bytes.
        for p in stride(from: last, through: max(0, last - 65_535), by: -1) {
            if (try? bytes.u32(p)) == 0x0605_4B50 { return p }
        }
        return nil
    }

    /// Bounds-checked little-endian reads at offsets from the start of `data`.
    private struct Bytes {
        let data: Data
        var count: Int { data.count }

        func slice(_ offset: Int, _ length: Int) throws -> Data {
            guard offset >= 0, length >= 0, offset + length <= data.count else {
                throw ZipError.corrupt
            }
            let start = data.startIndex + offset
            return data[start..<start + length]
        }

        func u16(_ offset: Int) throws -> UInt16 {
            UInt16(truncatingIfNeeded: try uint(offset, 2))
        }

        func u32(_ offset: Int) throws -> UInt32 {
            UInt32(truncatingIfNeeded: try uint(offset, 4))
        }

        func u64(_ offset: Int) throws -> UInt64 {
            try uint(offset, 8)
        }

        private func uint(_ offset: Int, _ width: Int) throws -> UInt64 {
            guard offset >= 0, offset + width <= data.count else { throw ZipError.corrupt }
            var value: UInt64 = 0
            let start = data.startIndex + offset
            for i in 0..<width {
                value |= UInt64(data[start + i]) << (8 * UInt64(i))
            }
            return value
        }
    }
}

/// An export the user unzipped themselves.
struct FolderFiles: ExportFiles {
    let root: URL
    let paths: [String]

    init(root: URL) {
        self.root = root
        let base = root.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var paths: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            paths.append(String(path.dropFirst(base.count + 1)))
        }
        self.paths = paths
    }

    func read(_ path: String) throws -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(path))
    }
}
