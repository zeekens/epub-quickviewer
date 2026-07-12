import Foundation
import Compression

/// Read access to an EPUB's files, whether zipped or exploded on disk.
protocol EPUBContainer {
    func read(_ name: String) -> Data?
    func contains(_ name: String) -> Bool
}

/// Directory-format EPUB (e.g. Apple Books stores them unzipped).
struct DirectoryContainer: EPUBContainer {
    let root: URL

    func read(_ name: String) -> Data? {
        guard let url = resolvedURL(name) else { return nil }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > ZipArchive.maxEntrySize {
            return nil
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    func contains(_ name: String) -> Bool {
        guard let url = resolvedURL(name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Refuse paths that escape the book directory (e.g. "../../…" from a
    /// crafted container.xml).
    private func resolvedURL(_ name: String) -> URL? {
        let url = root.appendingPathComponent(name).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else { return nil }
        return url
    }
}

/// Minimal read-only ZIP archive parser, sufficient for EPUB files.
/// Supports stored (0) and deflate (8) entries; no zip64, no encryption.
final class ZipArchive: EPUBContainer {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]

    init?(url: URL) {
        guard let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        data = mapped
        guard parseCentralDirectory() else { return nil }
    }

    var entryNames: [String] { Array(entries.keys) }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    /// Ceiling on a single entry's decompressed size — stops zip bombs from
    /// exhausting memory (no legitimate EPUB resource approaches this).
    static let maxEntrySize = 128 << 20  // 128 MiB

    /// Extract an entry's decompressed contents.
    func read(_ name: String) -> Data? {
        guard let entry = entries[name],
              entry.uncompressedSize <= Self.maxEntrySize else { return nil }

        // Local file header: 30 fixed bytes; name/extra lengths may differ
        // from the central directory copy, so re-read them here.
        let lho = entry.localHeaderOffset
        guard lho + 30 <= data.count, le32(at: lho) == 0x04034b50 else { return nil }
        let nameLen = Int(le16(at: lho + 26))
        let extraLen = Int(le16(at: lho + 28))
        let payloadStart = lho + 30 + nameLen + extraLen
        guard payloadStart + entry.compressedSize <= data.count else { return nil }
        let payload = data.subdata(in: payloadStart ..< payloadStart + entry.compressedSize)

        switch entry.method {
        case 0: // stored
            return payload
        case 8: // deflate (raw — Compression's COMPRESSION_ZLIB is headerless deflate)
            return inflate(payload, expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    // MARK: - Central directory

    private func parseCentralDirectory() -> Bool {
        // Locate End Of Central Directory record: scan backwards over the
        // maximum comment length (64 KiB) for the PK\x05\x06 signature.
        let minEOCD = 22
        guard data.count >= minEOCD else { return false }
        let scanStart = max(0, data.count - minEOCD - 0xFFFF)
        var eocd = -1
        var pos = data.count - minEOCD
        while pos >= scanStart {
            if le32(at: pos) == 0x06054b50 { eocd = pos; break }
            pos -= 1
        }
        guard eocd >= 0 else { return false }

        let entryCount = Int(le16(at: eocd + 10))
        let cdOffset = Int(le32(at: eocd + 16))
        guard cdOffset != 0xFFFFFFFF else { return false } // zip64 unsupported

        var cursor = cdOffset
        for _ in 0 ..< entryCount {
            guard cursor + 46 <= data.count, le32(at: cursor) == 0x02014b50 else { return false }
            let method = le16(at: cursor + 10)
            let compressed = Int(le32(at: cursor + 20))
            let uncompressed = Int(le32(at: cursor + 24))
            let nameLen = Int(le16(at: cursor + 28))
            let extraLen = Int(le16(at: cursor + 30))
            let commentLen = Int(le16(at: cursor + 32))
            let lho = Int(le32(at: cursor + 42))
            guard cursor + 46 + nameLen <= data.count else { return false }
            let nameData = data.subdata(in: cursor + 46 ..< cursor + 46 + nameLen)
            if compressed != 0xFFFFFFFF, uncompressed != 0xFFFFFFFF, lho != 0xFFFFFFFF,
               let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) {
                entries[name] = Entry(name: name, method: method,
                                      compressedSize: compressed,
                                      uncompressedSize: uncompressed,
                                      localHeaderOffset: lho)
            }
            cursor += 46 + nameLen + extraLen + commentLen
        }
        return !entries.isEmpty
    }

    // MARK: - Byte helpers (bytewise reads: Data may not be aligned)

    private func le16(at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset])
            | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private func le32(at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for i in 0 ..< 4 {
            value |= UInt32(data[data.startIndex + offset + i]) << (8 * i)
        }
        return value
    }

    private func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { outPtr -> Int in
            input.withUnsafeBytes { inPtr -> Int in
                guard let outBase = outPtr.bindMemory(to: UInt8.self).baseAddress,
                      let inBase = inPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(outBase, expectedSize,
                                                 inBase, input.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { return nil }
        return output
    }
}
