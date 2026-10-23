//
//  ZipDelta.swift
//  Builds a small signed IPA without recompressing the whole app.
//
//  Signing rewrites only a few files (main binary, Info.plist, embedded profile,
//  _CodeSignature) — everything else is byte-identical to the original IPA. The
//  signer writes the result uncompressed (~2× the size), so instead we copy the
//  original's already-compressed bytes for every unchanged file and deflate only
//  the files that changed. The device upload is the slow part, so the smaller
//  file is what matters.
//
//  Matching is by name + CRC32 + size from the zip directories, so nothing is
//  decompressed or hashed. Any problem throws and the caller falls back.
//

import Compression
import Foundation

nonisolated enum ZipDelta {
    struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    struct Entry {
        var nameData: Data
        var name: String
        var versionMade: UInt16
        var flags: UInt16
        var method: UInt16
        var time: UInt16
        var date: UInt16
        var crc: UInt32
        var comp: UInt32
        var uncomp: UInt32
        var intAttr: UInt16
        var extAttr: UInt32
        var offset: UInt32
    }

    /// Bytes that can be uploaded before signing finishes: original files that signing never touches.
    struct Prefix {
        struct Rec { var entry: Entry; var offset: UInt32 }
        var url: URL
        var length: UInt64
        var recs: [String: Rec]
    }

    /// Files signing leaves alone: not Mach-O (no extension / dylib), not plists, not the signature, not the icon.
    private static func isStable(_ e: Entry) -> Bool {
        guard !e.name.hasSuffix("/"), e.uncomp >= 256, e.flags & 0x1 == 0, e.method == 0 || e.method == 8 else { return false }
        let file = (e.name as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension.lowercased()
        if ext.isEmpty || ["dylib", "so", "plist", "mobileprovision", "a", "o"].contains(ext) { return false }
        if e.name.contains("_CodeSignature/") || file == "CodeResources" || e.name.contains("AppIcon") { return false }
        return true
    }

    /// Writes the compressed bytes of every stable original file to `out` (zip local entries, no directory).
    static func stage(original: URL, to out: URL) throws -> Prefix {
        let list = try entries(of: original)
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        fm.createFile(atPath: out.path, contents: nil)
        let input = try FileHandle(forReadingFrom: original)
        let output = try FileHandle(forWritingTo: out)
        defer { try? input.close(); try? output.close() }
        var pos: UInt64 = 0
        var recs: [String: Prefix.Rec] = [:]
        for e in list where isStable(e) {
            guard pos < 3_000_000_000 else { break }
            let start = pos
            let dataStart = try dataOffset(of: e, in: input)
            try write(localHeader(name: e.nameData, flags: e.flags & 0x0800, method: e.method, time: e.time, date: e.date,
                                  crc: e.crc, comp: e.comp, uncomp: e.uncomp), to: output, pos: &pos)
            try copy(from: input, offset: dataStart, length: UInt64(e.comp), to: output, pos: &pos)
            recs[e.name] = Prefix.Rec(entry: e, offset: UInt32(start))
        }
        guard !recs.isEmpty else { throw Failure("Nothing to stage.") }
        return Prefix(url: out, length: pos, recs: recs)
    }

    /// Writes `out`: the signed IPA's files, with unchanged files copied compressed from `original`.
    /// Returns the number of bytes that were copied through without recompression.
    @discardableResult
    static func repack(signed: URL, original: URL, to out: URL, prefix: Prefix? = nil) throws -> Int64 {
        let signedEntries = try entries(of: signed)
        let originalEntries = try entries(of: original)
        guard signedEntries.count < 65_535 else { throw Failure("Too many files for the simple zip writer.") }
        var originalByName: [String: Entry] = [:]
        for e in originalEntries { originalByName[e.name] = e }

        let fm = FileManager.default
        try? fm.removeItem(at: out)
        fm.createFile(atPath: out.path, contents: nil)
        let signedIn = try FileHandle(forReadingFrom: signed)
        let originalIn = try FileHandle(forReadingFrom: original)
        let output = try FileHandle(forWritingTo: out)
        defer { try? signedIn.close(); try? originalIn.close(); try? output.close() }

        var central = Data()
        let base = prefix?.length ?? 0          // with a prefix, `out` holds only the part after it
        var pos: UInt64 = base
        var copied: Int64 = 0
        var usedPrefix = 0

        for e in signedEntries {
            guard pos < 3_500_000_000 else { throw Failure("IPA too large for the simple zip writer.") }
            guard e.method == 0 || e.method == 8 else { throw Failure("Unsupported compression in the signed IPA.") }
            var headerOffset = pos
            let isDir = e.name.hasSuffix("/")
            var method: UInt16 = 0
            var crc = e.crc
            var comp: UInt32 = 0
            let uncomp = e.uncomp
            let utf8Flag = e.flags & 0x0800

            if let rec = prefix?.recs[e.name] {
                // Already uploaded as part of the prefix: it must be exactly what signing produced.
                guard !isDir, rec.entry.crc == e.crc, rec.entry.uncomp == e.uncomp else {
                    throw Failure("Pre-uploaded file changed while signing: \(e.name)")
                }
                headerOffset = UInt64(rec.offset)
                method = rec.entry.method; comp = rec.entry.comp; crc = rec.entry.crc
                copied += Int64(comp); usedPrefix += 1
            } else if e.method == 8 {
                // Compressed by the signer's fast packer: copy those bytes as they are.
                method = 8; comp = e.comp; crc = e.crc
                let dataStart = try dataOffset(of: e, in: signedIn)
                try write(localHeader(name: e.nameData, flags: utf8Flag, method: 8, time: e.time, date: e.date,
                                      crc: crc, comp: comp, uncomp: uncomp), to: output, pos: &pos)
                try copy(from: signedIn, offset: dataStart, length: UInt64(comp), to: output, pos: &pos)
                copied += Int64(comp)
            } else if let o = originalByName[e.name], !isDir, uncomp > 0,
               o.crc == e.crc, o.uncomp == e.uncomp, (o.method == 0 || o.method == 8), o.flags & 0x1 == 0 {
                // Unchanged file: copy the original's compressed bytes as they are.
                method = o.method; comp = o.comp; crc = o.crc
                let dataStart = try dataOffset(of: o, in: originalIn)
                try write(localHeader(name: e.nameData, flags: utf8Flag, method: method, time: e.time, date: e.date,
                                      crc: crc, comp: comp, uncomp: uncomp), to: output, pos: &pos)
                try copy(from: originalIn, offset: dataStart, length: UInt64(comp), to: output, pos: &pos)
                copied += Int64(comp)
            } else if isDir || uncomp == 0 || e.uncomp < 256 {
                // Directories, empty files, tiny files (and symlink targets): store as they are.
                var dataStart: UInt64 = 0
                if !isDir && uncomp > 0 { dataStart = try dataOffset(of: e, in: signedIn) }
                try write(localHeader(name: e.nameData, flags: utf8Flag, method: 0, time: e.time, date: e.date,
                                      crc: crc, comp: uncomp, uncomp: uncomp), to: output, pos: &pos)
                if uncomp > 0 { try copy(from: signedIn, offset: dataStart, length: UInt64(uncomp), to: output, pos: &pos) }
                comp = uncomp
            } else {
                // Changed file: deflate it. Write the header first, then patch the compressed size.
                method = 8
                let dataStart = try dataOffset(of: e, in: signedIn)
                try write(localHeader(name: e.nameData, flags: utf8Flag, method: 8, time: e.time, date: e.date,
                                      crc: crc, comp: 0, uncomp: uncomp), to: output, pos: &pos)
                let written = try deflate(from: signedIn, offset: dataStart, length: UInt64(e.uncomp), to: output)
                pos += written
                guard written < 0xFFFF_FFFF else { throw Failure("Compressed file too large.") }
                comp = UInt32(written)
                try output.seek(toOffset: headerOffset - base + 18)
                try output.write(contentsOf: le32(comp))
                try output.seek(toOffset: pos - base)
            }

            // Central directory record (permissions/attributes come from the signed zip).
            central.append(le32(0x0201_4b50))
            central.append(le16(e.versionMade)); central.append(le16(20))
            central.append(le16(utf8Flag)); central.append(le16(method))
            central.append(le16(e.time)); central.append(le16(e.date))
            central.append(le32(crc)); central.append(le32(comp)); central.append(le32(uncomp))
            central.append(le16(UInt16(e.nameData.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(e.intAttr)); central.append(le32(e.extAttr))
            central.append(le32(UInt32(headerOffset)))
            central.append(e.nameData)
        }

        if let prefix, usedPrefix != prefix.recs.count { throw Failure("Pre-uploaded files were removed while signing.") }
        let cdOffset = pos
        guard cdOffset < 0xFFFF_FFFF else { throw Failure("IPA too large for the simple zip writer.") }
        try output.write(contentsOf: central)
        var eocd = Data()
        eocd.append(le32(0x0605_4b50)); eocd.append(le16(0)); eocd.append(le16(0))
        eocd.append(le16(UInt16(signedEntries.count))); eocd.append(le16(UInt16(signedEntries.count)))
        eocd.append(le32(UInt32(central.count))); eocd.append(le32(UInt32(cdOffset))); eocd.append(le16(0))
        try output.write(contentsOf: eocd)
        return copied
    }

    // MARK: Reading

    static func entries(of url: URL) throws -> [Entry] {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let size = try h.seekToEnd()
        guard size > 22 else { throw Failure("Not a zip file.") }
        let tailLen = min(size, 65_557)
        try h.seek(toOffset: size - tailLen)
        let tail = try h.read(upToCount: Int(tailLen)) ?? Data()
        var eocdAt = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[tail.startIndex + i] == 0x50, tail[tail.startIndex + i + 1] == 0x4b,
               tail[tail.startIndex + i + 2] == 0x05, tail[tail.startIndex + i + 3] == 0x06 { eocdAt = i; break }
            i -= 1
        }
        guard eocdAt >= 0 else { throw Failure("No zip directory found.") }
        let t = tail.subdata(in: (tail.startIndex + eocdAt)..<tail.endIndex)
        let total = Int(u16(t, 10)), cdSize = Int(u32(t, 12)), cdOffset = UInt64(u32(t, 16))
        guard total != 0xFFFF, cdOffset != 0xFFFF_FFFF else { throw Failure("Zip64 isn't supported here.") }
        try h.seek(toOffset: cdOffset)
        let cd = try h.read(upToCount: cdSize) ?? Data()
        guard cd.count == cdSize else { throw Failure("Zip directory is truncated.") }

        var list: [Entry] = []
        var p = 0
        while p + 46 <= cd.count, u32(cd, p) == 0x0201_4b50 {
            let nameLen = Int(u16(cd, p + 28)), extraLen = Int(u16(cd, p + 30)), commentLen = Int(u16(cd, p + 32))
            guard p + 46 + nameLen <= cd.count else { throw Failure("Bad zip directory.") }
            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen))
            let e = Entry(nameData: nameData, name: String(decoding: nameData, as: UTF8.self),
                          versionMade: u16(cd, p + 4), flags: u16(cd, p + 8), method: u16(cd, p + 10),
                          time: u16(cd, p + 12), date: u16(cd, p + 14), crc: u32(cd, p + 16),
                          comp: u32(cd, p + 20), uncomp: u32(cd, p + 24),
                          intAttr: u16(cd, p + 36), extAttr: u32(cd, p + 38), offset: u32(cd, p + 42))
            if e.comp == 0xFFFF_FFFF || e.uncomp == 0xFFFF_FFFF || e.offset == 0xFFFF_FFFF { throw Failure("Zip64 isn't supported here.") }
            list.append(e)
            p += 46 + nameLen + extraLen + commentLen
        }
        guard list.count == total else { throw Failure("Zip directory count mismatch.") }
        return list
    }

    static func dataOffset(of e: Entry, in h: FileHandle) throws -> UInt64 {
        try h.seek(toOffset: UInt64(e.offset))
        let head = try h.read(upToCount: 30) ?? Data()
        guard head.count == 30, u32(head, 0) == 0x0403_4b50 else { throw Failure("Bad local header.") }
        return UInt64(e.offset) + 30 + UInt64(u16(head, 26)) + UInt64(u16(head, 28))
    }

    // MARK: Writing

    static func localHeader(name: Data, flags: UInt16, method: UInt16, time: UInt16, date: UInt16,
                                    crc: UInt32, comp: UInt32, uncomp: UInt32) -> Data {
        var d = Data()
        d.append(le32(0x0403_4b50)); d.append(le16(20)); d.append(le16(flags)); d.append(le16(method))
        d.append(le16(time)); d.append(le16(date)); d.append(le32(crc)); d.append(le32(comp)); d.append(le32(uncomp))
        d.append(le16(UInt16(name.count))); d.append(le16(0)); d.append(name)
        return d
    }

    static func write(_ data: Data, to h: FileHandle, pos: inout UInt64) throws {
        try h.write(contentsOf: data); pos += UInt64(data.count)
    }

    static func copy(from src: FileHandle, offset: UInt64, length: UInt64, to dst: FileHandle, pos: inout UInt64) throws {
        try src.seek(toOffset: offset)
        var remaining = length
        while remaining > 0 {
            let n = Int(min(remaining, 1 << 20))
            let chunk = try autoreleasepool { try src.read(upToCount: n) ?? Data() }
            guard chunk.count == n else { throw Failure("Unexpected end of file while copying.") }
            try dst.write(contentsOf: chunk)
            pos += UInt64(n); remaining -= UInt64(n)
        }
    }

    /// Raw DEFLATE (what zip entries use) of `length` bytes at `offset`, appended to `dst`. Returns bytes written.
    static func deflate(from src: FileHandle, offset: UInt64, length: UInt64, to dst: FileHandle) throws -> UInt64 {
        try src.seek(toOffset: offset)
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure("Compression isn't available.")
        }
        defer { compression_stream_destroy(&stream) }

        let outCap = 1 << 20
        var outBuf = [UInt8](repeating: 0, count: outCap)
        var remaining = length
        var written: UInt64 = 0

        while remaining > 0 {
            let n = Int(min(remaining, 1 << 20))
            let chunk = try src.read(upToCount: n) ?? Data()
            guard chunk.count == n else { throw Failure("Unexpected end of file while compressing.") }
            remaining -= UInt64(n)
            let final = remaining == 0
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
                stream.src_size = n
                while true {
                    var status = COMPRESSION_STATUS_OK
                    try outBuf.withUnsafeMutableBufferPointer { buf in
                        stream.dst_ptr = buf.baseAddress!
                        stream.dst_size = outCap
                        status = compression_stream_process(&stream, final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                        guard status != COMPRESSION_STATUS_ERROR else { throw Failure("Compression failed.") }
                        let produced = outCap - stream.dst_size
                        if produced > 0 {
                            try dst.write(contentsOf: Data(bytes: buf.baseAddress!, count: produced))
                            written += UInt64(produced)
                        }
                    }
                    if status == COMPRESSION_STATUS_END { break }
                    if !final && stream.src_size == 0 && stream.dst_size != 0 { break }
                }
            }
        }
        return written
    }

    // MARK: Little-endian helpers

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
    static func u16(_ d: Data, _ o: Int) -> UInt16 {
        let s = d.startIndex + o
        return UInt16(d[s]) | UInt16(d[s + 1]) << 8
    }
    static func u32(_ d: Data, _ o: Int) -> UInt32 {
        let s = d.startIndex + o
        return UInt32(d[s]) | UInt32(d[s + 1]) << 8 | UInt32(d[s + 2]) << 16 | UInt32(d[s + 3]) << 24
    }
}
