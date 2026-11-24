import Compression
import Foundation

/// Minimal, dependency-free ZIP reader (stored + deflate, ZIP64 aware).
///
/// 3MF files are OPC/ZIP packages. The Quick Look extension runs in an App Sandbox where
/// spawning `/usr/bin/unzip` is not permitted, so archives are decoded fully in-process.
public struct ZipArchive {
    public struct Entry {
        public let path: String
        public let method: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int
    }

    public enum ZipError: LocalizedError {
        case notAZip
        case corrupt(String)
        case unsupportedMethod(UInt16)
        case decompressionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notAZip: return "File is not a ZIP/3MF package"
            case .corrupt(let s): return "Corrupt ZIP archive: \(s)"
            case .unsupportedMethod(let m): return "Unsupported ZIP compression method \(m)"
            case .decompressionFailed(let s): return "Failed to decompress \(s)"
            }
        }
    }

    public let data: Data
    public let entries: [Entry]

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        self.data = data
        self.entries = try ZipArchive.readCentralDirectory(data)
    }

    public func entry(named path: String) -> Entry? {
        let wanted = ZipArchive.normalize(path).lowercased()
        return entries.first { ZipArchive.normalize($0.path).lowercased() == wanted }
    }

    public static func normalize(_ path: String) -> String {
        var s = path.replacingOccurrences(of: "\\", with: "/")
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }

    // MARK: - Extraction

    public func extract(_ entry: Entry) throws -> Data {
        let off = entry.localHeaderOffset
        guard off >= 0, off + 30 <= data.count, data.u32(off) == 0x0403_4B50 else {
            throw ZipError.corrupt("bad local header for \(entry.path)")
        }
        let nameLen = Int(data.u16(off + 26))
        let extraLen = Int(data.u16(off + 28))
        let start = off + 30 + nameLen + extraLen
        guard start >= 0, entry.compressedSize >= 0, start + entry.compressedSize <= data.count else {
            throw ZipError.corrupt("entry \(entry.path) exceeds archive bounds")
        }

        switch entry.method {
        case 0:
            return data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        case 8:
            return try inflate(start: start, compressedSize: entry.compressedSize,
                               uncompressedSize: entry.uncompressedSize, name: entry.path)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    private func inflate(start: Int, compressedSize: Int, uncompressedSize: Int, name: String) throws -> Data {
        if uncompressedSize == 0 { return Data() }
        // Guard against absurd sizes from a hostile/corrupt header (2 GiB cap per entry).
        guard uncompressedSize > 0, uncompressedSize < (1 << 31) else {
            throw ZipError.corrupt("implausible size for \(name)")
        }
        var output = Data(count: uncompressedSize)
        let written: Int = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return 0 }
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951) — exactly what ZIP method 8 stores.
                return compression_decode_buffer(
                    dstBase.assumingMemoryBound(to: UInt8.self), uncompressedSize,
                    srcBase.advanced(by: start).assumingMemoryBound(to: UInt8.self), compressedSize,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == uncompressedSize else {
            throw ZipError.decompressionFailed("\(name) (got \(written) of \(uncompressedSize) bytes)")
        }
        return output
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        let n = data.count
        guard n >= 22 else { throw ZipError.notAZip }

        // Locate End Of Central Directory record (scan back over up to 64 KiB comment).
        var eocd = -1
        var p = n - 22
        let lowest = max(0, n - 22 - 0xFFFF)
        while p >= lowest {
            if data.u32(p) == 0x0605_4B50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        var count = Int(data.u16(eocd + 10))
        var cdSize = Int(data.u32(eocd + 12))
        var cdOffset = Int(data.u32(eocd + 16))

        // ZIP64 EOCD locator sits immediately before the EOCD.
        if (count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF),
           eocd >= 20, data.u32(eocd - 20) == 0x0706_4B50 {
            let z64 = Int(data.u64(eocd - 20 + 8))
            if z64 >= 0, z64 + 56 <= n, data.u32(z64) == 0x0606_4B50 {
                count = Int(data.u64(z64 + 32))
                cdSize = Int(data.u64(z64 + 40))
                cdOffset = Int(data.u64(z64 + 48))
            }
        }

        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= n else {
            throw ZipError.corrupt("central directory out of bounds")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(min(count, 4096))
        var q = cdOffset
        let cdEnd = cdOffset + cdSize
        while q + 46 <= cdEnd, data.u32(q) == 0x0201_4B50 {
            let method = data.u16(q + 10)
            var csize = Int(data.u32(q + 20))
            var usize = Int(data.u32(q + 24))
            let nameLen = Int(data.u16(q + 28))
            let extraLen = Int(data.u16(q + 30))
            let commentLen = Int(data.u16(q + 32))
            var lho = Int(data.u32(q + 42))
            let nameStart = q + 46
            guard nameStart + nameLen + extraLen <= n else { throw ZipError.corrupt("truncated entry") }

            let name = String(decoding: data[(data.startIndex + nameStart)..<(data.startIndex + nameStart + nameLen)], as: UTF8.self)

            // ZIP64 extended information extra field (0x0001).
            var e = nameStart + nameLen
            let eEnd = e + extraLen
            while e + 4 <= eEnd {
                let id = data.u16(e)
                let sz = Int(data.u16(e + 2))
                if id == 0x0001 {
                    var f = e + 4
                    if usize == 0xFFFF_FFFF, f + 8 <= e + 4 + sz { usize = Int(data.u64(f)); f += 8 }
                    if csize == 0xFFFF_FFFF, f + 8 <= e + 4 + sz { csize = Int(data.u64(f)); f += 8 }
                    if lho == 0xFFFF_FFFF, f + 8 <= e + 4 + sz { lho = Int(data.u64(f)); f += 8 }
                }
                e += 4 + sz
            }

            if !name.hasSuffix("/") {
                entries.append(Entry(path: name, method: method, compressedSize: csize,
                                     uncompressedSize: usize, localHeaderOffset: lho))
            }
            q = nameStart + nameLen + extraLen + commentLen
        }

        guard !entries.isEmpty else { throw ZipError.corrupt("no entries") }
        return entries
    }
}

private extension Data {
    @inline(__always) func u16(_ o: Int) -> UInt16 {
        let i = startIndex + o
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    @inline(__always) func u32(_ o: Int) -> UInt32 {
        let i = startIndex + o
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    @inline(__always) func u64(_ o: Int) -> UInt64 {
        UInt64(u32(o)) | UInt64(u32(o + 4)) << 32
    }
}
