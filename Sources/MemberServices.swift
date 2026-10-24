import SwiftUI

// MARK: - Shared request layer and load state

/// Where a screen's data stands. Views switch on this instead of juggling a spinner flag and an error string.
enum PremiumLoadState: Equatable {
    case idle               // nothing asked for yet
    case loading            // first load, nothing to show yet
    case refreshing         // already have data, reloading quietly
    case loaded
    case failed(String)     // the last load failed; whatever was loaded before is kept
    case signedOut          // the server says the session is no longer valid

    var isWorking: Bool { self == .loading || self == .refreshing }
}

/// One authenticated JSON helper for every /app/v1 call the premium screens make.
/// It turns the messy outcomes (offline, expired session, cancelled task, server errors, HTML from a captive portal)
/// into a handful of cases the clients handle the same way.
enum AirShareAPI {
    enum Failure: Error {
        case signedOut
        case offline
        case cancelled
        case http(Int, String)     // status code and a message that is safe to show
    }

    enum Outcome: Equatable {
        case cancelled
        case signedOut
        case message(String)
    }

    /// Identifies whose data a screen is holding, so one account's tickets or purchases are never shown to the next.
    static var ownerTag: String? {
        guard let t = ZefvAccount.shared.sessionToken, !t.isEmpty else { return nil }
        return String(t.suffix(16))
    }

    static func request(_ method: String, _ path: String, body: [String: Any]? = nil, requiresAuth: Bool = true) async throws -> [String: Any] {
        let token = ZefvAccount.shared.sessionToken ?? ""
        if requiresAuth && token.isEmpty { throw Failure.signedOut }
        guard let base = URL(string: ZefvAccount.apiBase) else { throw Failure.http(0, "The server address is invalid.") }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 20
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch is CancellationError {
            throw Failure.cancelled
        } catch let e as URLError {
            switch e.code {
            case .cancelled: throw Failure.cancelled
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed:
                throw Failure.offline
            default: throw Failure.http(0, "Network problem. Please try again.")
            }
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if code == 401 { throw Failure.signedOut }
        if (200..<300).contains(code) {
            guard let object else { throw Failure.http(code, "Unexpected reply from the server.") }
            return object
        }
        switch code {
        case 500...: throw Failure.http(code, "AirShare had a problem. Try again in a moment.")
        case 429: throw Failure.http(code, (object?["error"] as? String) ?? "Too many requests. Try again later.")
        default: throw Failure.http(code, (object?["error"] as? String) ?? "Request failed (\(code)).")
        }
    }

    static func classify(_ error: Error) -> Outcome {
        if let f = error as? Failure {
            switch f {
            case .cancelled: return .cancelled
            case .signedOut: return .signedOut
            case .offline: return .message("Can't reach AirShare. Check your connection and try again.")
            case let .http(_, message): return .message(message)
            }
        }
        if error is CancellationError { return .cancelled }
        if error is DecodingError { return .message("Unexpected reply from the server.") }
        return .message(error.localizedDescription)
    }

    /// Decodes a JSON array that came out of a dictionary, without crashing if the server sent something else.
    static func decodeList<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> [T] {
        guard let value, JSONSerialization.isValidJSONObject(value) else { return [] }
        return try JSONDecoder().decode([T].self, from: JSONSerialization.data(withJSONObject: value))
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}

/// Inline status for a list screen: spinner on first load, retry on failure, a note when the session ended.
struct StateBanner: View {
    let state: PremiumLoadState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) { ProgressView(); Text("Loading\u{2026}").font(.footnote).foregroundStyle(.secondary) }
        case let .failed(message):
            HStack(alignment: .top, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
                Spacer(minLength: 8)
                Button("Retry", action: retry).font(.footnote.weight(.semibold))
            }
        case .signedOut:
            Label("Your session ended. Sign in again, then come back here.", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.footnote).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

// MARK: - Support

struct SupportTicket: Identifiable, Decodable {
    let id: Int
    let subject: String
    let message: String
    let priority: Bool
    let status: String
    let reply: String?
    let repliedAt: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, subject, message, priority, status, reply, repliedAt = "replied_at", createdAt = "created_at"
    }

    var statusText: String {
        switch status {
        case "open": return "Waiting for a reply"
        case "answered": return "Answered"
        case "closed": return "Closed"
        default: return status.capitalized
        }
    }
}

@MainActor
final class SupportClient: ObservableObject {
    static let shared = SupportClient()

    @Published private(set) var state: PremiumLoadState = .idle
    @Published private(set) var tickets: [SupportTicket] = []
    @Published private(set) var isPremium = false
    @Published private(set) var sending = false
    @Published var sendError: String?
    @Published var notice: String?

    private var generation = 0          // bumps on every load/reset so a slow, older reply can't overwrite a newer one
    private var owner: String?
    private var lastLoaded: Date?

    private init() {}

    func reset() {
        generation += 1
        tickets = []
        isPremium = false
        owner = nil
        lastLoaded = nil
        sendError = nil
        notice = nil
    }

    /// For "screen came back to the front" refreshes: skips the request if the data is fresh.
    func refreshIfStale(maxAge: TimeInterval = 30) async {
        if state.isWorking { return }
        if let t = lastLoaded, owner == AirShareAPI.ownerTag, Date().timeIntervalSince(t) < maxAge { return }
        await load()
    }

    func load() async {
        if owner != nil, owner != AirShareAPI.ownerTag { reset() }   // another account signed in
        generation += 1
        let mine = generation
        state = tickets.isEmpty ? .loading : .refreshing
        do {
            let o = try await AirShareAPI.request("GET", "support")
            guard mine == generation else { return }
            tickets = try AirShareAPI.decodeList(SupportTicket.self, o["tickets"])
            isPremium = (o["premium"] as? Bool) ?? false
            owner = AirShareAPI.ownerTag
            lastLoaded = Date()
            state = .loaded
        } catch {
            guard mine == generation else { return }
            switch AirShareAPI.classify(error) {
            case .cancelled: state = tickets.isEmpty ? .idle : .loaded
            case .signedOut: reset(); state = .signedOut
            case let .message(m): state = .failed(m)
            }
        }
    }

    /// Returns true when the ticket was accepted, so the screen only clears the draft then.
    @discardableResult
    func submit(subject: String, message: String) async -> Bool {
        guard !sending else { return false }          // double tap
        sending = true
        sendError = nil
        notice = nil
        defer { sending = false }
        do {
            let o = try await AirShareAPI.request("POST", "support", body: ["subject": subject, "message": message])
            notice = (o["priority"] as? Bool) == true ? "Sent. It's flagged as priority." : "Sent. We'll reply here."
            await load()                               // best effort; the ticket is saved either way
            return true
        } catch {
            switch AirShareAPI.classify(error) {
            case .cancelled: break
            case .signedOut: sendError = "Your session ended. Sign in again to contact support."
            case let .message(m): sendError = m
            }
            return false
        }
    }
}

// MARK: - Early looks

struct EarlyPost: Identifiable, Decodable {
    let id: Int
    let title: String
    let body: String
    let publicAt: String
    let early: Bool

    enum CodingKeys: String, CodingKey { case id, title, body, publicAt = "public_at", early }
}

@MainActor
final class EarlyClient: ObservableObject {
    static let shared = EarlyClient()

    @Published private(set) var state: PremiumLoadState = .idle
    @Published private(set) var posts: [EarlyPost] = []
    @Published private(set) var locked = 0
    @Published private(set) var isPremium = false

    private var generation = 0
    private var owner: String?
    private var lastLoaded: Date?

    private init() {}

    func reset() {
        generation += 1
        posts = []
        locked = 0
        isPremium = false
        owner = nil
        lastLoaded = nil
    }

    func refreshIfStale(maxAge: TimeInterval = 30) async {
        if state.isWorking { return }
        if let t = lastLoaded, owner == AirShareAPI.ownerTag, Date().timeIntervalSince(t) < maxAge { return }
        await load()
    }

    func load() async {
        // Premium can start or end at any time and decides which posts the server sends, so never trust old data
        // across an account change.
        if owner != nil, owner != AirShareAPI.ownerTag { reset() }
        generation += 1
        let mine = generation
        state = posts.isEmpty ? .loading : .refreshing
        do {
            let o = try await AirShareAPI.request("GET", "early")
            guard mine == generation else { return }
            posts = try AirShareAPI.decodeList(EarlyPost.self, o["posts"])
            locked = (o["locked"] as? Int) ?? 0
            isPremium = (o["premium"] as? Bool) ?? false
            owner = AirShareAPI.ownerTag
            lastLoaded = Date()
            state = .loaded
        } catch {
            guard mine == generation else { return }
            switch AirShareAPI.classify(error) {
            case .cancelled: state = posts.isEmpty ? .idle : .loaded
            case .signedOut: reset(); state = .signedOut
            case let .message(m): state = .failed(m)
            }
        }
    }
}
