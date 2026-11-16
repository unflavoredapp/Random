//
// Brand: Tetherless · https://tetherless.dev
//  IPadnVersionHistory.swift
//  Derived from mengangs/ipadn VersionService + VersionSource (GPL-2.0).
//  Public history feeds (Timbrd / Bilin / iosdump) enrich TetherLess version
//  pickers when authenticated Store history is thin or unavailable.
//

import Foundation

struct IPadnVersionSource: Equatable, Sendable {
    var name: String
    var urlTemplate: String
    var containerKey: String
    var reverse: Bool
    var enabled: Bool = true

    static let defaults: [IPadnVersionSource] = [
        IPadnVersionSource(
            name: "Timbrd",
            urlTemplate: "https://api.timbrd.com/apple/app-version/index.php?id={id}",
            containerKey: "",
            reverse: true
        ),
        IPadnVersionSource(
            name: "Bilin",
            urlTemplate: "https://apis.bilin.eu.org/history/{id}",
            containerKey: "data",
            reverse: false
        ),
        IPadnVersionSource(
            name: "iosdump",
            urlTemplate: "https://iosdump.apdoilaan.work/history/{appId}",
            containerKey: "data",
            reverse: false
        ),
    ]

    private static let placeholders = ["{id}", "{appId}", "{appid}", "{APPID}"]

    func url(for appID: String) -> URL? {
        let filled = Self.placeholders.reduce(urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)) {
            $0.replacingOccurrences(of: $1, with: appID)
        }
        guard let url = URL(string: filled), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

enum IPadnVersionHistory {
    /// Merge public history feeds into DecryptVersion rows (newest-first when possible).
    static func fetch(adamId: String, sources: [IPadnVersionSource] = IPadnVersionSource.defaults) async -> [DecryptVersion] {
        let id = adamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return [] }
        let enabled = sources.filter(\.enabled)
        guard !enabled.isEmpty else { return [] }

        let lists: [[DecryptVersion]] = await withTaskGroup(of: [DecryptVersion].self) { group in
            for source in enabled {
                group.addTask { await fetchOne(id, source: source) }
            }
            var out: [[DecryptVersion]] = []
            for await batch in group { out.append(batch) }
            return out
        }
        return merge(lists)
    }

    private static func fetchOne(_ adamId: String, source: IPadnVersionSource) async -> [DecryptVersion] {
        guard let url = source.url(for: adamId) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        let value: Any? = source.containerKey.isEmpty
            ? object
            : (object as? [String: Any])?[source.containerKey]
        guard let records = value as? [[String: Any]] else { return [] }
        let ordered = source.reverse ? Array(records.suffix(2000).reversed()) : Array(records.prefix(2000))
        var seen = Set<String>()
        return ordered.compactMap { row -> DecryptVersion? in
            let ext = string(row["external_identifier"])
            guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && $0.isNumber }),
                  seen.insert(ext).inserted else { return nil }
            let ver = sanitizedVersion(string(row["bundle_version"]), rejectingID: ext)
            return DecryptVersion(v: ver, current: false, minOS: nil, externalId: ext)
        }
    }

    private static func merge(_ sources: [[DecryptVersion]]) -> [DecryptVersion] {
        var byExt: [String: DecryptVersion] = [:]
        var order: [String] = []
        for list in sources {
            for item in list {
                let key = (item.externalId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                if byExt[key] == nil {
                    byExt[key] = item
                    order.append(key)
                } else if let existing = byExt[key], prefer(item.v, over: existing.v, rejectingID: key) {
                    byExt[key] = DecryptVersion(
                        v: item.v,
                        current: existing.current || item.current,
                        minOS: existing.minOS ?? item.minOS,
                        externalId: key
                    )
                }
            }
        }
        return order.compactMap { byExt[$0] }
    }

    private static func prefer(_ candidate: String, over current: String, rejectingID: String) -> Bool {
        preference(candidate, rejectingID: rejectingID) > preference(current, rejectingID: rejectingID)
    }

    private static func preference(_ raw: String, rejectingID: String) -> Int {
        let v = sanitizedVersion(raw, rejectingID: rejectingID)
        if v == "—" || v.isEmpty { return 0 }
        if v == rejectingID { return 1 }
        if v.contains(".") { return 3 }
        return 2
    }

    private static func sanitizedVersion(_ raw: String, rejectingID: String?) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "—" }
        if let rejectingID, t == rejectingID { return "—" }
        return t
    }

    private static func string(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }
}
