//
//  StorefrontCountry.swift
//  Map Apple Store Front ids (X-Apple-Store-Front) ↔ ISO country codes for
//  multi-account / multi-region iTunes search.
//

import Foundation

enum StorefrontCountry {
    /// Leading numeric id in `X-Apple-Store-Front` (e.g. `143441-1,29` → US).
    private static let idToCode: [Int: String] = [
        143441: "us", 143442: "fr", 143443: "de", 143444: "gb", 143445: "at",
        143446: "be", 143447: "fi", 143448: "gr", 143449: "ie", 143450: "it",
        143451: "lu", 143452: "nl", 143453: "pt", 143454: "dk", 143455: "se",
        143456: "no", 143457: "hu", 143458: "pl", 143459: "cz", 143460: "tr",
        143461: "ro", 143462: "ca", 143463: "mx", 143464: "ru", 143465: "tw",
        143466: "kr", 143467: "au", 143468: "nz", 143469: "jp", 143470: "cn",
        143471: "sg", 143472: "hk", 143473: "in", 143474: "za", 143475: "ae",
        143476: "sa", 143477: "ua", 143478: "by", 143479: "bg", 143480: "hr",
        143481: "cy", 143482: "cz", 143483: "ee", 143484: "lv", 143485: "lt",
        143486: "mt", 143487: "md", 143488: "sk", 143489: "si", 143491: "id",
        143492: "my", 143493: "ph", 143494: "th", 143495: "vn", 143496: "eg",
        143497: "kz", 143498: "am", 143499: "bh", 143501: "ng", 143502: "pk",
        143503: "lk", 143504: "qa", 143505: "kw", 143506: "om", 143507: "jo",
        143508: "br", 143509: "gt", 143510: "ar", 143511: "sv", 143512: "pe",
        143513: "do", 143514: "ec", 143515: "hn", 143516: "jm", 143517: "ni",
        143518: "py", 143519: "uy", 143520: "pa", 143521: "cr", 143523: "cl",
        143524: "bo", 143525: "ve", 143526: "co",
    ]

    static func code(fromStoreFront header: String) -> String? {
        let lead = header.split(separator: "-", maxSplits: 1).first
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let lead, let code = idToCode[lead] else { return nil }
        return code
    }

    static func label(forCode code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Country segment in `https://apps.apple.com/jp/app/...`
    static func code(fromAppStoreURL url: String) -> String? {
        let pattern = #"apps\.apple\.com/([a-z]{2})/"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: url) else {
            return nil
        }
        return String(url[range]).lowercased()
    }
}
