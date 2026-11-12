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
        var offset: UInt64          // 64-bit: archives past 4 GB use the zip64 extra field
    }

    /// Bytes that can be uploaded before signing finishes: original files that signing never touches.
    struct Prefix {
        struct Rec { var entry: Entry; var offset: UInt64 }
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
            recs[e.name] = Prefix.Rec(entry: e, offset: start)
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
                headerOffset = rec.offset
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
            appendCentralRecord(&central, versionMade: e.versionMade, flags: utf8Flag, method: method, time: e.time, date: e.date,
                                crc: crc, comp: comp, uncomp: uncomp, name: e.nameData, intAttr: e.intAttr, extAttr: e.extAttr,
                                headerOffset: headerOffset)
        }

        if let prefix, usedPrefix != prefix.recs.count { throw Failure("Pre-uploaded files were removed while signing.") }
        let cdOffset = pos
        try output.write(contentsOf: central)
        try output.write(contentsOf: endOfCentralDirectory(count: signedEntries.count, cdSize: UInt64(central.count), cdOffset: cdOffset))
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
        var total = Int(u16(t, 10)), cdSize = Int(u32(t, 12)), cdOffset = UInt64(u32(t, 16))
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // zip64: the locator sits right before the EOCD and points at the zip64 end record.
            guard eocdAt >= 20, tail[tail.startIndex + eocdAt - 20] == 0x50, tail[tail.startIndex + eocdAt - 19] == 0x4b,
                  tail[tail.startIndex + eocdAt - 18] == 0x06, tail[tail.startIndex + eocdAt - 17] == 0x07 else {
                throw Failure("Zip64 locator not found.")
            }
            let loc = tail.subdata(in: (tail.startIndex + eocdAt - 20)..<(tail.startIndex + eocdAt))
            try h.seek(toOffset: u64(loc, 8))
            let rec = try h.read(upToCount: 56) ?? Data()
            guard rec.count == 56, u32(rec, 0) == 0x0606_4b50 else { throw Failure("Bad zip64 directory.") }
            total = Int(u64(rec, 32)); cdSize = Int(u64(rec, 40)); cdOffset = u64(rec, 48)
        }
        try h.seek(toOffset: cdOffset)
        let cd = try h.read(upToCount: cdSize) ?? Data()
        guard cd.count == cdSize else { throw Failure("Zip directory is truncated.") }

        var list: [Entry] = []
        var p = 0
        while p + 46 <= cd.count, u32(cd, p) == 0x0201_4b50 {
            let nameLen = Int(u16(cd, p + 28)), extraLen = Int(u16(cd, p + 30)), commentLen = Int(u16(cd, p + 32))
            guard p + 46 + nameLen <= cd.count else { throw Failure("Bad zip directory.") }
            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen))
            var offset64 = UInt64(u32(cd, p + 42))
            if offset64 == 0xFFFF_FFFF {
                // Only the offset is zip64 here (sizes are checked below): it is the first value in the 0x0001 extra field.
                var q = p + 46 + nameLen; let extraEnd = q + extraLen
                var found = false
                while q + 4 <= extraEnd, q + 4 <= cd.count {
                    let id = u16(cd, q), len = Int(u16(cd, q + 2))
                    if id == 0x0001, len >= 8, q + 4 + 8 <= cd.count { offset64 = u64(cd, q + 4); found = true; break }
                    q += 4 + len
                }
                guard found else { throw Failure("Zip64 offset missing.") }
            }
            let e = Entry(nameData: nameData, name: String(decoding: nameData, as: UTF8.self),
                          versionMade: u16(cd, p + 4), flags: u16(cd, p + 8), method: u16(cd, p + 10),
                          time: u16(cd, p + 12), date: u16(cd, p + 14), crc: u32(cd, p + 16),
                          comp: u32(cd, p + 20), uncomp: u32(cd, p + 24),
                          intAttr: u16(cd, p + 36), extAttr: u32(cd, p + 38), offset: offset64)
            if e.comp == 0xFFFF_FFFF || e.uncomp == 0xFFFF_FFFF { throw Failure("A single file over 4 GB isn't supported by the fast path.") }
            list.append(e)
            p += 46 + nameLen + extraLen + commentLen
        }
        guard list.count == total else { throw Failure("Zip directory count mismatch.") }
        return list
    }

    static func dataOffset(of e: Entry, in h: FileHandle) throws -> UInt64 {
        try h.seek(toOffset: e.offset)
        let head = try h.read(upToCount: 30) ?? Data()
        guard head.count == 30, u32(head, 0) == 0x0403_4b50 else { throw Failure("Bad local header.") }
        return e.offset + 30 + UInt64(u16(head, 26)) + UInt64(u16(head, 28))
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

    // MARK: Central directory (zip64-aware)

    /// One central-directory record. Offsets past 4 GB go in a zip64 extra field.
    static func appendCentralRecord(_ c: inout Data, versionMade: UInt16, flags: UInt16, method: UInt16, time: UInt16, date: UInt16,
                                    crc: UInt32, comp: UInt32, uncomp: UInt32, name: Data, intAttr: UInt16, extAttr: UInt32,
                                    headerOffset: UInt64) {
        let big = headerOffset >= 0xFFFF_FFFF
        c.append(le32(0x0201_4b50))
        c.append(le16(versionMade)); c.append(le16(big ? 45 : 20))
        c.append(le16(flags)); c.append(le16(method))
        c.append(le16(time)); c.append(le16(date))
        c.append(le32(crc)); c.append(le32(comp)); c.append(le32(uncomp))
        c.append(le16(UInt16(name.count))); c.append(le16(big ? 12 : 0)); c.append(le16(0))
        c.append(le16(0)); c.append(le16(intAttr)); c.append(le32(extAttr))
        c.append(le32(big ? 0xFFFF_FFFF : UInt32(headerOffset)))
        c.append(name)
        if big { c.append(le16(0x0001)); c.append(le16(8)); c.append(le64(headerOffset)) }
    }

    /// End of central directory, preceded by the zip64 record + locator when the archive needs them
    /// (more than 65,534 entries, or a directory at/after 4 GB).
    static func endOfCentralDirectory(count: Int, cdSize: UInt64, cdOffset: UInt64) -> Data {
        var d = Data()
        let zip64 = count >= 0xFFFF || cdOffset >= 0xFFFF_FFFF || cdSize >= 0xFFFF_FFFF
        if zip64 {
            d.append(le32(0x0606_4b50)); d.append(le64(44)); d.append(le16(45)); d.append(le16(45))
            d.append(le32(0)); d.append(le32(0)); d.append(le64(UInt64(count))); d.append(le64(UInt64(count)))
            d.append(le64(cdSize)); d.append(le64(cdOffset))
            d.append(le32(0x0706_4b50)); d.append(le32(0)); d.append(le64(cdOffset + cdSize)); d.append(le32(1))
        }
        d.append(le32(0x0605_4b50)); d.append(le16(0)); d.append(le16(0))
        d.append(le16(zip64 ? 0xFFFF : UInt16(count))); d.append(le16(zip64 ? 0xFFFF : UInt16(count)))
        d.append(le32(zip64 ? 0xFFFF_FFFF : UInt32(cdSize))); d.append(le32(zip64 ? 0xFFFF_FFFF : UInt32(cdOffset))); d.append(le16(0))
        return d
    }

    // MARK: Little-endian helpers

    static func le64(_ v: UInt64) -> Data { le32(UInt32(v & 0xFFFF_FFFF)) + le32(UInt32(v >> 32)) }
    static func u64(_ d: Data, _ o: Int) -> UInt64 { UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32 }

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
