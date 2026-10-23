import Foundation
import Combine
import UIKit
import IDevice

// A completed error response from iOS's installer means the app was rejected,
// rather than the transport failing. Keep its original message for the row.
public struct IDeviceInstallationRejection: LocalizedError {
    private let message: String
    public var errorDescription: String? { message }
    init(message: String) { self.message = message }
}

/// An IPA that arrives in two parts: a prefix that is known up front (uploaded while the app is still
/// being signed) and a tail (changed files + zip directory) that is supplied once signing finishes.
public final class StreamedIPA: @unchecked Sendable {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }
    private let lock = NSLock()
    private let prefixSignal = DispatchSemaphore(value: 0)
    private let tailSignal = DispatchSemaphore(value: 0)
    private var prefix: Result<URL, Error>?
    private var tail: Result<URL, Error>?
    public init() {}

    public func setPrefix(_ r: Result<URL, Error>) {
        lock.lock(); let first = prefix == nil; if first { prefix = r }; lock.unlock()
        if first { prefixSignal.signal() }
    }
    public func setTail(_ r: Result<URL, Error>) {
        lock.lock(); let first = tail == nil; if first { tail = r }; lock.unlock()
        if first { tailSignal.signal() }
    }
    func waitPrefix(_ check: () throws -> Void) throws -> URL {
        while prefixSignal.wait(timeout: .now() + 0.25) == .timedOut { try check() }
        lock.lock(); defer { lock.unlock() }
        return try prefix!.get()
    }
    func waitTail(_ check: () throws -> Void) throws -> URL {
        while tailSignal.wait(timeout: .now() + 0.25) == .timedOut { try check() }
        lock.lock(); defer { lock.unlock() }
        return try tail!.get()
    }
}

public final class InstallationProxy: Identifiable, ObservableObject {
    public let viewModel: InstallerStatusViewModel
    private let cancellation = IDeviceInstallCancellation()
    private var isCurrent: () -> Bool = { true }
    fileprivate var uninstallProgress: (@Sendable (Double) -> Void)?

    public init(viewModel: InstallerStatusViewModel) { self.viewModel = viewModel }

    // Each proxy is one attempt. Cancellation waits for any native call already
    // in progress to return before releasing resources and its admission slot.
    public func install(at url: URL, suspend: Bool = false, streamed: StreamedIPA? = nil,
                        isCurrent: @escaping () -> Bool = { true }) async throws {
        self.isCurrent = isCurrent
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await IDeviceInstallationWorker.performInstallation { [self] in
                try cancellation.check()
                try installSynchronously(at: url, suspend: suspend, streamed: streamed)
            }
            try cancellation.check()
            await MainActor.run {
                if isCurrent() { viewModel.status = .completed(.success(())) }
            }
        } onCancel: { [cancellation] in cancellation.cancel() }
    }

    private func checkCancellation() throws {
        try cancellation.check()
        if !isCurrent() { throw CancellationError() }
    }

    private func update(_ action: @escaping (InstallerStatusViewModel) -> Void) {
        DispatchQueue.main.async { [self] in
            guard !cancellation.isCancelled, isCurrent() else { return }
            action(viewModel)
        }
    }

    private func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let error else { return }
        defer { idevice_error_free(error) }
        // Pinned idevice: InstallationProxy = 107, OperationFailed = 1.
        // Socket failures remain transport errors, even during installation.
        if error.pointee.code == 107 && error.pointee.sub_code == 1 {
            throw IDeviceInstallationRejection(message: IDeviceSwiftError(error).localizedDescription)
        }
        throw IDeviceSwiftError(error)
    }

    private func installSynchronously(at url: URL, suspend: Bool, streamed: StreamedIPA?) throws {
        let heartbeat = HeartbeatManager.shared
        guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
            throw IDeviceSwiftError(message: "Pair this device in Installation settings before installing.")
        }
        // Keep a lease on the workflow's shared tunnel until this attempt's
        // clients are freed. Per-app handles stay on this worker thread.
        let connection = heartbeat.isRsd ? try heartbeat.acquireRSDConnection() : nil
        defer { withExtendedLifetime(connection) {} }
        let provider = connection == nil ? try makeLegacyProvider(heartbeat) : nil
        defer { idevice_provider_free(provider) }
        try checkCancellation()
        var afc: OpaquePointer?
        var proxy: OpaquePointer?
        var file: OpaquePointer?
        var remotePath: String?
        defer {
            if let file { idevice_error_free(afc_file_close(file)) }
            if let remotePath { idevice_error_free(afc_remove_path(afc, remotePath)) }
            installation_proxy_client_free(proxy)
            afc_client_free(afc)
        }
        if let connection {
            try connection.withServiceConnection { adapter, handshake in
                try check(afc_client_connect_rsd(adapter, handshake, &afc))
            }
        } else {
            try check(afc_client_connect(provider, &afc))
        }
        // PublicStaging normally exists. Ignore only AFC's OBJECT_EXISTS status.
        if let error = afc_make_directory(afc, "PublicStaging") {
            defer { idevice_error_free(error) }
            guard error.pointee.sub_code == 16 else { throw IDeviceSwiftError(error) }
        }
        let stagingPath = "/PublicStaging/\(UUID().uuidString).ipa"
        remotePath = stagingPath
        try check(afc_file_open(afc, stagingPath, AfcWrOnly, &file))
        // Bound resident upload memory per admitted job: files are streamed in chunks.
        // Chunk size is user-selectable (Settings › Install Method › Connection); each write is one round trip.
        let chosenMB = UserDefaults.standard.integer(forKey: "AirShare.uploadChunkMB")
        let chunkBytes = [1, 2, 4, 8, 16].contains(chosenMB) ? chosenMB * 1_048_576 : 4 * 1_048_576
        var sent: UInt64 = 0
        var knownTotal: UInt64 = 0
        var tailPending = false
        func fileSize(_ u: URL) -> UInt64 {
            ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.uint64Value) ?? 0
        }
        func send(_ fileURL: URL) throws {
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            let byteCount = try input.seekToEnd()
            try input.seek(toOffset: 0)
            var offset: UInt64 = 0
            while offset < byteCount {
                try checkCancellation()
                let size = Int(min(UInt64(chunkBytes), byteCount - offset))
                let written = try autoreleasepool { () throws -> Int in
                    guard let data = try input.read(upToCount: size), !data.isEmpty else {
                        throw IDeviceSwiftError(message: "The IPA ended before its upload completed.")
                    }
                    try data.withUnsafeBytes { bytes in
                        try check(afc_file_write(file, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count))
                    }
                    return data.count
                }
                offset += UInt64(written)
                sent += UInt64(written)
                let denominator = Double(max(knownTotal + (tailPending ? knownTotal / 10 : 0), 1))
                let progress = min(1, Double(sent) / denominator)
                update { $0.uploadProgress = progress }
            }
        }
        update { $0.packageProgress = 1; $0.status = .sendingPayload }
        if let streamed {
            // Upload what's already known while the app is still being signed, then the changed tail.
            let prefixURL = try streamed.waitPrefix { try self.checkCancellation() }
            knownTotal = fileSize(prefixURL); tailPending = true
            try send(prefixURL)
            let tailURL = try streamed.waitTail { try self.checkCancellation() }
            knownTotal += fileSize(tailURL); tailPending = false
            try send(tailURL)
        } else {
            let byteCount = fileSize(url)
            guard byteCount > 0 else { throw IDeviceSwiftError(message: "The IPA is empty.") }
            knownTotal = byteCount
            try send(url)
        }
        let closeResult = afc_file_close(file)
        file = nil // close consumes the handle, including on failure
        try check(closeResult)
        try checkCancellation()
        if let connection {
            try connection.withServiceConnection { adapter, handshake in
                try check(installation_proxy_connect_rsd(adapter, handshake, &proxy))
            }
        } else {
            try check(installation_proxy_connect(provider, &proxy))
        }
        update { $0.status = .installing }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if suspend {
            DispatchQueue.main.async { UIApplication.shared.perform(#selector(NSXPCConnection.suspend)) }
        }
        try check(installation_proxy_install_with_callback(proxy, stagingPath, nil, Self.progressCallback, context))
        try checkCancellation()
    }

    private func makeLegacyProvider(_ heartbeat: HeartbeatManager) throws -> OpaquePointer {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = heartbeat.port.bigEndian
        guard inet_pton(AF_INET, heartbeat.ipAddress, &address.sin_addr) == 1,
              let pairing = heartbeat.getPairing() else {
            throw IDeviceSwiftError(message: "The device pairing or address is unavailable.")
        }
        var provider: OpaquePointer?
        let error = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) {
                idevice_tcp_provider_new($0, pairing, "AirShare installation", &provider)
            }
        }
        // The constructor consumes pairing on success; the address and label
        // above are valid, so an error leaves that ownership with us.
        if let error {
            idevice_pairing_file_free(pairing)
            try check(error)
        }
        guard let provider else { throw IDeviceSwiftError(message: "Could not create the device connection.") }
        return provider
    }

    private static let progressCallback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { progress, context in
        guard let context else { return }
        let operation = Unmanaged<InstallationProxy>.fromOpaque(context).takeUnretainedValue()
        operation.update { $0.installProgress = min(1, Double(progress) / 100) }
    }
}

// MARK: - Installed apps (list + uninstall)

/// A user-installed app reported by the device's installation service.
/// `isAppStore` is true when iOS reports Apple's App Store signature (FairPlay-encrypted, i.e. not decrypted).
public struct DeviceApp: Identifiable, Hashable, Codable, Sendable {
    public let bundleID: String
    public let name: String
    public let version: String
    public let isAppStore: Bool
    /// App + data size on disk, when the device reported it.
    public let sizeBytes: Int64?
    public var id: String { bundleID }
    public init(bundleID: String, name: String, version: String, isAppStore: Bool = false, sizeBytes: Int64? = nil) {
        self.bundleID = bundleID; self.name = name; self.version = version
        self.isAppStore = isAppStore; self.sizeBytes = sizeBytes
    }
}

extension InstallationProxy {
    /// Opens the device connection the same way `install` does (shared RSD tunnel, else the legacy provider)
    /// and hands it to `body`. Must run on an IDeviceInstallationWorker thread.
    private func withDeviceConnection<T>(_ body: (RSDConnection?, OpaquePointer?) throws -> T) throws -> T {
        let heartbeat = HeartbeatManager.shared
        guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
            throw IDeviceSwiftError(message: "Pair this device in Installation settings before managing apps.")
        }
        let connection = heartbeat.isRsd ? try heartbeat.acquireRSDConnection() : nil
        defer { withExtendedLifetime(connection) {} }
        let provider = connection == nil ? try makeLegacyProvider(heartbeat) : nil
        defer { idevice_provider_free(provider) }
        try checkCancellation()
        return try body(connection, provider)
    }

    private func withInstallationClient<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try withDeviceConnection { connection, provider in
            var proxy: OpaquePointer?
            defer { installation_proxy_client_free(proxy) }
            if let connection {
                try connection.withServiceConnection { adapter, handshake in
                    try check(installation_proxy_connect_rsd(adapter, handshake, &proxy))
                }
            } else {
                try check(installation_proxy_connect(provider, &proxy))
            }
            guard let client = proxy else {
                throw IDeviceSwiftError(message: "Could not reach the device's installer.")
            }
            return try body(client)
        }
    }

    private func withSpringBoardClient<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try withDeviceConnection { connection, provider in
            var sb: OpaquePointer?
            defer { springboard_services_free(sb) }
            if let connection {
                try connection.withServiceConnection { adapter, handshake in
                    try check(springboard_services_connect_rsd(adapter, handshake, &sb))
                }
            } else {
                try check(springboard_services_connect(provider, &sb))
            }
            guard let client = sb else {
                throw IDeviceSwiftError(message: "Could not reach the device's Home Screen service.")
            }
            return try body(client)
        }
    }

    private static func string(_ dict: plist_t, _ key: String) -> String? {
        guard let node = plist_dict_get_item(dict, key), plist_get_node_type(node) == PLIST_STRING else { return nil }
        var raw: UnsafeMutablePointer<CChar>?
        plist_get_string_val(node, &raw)
        guard let raw else { return nil }
        defer { plist_mem_free(raw) }
        return String(cString: raw)
    }

    private static func uint(_ dict: plist_t, _ key: String) -> Int64? {
        guard let node = plist_dict_get_item(dict, key), plist_get_node_type(node) == PLIST_INT else { return nil }
        var value: UInt64 = 0
        plist_get_uint_val(node, &value)
        return Int64(clamping: value)
    }

    /// Reads one app dictionary. Returns nil for anything that isn't a user app we can act on:
    /// system / internal / hidden apps, and Apple's own built-in bundles.
    private static func deviceApp(from info: plist_t) -> DeviceApp? {
        guard let bundleID = string(info, "CFBundleIdentifier") else { return nil }
        if let type = string(info, "ApplicationType"), type != "User" { return nil }
        // App Store (and TestFlight) apps carry Apple's own signature and are FairPlay-encrypted.
        let signer = string(info, "SignerIdentity") ?? ""
        let store = signer.hasPrefix("Apple iPhone OS Application Signing") || plist_dict_get_item(info, "ApplicationDSID") != nil
        if bundleID.hasPrefix("com.apple.") && !store { return nil }
        let name = string(info, "CFBundleDisplayName") ?? string(info, "CFBundleName") ?? bundleID
        let version = string(info, "CFBundleShortVersionString") ?? string(info, "CFBundleVersion") ?? ""
        let fixed = uint(info, "StaticDiskUsage"), dynamic = uint(info, "DynamicDiskUsage")
        let size: Int64? = (fixed == nil && dynamic == nil) ? nil : (fixed ?? 0) + (dynamic ?? 0)
        return DeviceApp(bundleID: bundleID, name: name, version: version, isAppStore: store, sizeBytes: size)
    }

    /// Apps the user installed (never system apps), with their size on disk, sorted by name.
    public func listUserApps() async throws -> [DeviceApp] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await IDeviceInstallationWorker.performInstallation { [self] in
                try withInstallationClient { client -> [DeviceApp] in
                    var apps = try browseUserApps(client)
                    if apps == nil { apps = try getUserApps(client) }   // older installd: no ReturnAttributes
                    return (apps ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
            }
        } onCancel: { [cancellation] in cancellation.cancel() }
    }

    /// Browse with only the attributes we use (a fraction of the payload of a full lookup). nil = not supported.
    private func browseUserApps(_ client: OpaquePointer) throws -> [DeviceApp]? {
        let options = plist_new_dict()
        defer { plist_free(options) }
        plist_dict_set_item(options, "ApplicationType", plist_new_string("User"))
        let attributes = plist_new_array()
        for key in ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString", "CFBundleVersion",
                    "ApplicationType", "SignerIdentity", "ApplicationDSID", "StaticDiskUsage", "DynamicDiskUsage"] {
            plist_array_append_item(attributes, plist_new_string(key))
        }
        plist_dict_set_item(options, "ReturnAttributes", attributes)
        var nodes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
        var count = 0
        if let error = installation_proxy_browse(client, options, &nodes, &count) {
            idevice_error_free(error)
            try checkCancellation()
            return nil
        }
        guard let nodes, count > 0 else { return [] }
        defer { idevice_plist_array_free(nodes, UInt(count)) }
        return (0..<count).compactMap { nodes[$0].flatMap { Self.deviceApp(from: $0) } }
    }

    private func getUserApps(_ client: OpaquePointer) throws -> [DeviceApp] {
        var raw: UnsafeMutableRawPointer?
        var count = 0
        try check(installation_proxy_get_apps(client, "User", nil, 0, &raw, &count))
        guard let raw, count > 0 else { return [] }
        let nodes = raw.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        defer { idevice_plist_array_free(nodes, UInt(count)) }
        return (0..<count).compactMap { nodes[$0].flatMap { Self.deviceApp(from: $0) } }
    }

    /// Removes IPAs left in the device's /PublicStaging by uploads that never finished (for example when AirShare was
    /// killed mid-install). Only call while no install is running.
    public func cleanStaging() async throws -> (removed: Int, bytes: Int64) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await IDeviceInstallationWorker.performInstallation { [self] in
                try withDeviceConnection { connection, provider -> (removed: Int, bytes: Int64) in
                    var afc: OpaquePointer?
                    defer { afc_client_free(afc) }
                    if let connection {
                        try connection.withServiceConnection { adapter, handshake in
                            try check(afc_client_connect_rsd(adapter, handshake, &afc))
                        }
                    } else {
                        try check(afc_client_connect(provider, &afc))
                    }
                    var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                    var count = 0
                    if let error = afc_list_directory(afc, "/PublicStaging", &entries, &count) {
                        idevice_error_free(error)       // no staging folder: nothing to clean
                        return (0, 0)
                    }
                    guard let entries, count > 0 else { return (0, 0) }
                    var removed = 0
                    var bytes: Int64 = 0
                    for index in 0..<count {
                        guard let entry = entries[index] else { continue }
                        defer { idevice_string_free(entry) }
                        let name = String(cString: entry)
                        guard name.lowercased().hasSuffix(".ipa") else { continue }
                        try checkCancellation()
                        let path = "/PublicStaging/\(name)"
                        var info = AfcFileInfo()
                        if afc_get_file_info(afc, path, &info) == nil {
                            bytes += Int64(info.size)
                            afc_file_info_free(&info)
                        }
                        if let error = afc_remove_path(afc, path) { idevice_error_free(error) } else { removed += 1 }
                    }
                    return (removed, bytes)
                }
            }
        } onCancel: { [cancellation] in cancellation.cancel() }
    }

    /// Home Screen icons (PNG) for the given apps, best effort: an app whose icon can't be read is skipped.
    public func icons(for bundleIDs: [String]) async -> [String: Data] {
        guard !bundleIDs.isEmpty else { return [:] }
        return (try? await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await IDeviceInstallationWorker.performInstallation { [self] in
                try withSpringBoardClient { client -> [String: Data] in
                    var out: [String: Data] = [:]
                    for id in bundleIDs {
                        try checkCancellation()
                        var raw: UnsafeMutableRawPointer?
                        var length = 0
                        if let error = springboard_services_get_icon(client, id, &raw, &length) {
                            idevice_error_free(error)
                            continue   // per-app failure: skip
                        }
                        guard let raw, length > 0 else { continue }
                        let bytes = raw.assumingMemoryBound(to: UInt8.self)
                        out[id] = Data(bytes: bytes, count: length)
                        idevice_data_free(bytes, UInt(length))
                    }
                    return out
                }
            }
        } onCancel: { [cancellation] in cancellation.cancel() }) ?? [:]
    }

    /// Removes an app (and its data) from the device. `progress` is 0…1 and is called on the main queue.
    public func uninstall(bundleID: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        self.uninstallProgress = progress
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await IDeviceInstallationWorker.performInstallation { [self] in
                try withInstallationClient { client in
                    let context = Unmanaged.passUnretained(self).toOpaque()
                    try check(installation_proxy_uninstall_with_callback(client, bundleID, nil, Self.uninstallCallback, context))
                }
            }
        } onCancel: { [cancellation] in cancellation.cancel() }
        uninstallProgress = nil
        progress(1)
    }

    private static let uninstallCallback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { value, context in
        guard let context else { return }
        let operation = Unmanaged<InstallationProxy>.fromOpaque(context).takeUnretainedValue()
        guard let report = operation.uninstallProgress else { return }
        let fraction = min(1, Double(value) / 100)
        DispatchQueue.main.async { report(fraction) }
    }
}
