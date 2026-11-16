// Brand: Tetherless · https://tetherless.dev
import Foundation

extension SAPSigner {
    private static let setupUA =
        "Configurator/2.15 (Macintosh; OS X 11.0.0; 16A5288f) AppleWebKit/0605.2.7.5"

    /// Reuse one SAP session across authenticate remints (handshake is expensive / flaky on cellular).
    private static let cacheTTL: TimeInterval = 20 * 60
    private static var cached: SAPSigner?
    private static var cachedAt: Date?
    private static let cacheLock = NSLock()

    /// Establish protocol-200 state using Apple's certificate and two-round setup service.
    /// Retries transient network drops (common on cellular / brief Wi‑Fi blips).
    static func connect(forceRefresh: Bool = false) async throws -> SAPSigner {
        if !forceRefresh, let hit = cachedIfFresh() {
            return hit
        }
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let signer = try await connectOnce()
                cacheLock.lock()
                cached = signer
                cachedAt = Date()
                cacheLock.unlock()
                return signer
            } catch {
                lastError = error
                invalidateCache()
                if !isTransientSetupFailure(error) || attempt == 3 { throw error }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }
        throw lastError ?? SAPError.invalidInput("SAP setup failed")
    }

    /// Drop cached SAP state (call after hard auth failures that look like a dead session).
    static func invalidateCache() {
        cacheLock.lock()
        cached = nil
        cachedAt = nil
        cacheLock.unlock()
    }

    /// Prefetch SAP so Decrypt / Retry isn't blocked on the first handshake.
    static func warm() async {
        _ = try? await connect()
    }

    private static func cachedIfFresh() -> SAPSigner? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < cacheTTL else {
            return nil
        }
        return cached
    }

    private static func isTransientSetupFailure(_ error: Error) -> Bool {
        let m = error.localizedDescription.lowercased()
        if m.contains("network connection was lost")
            || m.contains("timed out")
            || m.contains("not connected to the internet")
            || m.contains("connection reset")
            || m.contains("network is unreachable")
            || m.contains("ssl")
            || m.contains("socket") {
            return true
        }
        let ns = error as NSError
        // NSURLError cancelled / timed out / connection lost / DNS
        return [-1001, -1005, -1009, -1018, -1200, -1202].contains(ns.code)
    }

    private static func connectOnce() async throws -> SAPSigner {
        func exchange(url: String, payload: Data? = nil, key: String) async throws -> Data {
            guard let endpoint = URL(string: url) else {
                throw SAPError.invalidInput("Bad SAP setup URL")
            }
            var req = URLRequest(url: endpoint)
            req.timeoutInterval = 30
            req.setValue(setupUA, forHTTPHeaderField: "User-Agent")
            if let payload {
                req.httpMethod = "POST"
                req.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
                req.httpBody = try PropertyListSerialization.data(
                    fromPropertyList: ["sign-sap-setup-buffer": payload],
                    format: .xml,
                    options: 0
                )
            } else {
                req.httpMethod = "GET"
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let value = plist[key] as? Data, !value.isEmpty, value.count <= 1 << 20
            else {
                throw SAPError.invalidInput("SAP setup service returned an invalid response (HTTP \(status))")
            }
            return value
        }

        let certificate = try await exchange(
            url: "https://s.mzstatic.com/sap/setupCert.plist",
            key: "sign-sap-setup-cert"
        )
        let handshake = try SAPHandshake(certificate: certificate)
        let reply = try await exchange(
            url: "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy",
            payload: handshake.request,
            key: "sign-sap-setup-buffer"
        )
        return try SAPSigner(session: handshake.complete(reply))
    }
}
