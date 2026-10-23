//
//  ZipFast.swift
//  Faster IPA unpack / repack for signing.
//
//  * extract: inflates files in parallel straight from the zip's directory, stamps every file with a
//    marker modification time, and never re-reads anything.
//  * packDelta: after signing, any file whose modification time is still the marker (and whose size
//    matches the original entry) is unchanged, so its already-compressed bytes are copied from the
//    original IPA. Only files the signer touched are read and deflated.
//
//  Any problem throws; callers fall back to the slow ZIPFoundation path.
//

import Compression
import Darwin
import Foundation

nonisolated enum ZipFast {
    typealias Failure = ZipDelta.Failure

    /// Every extracted file gets this modification time. A file with a different one was written by the signer.
    static let marker = Date(timeIntervalSince1970: 946_684_800)   // 2000-01-01

    // MARK: Switch + crash guard

    static let enabledKey = "AirShare.fastSigner"
    static let trippedKey = "AirShare.fastSignerTripped"
    private static let canaryKey = "AirShare.fastSignerCanary"

    /// True when the fast path should run. Off by default. If the previous fast run never finished
    /// (the app was killed mid-way), it switches itself off and records that so Settings can say why.
    static func begin() -> Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: canaryKey) {
            d.set(false, forKey: enabledKey); d.set(true, forKey: trippedKey); d.set(false, forKey: canaryKey)
        }
        guard d.bool(forKey: enabledKey) else { d.synchronize(); return false }
        d.set(true, forKey: canaryKey); d.synchronize()
        return true
    }

    static func end() {
        UserDefaults.standard.set(false, forKey: canaryKey)
        UserDefaults.standard.synchronize()
    }

    // MARK: Extract

    static func extract(ipa: URL, to dir: URL) throws {
        let list = try ZipDelta.entries(of: ipa)
        let fm = FileManager.default
        let rootPath = dir.standardizedFileURL.path
        var files: [ZipDelta.Entry] = []
        var parents = Set<String>()

        func destination(_ name: String) throws -> String {
            guard !name.hasPrefix("/"), !name.contains("../"), !name.hasPrefix("..") else { throw Failure("Unsafe path in IPA: \(name)") }
            return rootPath + "/" + name
        }
        for e in list {
            let path = try destination(e.name)
            if e.name.hasSuffix("/") { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
            else { files.append(e); parents.insert((path as NSString).deletingLastPathComponent) }
        }
        for p in parents { try fm.createDirectory(atPath: p, withIntermediateDirectories: true) }

        // Biggest files first so the workers finish together.
        files.sort { $0.uncomp > $1.uncomp }
        let workers = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount))
        let lock = NSLock()
        var next = 0
        var firstError: Error?

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            guard let handle = try? FileHandle(forReadingFrom: ipa) else {
                lock.lock(); if firstError == nil { firstError = Failure("Could not open the IPA.") }; lock.unlock(); return
            }
            defer { try? handle.close() }
            while true {
                lock.lock()
                let i = next; next += 1
                let failed = firstError != nil
                lock.unlock()
                if failed || i >= files.count { return }
                do { try extractOne(files[i], from: handle, path: try destination(files[i].name)) }
                catch { lock.lock(); if firstError == nil { firstError = error }; lock.unlock(); return }
            }
        }
        if let firstError { throw firstError }
    }

    /// Uncompressed bytes of one small entry (Info.plist, an icon…) without unpacking anything else.
    static func read(_ e: ZipDelta.Entry, from h: FileHandle, limit: UInt32 = 8_000_000) throws -> Data {
        guard e.uncomp <= limit, e.flags & 0x1 == 0, e.method == 0 || e.method == 8 else { throw Failure("Can't read \(e.name)") }
        var out = Data()
        let start = try ZipDelta.dataOffset(of: e, in: h)
        try readEntry(e, from: h, dataStart: start) { out.append($0) }
        return out
    }

    private static func extractOne(_ e: ZipDelta.Entry, from h: FileHandle, path: String) throws {
        guard e.flags & 0x1 == 0, e.method == 0 || e.method == 8 else { throw Failure("Unsupported zip entry: \(e.name)") }
        let mode = (e.extAttr >> 16) & 0xFFFF
        let isSymlink = (mode & 0xF000) == 0xA000
        let dataStart = try ZipDelta.dataOffset(of: e, in: h)

        if isSymlink {
            var target = Data()
            try readEntry(e, from: h, dataStart: dataStart) { target.append($0) }
            guard let s = String(data: target, encoding: .utf8) else { throw Failure("Bad symlink: \(e.name)") }
            unlink(path)
            guard symlink(s, path) == 0 else { throw Failure("Could not create symlink \(e.name)") }
            return
        }

        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw Failure("Could not create \(e.name)") }
        var closed = false
        defer { if !closed { close(fd) } }
        try readEntry(e, from: h, dataStart: dataStart) { chunk in
            try chunk.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    guard n > 0 else { throw Failure("Write failed for \(e.name)") }
                    off += n
                }
            }
        }
        let perms = mode_t(mode & 0o7777)
        fchmod(fd, perms == 0 ? 0o644 : perms)
        var times = [timeval(tv_sec: Int(marker.timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(marker.timeIntervalSince1970), tv_usec: 0)]
        futimes(fd, &times)
        closed = true
        guard close(fd) == 0 else { throw Failure("Close failed for \(e.name)") }
    }

    /// Streams an entry's uncompressed bytes (stored or inflated) to `sink`.
    private static func readEntry(_ e: ZipDelta.Entry, from h: FileHandle, dataStart: UInt64, sink: (Data) throws -> Void) throws {
        try h.seek(toOffset: dataStart)
        var remaining = UInt64(e.comp)
        if e.method == 0 {
            while remaining > 0 {
                let n = Int(min(remaining, 1 << 20))
                let chunk = try autoreleasepool { try h.read(upToCount: n) ?? Data() }
                guard chunk.count == n else { throw Failure("Unexpected end of file.") }
                try sink(chunk); remaining -= UInt64(n)
            }
            return
        }
        guard remaining > 0 else { return }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure("Decompression isn't available.")
        }
        defer { compression_stream_destroy(&stream) }
        let outCap = 1 << 20
        var outBuf = [UInt8](repeating: 0, count: outCap)
        var ended = false
        while remaining > 0, !ended {
            let n = Int(min(remaining, 1 << 20))
            let chunk = try autoreleasepool { try h.read(upToCount: n) ?? Data() }
            guard chunk.count == n else { throw Failure("Unexpected end of file.") }
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
                        guard status != COMPRESSION_STATUS_ERROR else { throw Failure("Decompression failed for \(e.name).") }
                        let produced = outCap - stream.dst_size
                        if produced > 0 { try sink(Data(bytes: buf.baseAddress!, count: produced)) }
                    }
                    if status == COMPRESSION_STATUS_END { ended = true; break }
                    if stream.src_size == 0 && stream.dst_size != 0 { break }
                }
            }
        }
    }

    // MARK: Pack

    /// Writes `out` from the extracted+signed tree under `root` (which holds `Payload/`).
    static func packDelta(root: URL, original: URL, to out: URL) throws {
        let originalEntries = try ZipDelta.entries(of: original)
        var byName: [String: ZipDelta.Entry] = [:]
        for e in originalEntries { byName[e.name] = e }

        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        guard let walker = fm.enumerator(atPath: rootPath + "/Payload") else { throw Failure("Nothing to pack.") }
        var rel: [String] = ["Payload"]
        for case let p as String in walker { rel.append("Payload/" + p) }
        guard rel.count < 65_000 else { throw Failure("Too many files for the simple zip writer.") }

        try? fm.removeItem(at: out)
        fm.createFile(atPath: out.path, contents: nil)
        let originalIn = try FileHandle(forReadingFrom: original)
        let output = try FileHandle(forWritingTo: out)
        defer { try? originalIn.close(); try? output.close() }

        var central = Data()
        var pos: UInt64 = 0
        let (nowDate, nowTime) = dos(Date())

        for name in rel {
            guard pos < 3_500_000_000 else { throw Failure("IPA too large for the simple zip writer.") }
            let path = rootPath + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else { throw Failure("Could not read \(name)") }
            let fmt = st.st_mode & S_IFMT
            let isDir = fmt == S_IFDIR, isLink = fmt == S_IFLNK
            guard isDir || isLink || fmt == S_IFREG else { continue }
            let zipName = isDir ? name + "/" : name
            let nameData = Data(zipName.utf8)
            let headerOffset = pos
            var method: UInt16 = 0, crc: UInt32 = 0, comp: UInt32 = 0, uncomp: UInt32 = 0
            var time = nowTime, date = nowDate
            var extAttr = UInt32(st.st_mode) << 16

            if isDir {
                extAttr |= 0x10
                try ZipDelta.write(ZipDelta.localHeader(name: nameData, flags: 0x0800, method: 0, time: time, date: date, crc: 0, comp: 0, uncomp: 0),
                                   to: output, pos: &pos)
            } else if isLink {
                let target = try fm.destinationOfSymbolicLink(atPath: path)
                let bytes = Data(target.utf8)
                crc = crc32(bytes); uncomp = UInt32(bytes.count); comp = uncomp
                try ZipDelta.write(ZipDelta.localHeader(name: nameData, flags: 0x0800, method: 0, time: time, date: date, crc: crc, comp: comp, uncomp: uncomp),
                                   to: output, pos: &pos)
                try ZipDelta.write(bytes, to: output, pos: &pos)
            } else {
                guard st.st_size < 0xFFFF_FFFF else { throw Failure("File too large for the simple zip writer.") }
                let size = UInt64(st.st_size)
                let mtime = Int(st.st_mtimespec.tv_sec)
                if let o = byName[zipName], size > 0, o.uncomp == UInt32(size), abs(mtime - Int(marker.timeIntervalSince1970)) <= 1,
                   o.method == 0 || o.method == 8, o.flags & 0x1 == 0 {
                    // Untouched since extraction: copy the original's compressed bytes as they are.
                    method = o.method; crc = o.crc; comp = o.comp; uncomp = o.uncomp
                    time = o.time; date = o.date
                    let dataStart = try ZipDelta.dataOffset(of: o, in: originalIn)
                    try ZipDelta.write(ZipDelta.localHeader(name: nameData, flags: 0x0800, method: method, time: time, date: date,
                                                            crc: crc, comp: comp, uncomp: uncomp), to: output, pos: &pos)
                    try ZipDelta.copy(from: originalIn, offset: dataStart, length: UInt64(comp), to: output, pos: &pos)
                } else if size == 0 {
                    try ZipDelta.write(ZipDelta.localHeader(name: nameData, flags: 0x0800, method: 0, time: time, date: date, crc: 0, comp: 0, uncomp: 0),
                                       to: output, pos: &pos)
                } else {
                    // Changed (or new) file: checksum it, then deflate it.
                    let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                    defer { try? input.close() }
                    uncomp = UInt32(size)
                    crc = try crc32(of: input, length: size)
                    if size < 256 {
                        try input.seek(toOffset: 0)
                        let data = try input.readToEnd() ?? Data()
                        try ZipDelta.write(ZipDelta.localHeader(name: nameData, flags: 0x0800, method: 0, time: time, date: date,
                                                                crc: crc, comp: uncomp, uncomp: uncomp), to: output, pos: &pos)
                        try ZipDelta.write(data, to: output, pos: &pos)
                        comp = uncomp
                    } else {
                        method = 8
                        try ZipDelta.write(ZipDelta.localHeader(name: nameData, flags: 0x0800, method: 8, time: time, date: date,
                                                                crc: crc, comp: 0, uncomp: uncomp), to: output, pos: &pos)
                        let written = try ZipDelta.deflate(from: input, offset: 0, length: size, to: output)
                        pos += written
                        guard written < 0xFFFF_FFFF else { throw Failure("Compressed file too large.") }
                        comp = UInt32(written)
                        try output.seek(toOffset: headerOffset + 18)
                        try output.write(contentsOf: ZipDelta.le32(comp))
                        try output.seek(toOffset: pos)
                    }
                }
            }

            central.append(ZipDelta.le32(0x0201_4b50))
            central.append(ZipDelta.le16((3 << 8) | 20)); central.append(ZipDelta.le16(20))
            central.append(ZipDelta.le16(0x0800)); central.append(ZipDelta.le16(method))
            central.append(ZipDelta.le16(time)); central.append(ZipDelta.le16(date))
            central.append(ZipDelta.le32(crc)); central.append(ZipDelta.le32(comp)); central.append(ZipDelta.le32(uncomp))
            central.append(ZipDelta.le16(UInt16(nameData.count))); central.append(ZipDelta.le16(0)); central.append(ZipDelta.le16(0))
            central.append(ZipDelta.le16(0)); central.append(ZipDelta.le16(0)); central.append(ZipDelta.le32(extAttr))
            central.append(ZipDelta.le32(UInt32(headerOffset)))
            central.append(nameData)
        }

        let cdOffset = pos
        guard cdOffset < 0xFFFF_FFFF else { throw Failure("IPA too large for the simple zip writer.") }
        try output.write(contentsOf: central)
        var eocd = Data()
        eocd.append(ZipDelta.le32(0x0605_4b50)); eocd.append(ZipDelta.le16(0)); eocd.append(ZipDelta.le16(0))
        eocd.append(ZipDelta.le16(UInt16(rel.count))); eocd.append(ZipDelta.le16(UInt16(rel.count)))
        eocd.append(ZipDelta.le32(UInt32(central.count))); eocd.append(ZipDelta.le32(UInt32(cdOffset))); eocd.append(ZipDelta.le16(0))
        try output.write(contentsOf: eocd)
    }

    // MARK: Helpers

    private static func dos(_ d: Date) -> (date: UInt16, time: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: d)
        let year: Int = max(1980, c.year ?? 1980)
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = (c.second ?? 0) / 2
        let dateBits: Int = ((year - 1980) << 9) | (month << 5) | day
        let timeBits: Int = (hour << 11) | (minute << 5) | second
        let date = UInt16(truncatingIfNeeded: dateBits)
        let time = UInt16(truncatingIfNeeded: timeBits)
        return (date, time)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for b in raw.bindMemory(to: UInt8.self) { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }

    private static func crc32(of h: FileHandle, length: UInt64) throws -> UInt32 {
        try h.seek(toOffset: 0)
        var c: UInt32 = 0xFFFF_FFFF
        var remaining = length
        while remaining > 0 {
            let n = Int(min(remaining, 1 << 20))
            let chunk = try autoreleasepool { try h.read(upToCount: n) ?? Data() }
            guard chunk.count == n else { throw Failure("Unexpected end of file while checksumming.") }
            chunk.withUnsafeBytes { raw in
                for b in raw.bindMemory(to: UInt8.self) { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            }
            remaining -= UInt64(n)
        }
        return c ^ 0xFFFF_FFFF
    }
}
