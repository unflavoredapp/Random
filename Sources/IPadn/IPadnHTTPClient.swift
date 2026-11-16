//
//  IPadnHTTPClient.swift
//  Derived from mengangs/ipadn HTTPClient.swift (GPL-2.0).
//  Used for bag.xml + MZFinance authenticate redirects.
//

import Foundation

enum IPadnHTTPStatusError: LocalizedError {
    case code(Int)
    var code: Int {
        if case .code(let c) = self { return c }
        return 0
    }
    var errorDescription: String? { "HTTP \(code)" }
}

enum IPadnToolError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

final class IPadnHTTPClient: Sendable {
    static let shared = IPadnHTTPClient()
    /// Configurator UA — same as iPadn / ipatool-style store edge.
    static let userAgent =
        "Configurator/2.21 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let status = error as? IPadnHTTPStatusError {
            return [408, 429, 500, 502, 503, 504].contains(status.code)
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed, NSURLErrorSecureConnectionFailed
        ].contains(ns.code)
    }

    func request(
        _ url: URL,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:],
        appleRedirects: Bool = false,
        authentication: Bool = false,
        allowRedirects: Bool = true,
        retryTransient: Bool? = nil,
        refreshHeaders: ((URL) async throws -> [String: String])? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let retries = (retryTransient ?? (method == "GET")) ? 2 : 0
        var attempt = 0
        while true {
            do {
                return try await requestOnce(
                    url,
                    method: method,
                    body: body,
                    headers: headers,
                    appleRedirects: appleRedirects,
                    authentication: authentication,
                    allowRedirects: allowRedirects,
                    refreshHeaders: refreshHeaders
                )
            } catch {
                guard attempt < retries, Self.isTransient(error), !Task.isCancelled else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }
    }

    private func requestOnce(
        _ url: URL,
        method: String,
        body: Data?,
        headers: [String: String],
        appleRedirects: Bool,
        authentication: Bool,
        allowRedirects: Bool,
        refreshHeaders: ((URL) async throws -> [String: String])?
    ) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            throw IPadnToolError.message("Invalid Apple URL.")
        }
        var current = url
        var activeMethod = method
        var activeBody = body
        var activeHeaders = headers
        let initialHost = url.host?.lowercased()
        for _ in 0..<5 {
            try Task.checkCancellation()
            var request = URLRequest(url: current)
            request.httpMethod = activeMethod
            request.httpBody = activeBody
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            activeHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw IPadnToolError.message("Bad Apple response.")
            }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard allowRedirects else { throw IPadnHTTPStatusError.code(response.statusCode) }
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let rawNext = URL(string: location, relativeTo: current)?.absoluteURL,
                      rawNext.scheme?.lowercased() == "https",
                      let host = rawNext.host?.lowercased(),
                      rawNext.user == nil,
                      rawNext.password == nil else {
                    throw IPadnToolError.message("Apple redirect missing Location.")
                }
                let next: URL
                if authentication {
                    guard [301, 302, 307, 308].contains(response.statusCode),
                          let normalized = IPadnAppleAuthentication.normalizedEndpoint(rawNext) else {
                        throw IPadnToolError.message("Apple returned an invalid login URL.")
                    }
                    next = normalized
                } else if appleRedirects {
                    guard host == "itunes.apple.com" || host.hasSuffix(".itunes.apple.com") else {
                        throw IPadnToolError.message("Unexpected Apple redirect host.")
                    }
                    next = rawNext
                    if response.statusCode == 303 && activeMethod != "GET" && activeMethod != "HEAD" {
                        activeMethod = "GET"
                        activeBody = nil
                        activeHeaders = activeHeaders.filter {
                            $0.key.lowercased() != "content-type"
                        }
                    }
                } else {
                    guard host == initialHost else {
                        throw IPadnToolError.message("Unexpected redirect host.")
                    }
                    next = rawNext
                    if response.statusCode == 303 && activeMethod != "GET" && activeMethod != "HEAD" {
                        activeMethod = "GET"
                        activeBody = nil
                        activeHeaders = activeHeaders.filter {
                            $0.key.lowercased() != "content-type"
                        }
                    }
                }
                if let refreshHeaders {
                    activeHeaders = try await refreshHeaders(next)
                } else if !IPadnAppleAuthentication.needsStoreProof(next, method: activeMethod) {
                    activeHeaders = activeHeaders.filter {
                        !["x-apple-amd", "x-apple-amd-m"].contains($0.key.lowercased())
                    }
                }
                current = next
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw IPadnHTTPStatusError.code(response.statusCode)
            }
            return (data, response)
        }
        throw IPadnToolError.message("Too many Apple redirects.")
    }

    static func encodePlist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    /// POST a plist body and decode the Apple plist response (DownloadDispatch / buyProduct).
    func plist(
        _ url: URL,
        body: Data,
        headers: [String: String] = [:],
        refreshHeaders: ((URL) async throws -> [String: String])? = nil
    ) async throws -> ([String: Any], HTTPURLResponse) {
        let (data, response) = try await request(
            url,
            method: "POST",
            body: body,
            headers: headers,
            appleRedirects: true,
            retryTransient: true,
            refreshHeaders: refreshHeaders
        )
        let dict = try IPadnApplePropertyList.dictionary(data)
        return (dict, response)
    }

    static func appleFailure(_ response: [String: Any]) -> IPadnToolError? {
        let code = ipadnPlistString(response["failureType"])
        guard !code.isEmpty else { return nil }
        let messages: [String: String] = [
            "2002": "Apple ID needs to sign in again — check the password.",
            "5002": "Apple services are temporarily unavailable.",
            "2040": "This app can’t be downloaded from Apple right now.",
            "-5000": "Incorrect Apple ID or password.",
            "2059": "This app can’t be downloaded right now. Try again later.",
            "1010": "This app isn’t available in this account’s storefront.",
            "2034": "Apple login expired — sign in again.",
            "2042": "Apple login expired — sign in again.",
            "2019": "Buy this paid app in the App Store first.",
            "9610": "This account doesn’t have a license for this app."
        ]
        return .message(messages[code] ?? "Apple couldn’t complete that request. Try again.")
    }
}
