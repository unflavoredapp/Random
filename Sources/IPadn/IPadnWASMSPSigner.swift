//
// Brand: Tetherless · https://tetherless.dev
//  IPadnWASMSPSigner.swift
//  Derived from mengangs/ipadn SAPSigner.swift (GPL-2.0).
//  WKWebView + loopback SAPRuntime for sapSign / sapStoreProofHeaders / sapStoreProvision.
//  Named IPadnWASMSPSigner to avoid clashing with Sources/StoreSAP/SAPSigner.
//

import Combine
import CryptoKit
import Foundation
import UIKit
import WebKit

@MainActor
final class IPadnWASMSPSigner: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = IPadnWASMSPSigner()

    @Published private(set) var isPresented = false
    @Published private(set) var webView: WKWebView?
    @Published private(set) var title = "Verifying request"
    @Published private(set) var stage = "Preparing local environment"
    @Published private(set) var stageIndex = 0
    @Published private(set) var startedAt = Date()
    let server = IPadnLoopbackServer()
    private var operationID: UUID?
    private var navigation: CheckedContinuation<Void, Error>?
    private var evaluation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var terminalError: Error?
    private var signatureCache: [String: String] = [:]
    private var kbCache: [String: String] = [:]
    private var storeProofRecords: [String: IPadnStoreProofRecord]?
    private var cacheRevision = UUID()
    private var reusableWebView: WKWebView?
    private var reusableBase: URL?
    private var idleTimeout: Task<Void, Never>?
    private var memoryObserver: AnyCancellable?

    /// Set around work the user is waiting for (getting an app, signing in).
    /// It goes ahead of background work such as reading version details.
    @TaskLocal static var userInitiated = false
    private struct Waiter {
        let id: UUID
        let urgent: Bool
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    private static let idleKeepSeconds: UInt64 = 300

    override init() {
        super.init()
        memoryObserver = Publishers.Merge(
            NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification),
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
        )
        .sink { [weak self] _ in
            Task { @MainActor in
                self?.discardIdleRuntime()
                await self?.server.reset()
            }
        }
    }

    func sign(_ data: Data, guid: String, useCache: Bool, cacheSignature: Bool = true) async throws -> String {
        let key = guid + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try Task.checkCancellation()
        if useCache, cacheSignature, let cached = signatureCache[key] { return cached }
        let revision = cacheRevision
        let result = try await execute(title: "Verifying request", script: """
            reportStage(1);
            await sapInitialize(guid, {proxyURL: proxy});
            try { reportStage(2); return await sapSign(body); }
            finally { await sapClose(); }
            """, arguments: ["guid": guid, "body": data.base64EncodedString()], reuseRuntime: useCache)
        if useCache, cacheSignature, revision == cacheRevision {
            if signatureCache.count >= 128 { signatureCache.removeAll() }
            signatureCache[key] = result
        }
        return result
    }

    func kbsync(guid: String, dsid: String, useCache: Bool) async throws -> String {
        guard guid.count == 12, guid.allSatisfy(\.isHexDigit), let value = UInt64(dsid), value > 0 else {
            throw IPadnToolError.message("Invalid device or account identifier — sign in again")
        }
        try Task.checkCancellation()
        let key = guid + ":" + dsid
        if useCache, let cached = kbCache[key] { return cached }
        let revision = cacheRevision
        let result = try await execute(title: "Preparing download", script: """
            reportStage(1);
            await loadSapSigner();
            reportStage(2);
            return await sapGenerateKBSync(guid, dsid);
            """, arguments: ["guid": guid, "dsid": dsid], reuseRuntime: useCache)
        if useCache, revision == cacheRevision { kbCache[key] = result }
        return result
    }

    private struct StoreStatePayload: Codable {
        var identifier: String
        var files: [String: String]
    }

    private struct StoreProofPayload: Decodable {
        var provisioned: Bool
        var headers: [String: String]?
        var state: StoreStatePayload
    }

    private static func normalizedStoreGUID(_ guid: String) throws -> String {
        let cleaned = guid.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
        guard cleaned.count == 12, cleaned.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw IPadnToolError.message("Invalid device identifier — check settings")
        }
        return cleaned
    }

    private static func derivedStoreIdentifier(guid: String) -> String {
        let digest = SHA256.hash(data: Data(("iPadn-store-id:" + guid).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomStoreIdentifier() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private func currentStoreRecords() -> [String: IPadnStoreProofRecord] {
        if let loaded = storeProofRecords { return loaded }
        let loaded = IPadnStoreProofStore.load()
        storeProofRecords = loaded
        return loaded
    }

    private func record(for normalizedGUID: String) -> IPadnStoreProofRecord {
        if let existing = currentStoreRecords()[normalizedGUID],
           existing.identifier.count == 16,
           existing.identifier.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
            return existing
        }
        return IPadnStoreProofRecord(
            identifier: Self.derivedStoreIdentifier(guid: normalizedGUID),
            files: [:]
        )
    }

    private func saveRecord(_ record: IPadnStoreProofRecord, for normalizedGUID: String) {
        var all = currentStoreRecords()
        var updated = record
        updated.updatedAt = Date()
        all[normalizedGUID] = updated
        storeProofRecords = all
        IPadnStoreProofStore.save(all)
    }

    func storeProofHeaders(guid: String, useCache: Bool) async throws -> [String: String]? {
        let normalized = try Self.normalizedStoreGUID(guid)
        try Task.checkCancellation()
        let existing = record(for: normalized)
        guard !existing.files.isEmpty else { return nil }
        let stateData = try JSONEncoder().encode(
            StoreStatePayload(identifier: existing.identifier, files: existing.files)
        )
        guard let stateJSON = String(data: stateData, encoding: .utf8) else { return nil }
        let output = try await execute(title: "Verifying device", script: """
            reportStage(1);
            reportStage(2);
            return await sapStoreProofHeaders(state, {proxyURL: proxy});
            """, arguments: ["state": stateJSON], reuseRuntime: useCache)
        let payload = try JSONDecoder().decode(StoreProofPayload.self, from: Data(output.utf8))
        if payload.state.identifier != existing.identifier || payload.state.files != existing.files {
            saveRecord(
                IPadnStoreProofRecord(identifier: payload.state.identifier, files: payload.state.files),
                for: normalized
            )
        }
        guard payload.provisioned,
              let headers = payload.headers,
              let otp = headers["X-Apple-AMD"], !otp.isEmpty,
              let mid = headers["X-Apple-AMD-M"], !mid.isEmpty else {
            return nil
        }
        return ["X-Apple-AMD": otp, "X-Apple-AMD-M": mid]
    }

    func provisionStoreProof(challenge: String, guid: String, useCache: Bool) async throws -> [String: String] {
        let normalized = try Self.normalizedStoreGUID(guid)
        guard !challenge.isEmpty else {
            throw IPadnToolError.message("Invalid device verification parameter — try again")
        }
        try Task.checkCancellation()
        let current = record(for: normalized)
        let stateData = try JSONEncoder().encode(
            StoreStatePayload(identifier: current.identifier, files: current.files)
        )
        guard let stateJSON = String(data: stateData, encoding: .utf8) else {
            throw IPadnToolError.message("Failed to encode device verification state")
        }
        let output = try await execute(title: "Verifying device", script: """
            reportStage(1);
            reportStage(2);
            return await sapStoreProvision(state, challenge, guid, {proxyURL: proxy});
            """, arguments: [
                "state": stateJSON,
                "challenge": challenge,
                "guid": normalized
            ], reuseRuntime: useCache)
        let payload = try JSONDecoder().decode(StoreProofPayload.self, from: Data(output.utf8))
        guard payload.provisioned,
              let headers = payload.headers,
              let otp = headers["X-Apple-AMD"], !otp.isEmpty,
              let mid = headers["X-Apple-AMD-M"], !mid.isEmpty else {
            throw IPadnToolError.message("Device verification incomplete — try again")
        }
        saveRecord(
            IPadnStoreProofRecord(identifier: payload.state.identifier, files: payload.state.files),
            for: normalized
        )
        return ["X-Apple-AMD": otp, "X-Apple-AMD-M": mid]
    }

    func resetStoreProof(guid: String) {
        guard let normalized = try? Self.normalizedStoreGUID(guid) else { return }
        saveRecord(
            IPadnStoreProofRecord(identifier: Self.randomStoreIdentifier(), files: [:]),
            for: normalized
        )
    }

    private enum RuntimeRetry: Error { case coldStart }

    func execute(
        title: String,
        script: String,
        arguments: [String: Any],
        timeoutSeconds: UInt64 = 180,
        reuseRuntime: Bool = true
    ) async throws -> String {
        do {
            return try await executeAttempt(
                title: title,
                script: script,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds,
                reuseRuntime: reuseRuntime
            )
        } catch {
            try Task.checkCancellation()
            if error is RuntimeRetry {
                return try await executeAttempt(
                    title: title,
                    script: script,
                    arguments: arguments,
                    timeoutSeconds: timeoutSeconds,
                    reuseRuntime: false
                )
            }
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain
                && (ns.code == NSURLErrorCannotConnectToHost || ns.code == NSURLErrorNetworkConnectionLost) {
                IPadnInstallLog.shared.add(
                    "IPadnWASMSPSigner loopback error (\(ns.code)), resetting server and retrying"
                )
                await server.reset()
                discardIdleRuntime()
                return try await executeAttempt(
                    title: title,
                    script: script,
                    arguments: arguments,
                    timeoutSeconds: timeoutSeconds,
                    reuseRuntime: false
                )
            }
            throw error
        }
    }

    private func executeAttempt(
        title: String,
        script: String,
        arguments: [String: Any],
        timeoutSeconds: UInt64 = 180,
        reuseRuntime: Bool = true
    ) async throws -> String {
        try await acquireTurn()
        let id = UUID()
        operationID = id
        terminalError = nil
        let revision = cacheRevision
        var succeeded = false
        idleTimeout?.cancel()
        idleTimeout = nil
        self.title = title
        stage = "Preparing local environment"
        stageIndex = 0
        startedAt = Date()
        defer { release(id: id, reuse: reuseRuntime && succeeded && cacheRevision == revision) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await server.start()
            try checkActive(id)
            guard let base = server.baseURL else {
                throw IPadnToolError.message("Couldn’t finish verification — please retry")
            }
            let web: WKWebView
            let warm = reuseRuntime && reusableBase == base && reusableWebView != nil
            if warm, let saved = reusableWebView {
                web = saved
            } else {
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()
                web = WKWebView(frame: .zero, configuration: config)
            }
            reusableWebView = nil
            reusableBase = nil
            web.configuration.userContentController.add(self, name: "progress")
            web.navigationDelegate = self
            webView = web
            isPresented = true
            if !warm {
                armTimeout(id: id, seconds: 45, message: "Local verification environment timed out — try again.")
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    navigation = continuation
                    web.load(URLRequest(url: base.appendingPathComponent("runtime/index.html")))
                }
            } else {
                stage = "Reusing local verification components"
            }
            try checkActive(id)
            armTimeout(
                id: id,
                seconds: timeoutSeconds,
                message: "Verification exceeded 3 minutes and was stopped. Keep the app in the foreground and retry."
            )
            var values = arguments
            values["proxy"] = base.appendingPathComponent("proxy").absoluteString
            let result: String
            do {
                result = try await withCheckedThrowingContinuation { continuation in
                    evaluation = continuation
                    web.callAsyncJavaScript(script, arguments: values, in: nil, in: .page) { [weak self] result in
                        Task { @MainActor in
                            guard let self, self.operationID == id, let continuation = self.evaluation else { return }
                            self.evaluation = nil
                            switch result {
                            case .success(let value):
                                if let text = value as? String, !text.isEmpty {
                                    continuation.resume(returning: text)
                                } else {
                                    continuation.resume(
                                        throwing: IPadnToolError.message("Verification result was empty — try again")
                                    )
                                }
                            case .failure(let err):
                                continuation.resume(throwing: err)
                            }
                        }
                    }
                }
            } catch {
                try checkActive(id)
                if warm {
                    discardIdleRuntime()
                    throw RuntimeRetry.coldStart
                }
                throw IPadnToolError.message("Verification didn’t finish — check the network and retry")
            }
            try checkActive(id)
            succeeded = true
            return result
        } onCancel: { [weak self] in
            Task { @MainActor in self?.stop(id: id, error: CancellationError()) }
        }
    }

    private func acquireTurn() async throws {
        try Task.checkCancellation()
        guard operationID != nil || !waiters.isEmpty else { return }
        let ticket = UUID()
        let urgent = Self.userInitiated
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let waiter = Waiter(id: ticket, urgent: urgent, continuation: continuation)
                if urgent, let index = waiters.firstIndex(where: { !$0.urgent }) {
                    waiters.insert(waiter, at: index)
                } else {
                    waiters.append(waiter)
                }
                if operationID == nil { handOver() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = self.waiters.firstIndex(where: { $0.id == ticket }) else { return }
                self.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func handOver() {
        guard operationID == nil, !waiters.isEmpty else { return }
        operationID = UUID()
        waiters.removeFirst().continuation.resume()
    }

    private func checkActive(_ id: UUID) throws {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        guard operationID == id else { throw CancellationError() }
    }

    private func armTimeout(id: UUID, seconds: UInt64, message: String) {
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            } catch {
                return
            }
            self?.stop(id: id, error: IPadnToolError.message(message))
        }
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        let continuation = navigation
        navigation = nil
        continuation?.resume(with: result)
    }

    private func stop(id: UUID, error: Error) {
        guard operationID == id else { return }
        terminalError = error
        finishNavigation(.failure(error))
        let continuation = evaluation
        evaluation = nil
        continuation?.resume(throwing: error)
        timeout?.cancel()
        webView?.stopLoading()
        webView?.loadHTMLString("<!doctype html><title>Stopped</title>", baseURL: nil)
        isPresented = false
    }

    func cancel() {
        if let id = operationID { stop(id: id, error: CancellationError()) }
    }

    private func release(id: UUID, reuse: Bool) {
        guard operationID == id else { return }
        timeout?.cancel()
        timeout = nil
        finishNavigation(.failure(CancellationError()))
        let continuation = evaluation
        evaluation = nil
        continuation?.resume(throwing: CancellationError())
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "progress")
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        if reuse && UIApplication.shared.applicationState != .background {
            reusableWebView = webView
            reusableBase = server.baseURL
            idleTimeout = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.idleKeepSeconds * 1_000_000_000)
                } catch {
                    return
                }
                self?.discardIdleRuntime()
            }
        } else {
            reusableWebView = nil
            reusableBase = nil
        }
        webView = nil
        isPresented = false
        operationID = nil
        terminalError = nil
        handOver()
    }

    private func discardIdleRuntime() {
        guard operationID == nil else { return }
        idleTimeout?.cancel()
        idleTimeout = nil
        reusableWebView?.stopLoading()
        reusableWebView = nil
        reusableBase = nil
    }

    func clearCache() {
        cacheRevision = UUID()
        signatureCache.removeAll()
        kbCache.removeAll()
        discardIdleRuntime()
    }

    func prewarm() {
        guard operationID == nil, waiters.isEmpty, reusableWebView == nil,
              UIApplication.shared.applicationState == .active else { return }
        Task {
            _ = try? await execute(
                title: "Preparing verification components",
                script: "return 'ready';",
                arguments: [:],
                timeoutSeconds: 30
            )
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.webView === webView, operationID != nil,
              let index = message.body as? Int, (1...2).contains(index) else { return }
        stageIndex = index
        stage = index == 1
            ? "Loading verification components"
            : title == "Preparing download"
                ? "Generating download authorization data"
                : title == "Verifying device"
                    ? "Completing device security verification"
                    : "Generating request signature"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, terminalError == nil else { return }
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        finishNavigation(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView else { return }
        finishNavigation(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView, let id = operationID else { return }
        stop(id: id, error: IPadnToolError.message("Verification was interrupted — try again"))
    }
}
