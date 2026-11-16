//
// Brand: Tetherless · https://tetherless.dev
//  IPadnInstallationSettings.swift
//  English Installation Settings — iPadn InstallationSettingsView structure (GPL-2.0),
//  wired to TetherLess NativeInstaller / DeviceInstallationManager / OTA / certificates.
//

import SwiftUI
import UniformTypeIdentifiers

struct IPadnInstallationSettingsView: View {
    private enum Method: String, CaseIterable, Identifiable {
        case automatic, native, certificate, proxy
        var id: String { rawValue }
        var shortTitle: String {
            switch self {
            case .automatic: return "One-tap"
            case .native: return "Native"
            case .certificate: return "Certificate"
            case .proxy: return "Proxy"
            }
        }
    }

    @AppStorage(NativeInstaller.methodKey) private var methodKey = "ota"
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @State private var selected: Method = .automatic
    @State private var issue: String?
    @State private var busy = false
    @State private var importingPairing = false
    @State private var checkMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Install method", selection: $selected) {
                    ForEach(Method.allCases) { m in
                        Text(m.shortTitle).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selected) { apply($0) }
            }

            switch selected {
            case .automatic:
                Section {
                    Label("No profile or certificate needed", systemImage: "checkmark.seal")
                    Label("The package never leaves this device", systemImage: "iphone")
                } header: {
                    Text("One-tap install (recommended)")
                } footer: {
                    Text("Uses TetherLess OTA (`*.tetherless.dev`). Stay in the app until install finishes.")
                }

            case .native:
                Section {
                    Label("The App Store recognizes and updates installed apps", systemImage: "checkmark.seal")
                    Label("Can replace App Store apps and keep their data", systemImage: "arrow.triangle.2.circlepath")
                    LabeledContent(
                        "Pairing File",
                        value: DevicePairingStore.hasSavedPairing ? "Imported" : "Not imported"
                    )
                    NavigationLink {
                        PairHomeView()
                    } label: {
                        Label(
                            DevicePairingStore.hasSavedPairing ? "Pair Again" : "Pair on This Device",
                            systemImage: "iphone.radiowaves.left.and.right"
                        )
                    }
                    Button {
                        importingPairing = true
                    } label: {
                        Label("Import Pairing File", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        Task { await checkConnection() }
                    } label: {
                        HStack {
                            Label("Check Connection", systemImage: "point.3.connected.trianglepath.dotted")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || !DevicePairingStore.hasSavedPairing)
                    if DevicePairingStore.hasSavedPairing {
                        Button(role: .destructive) {
                            Task {
                                await manager.resetPairing()
                                checkMessage = "Pairing file removed."
                            }
                        } label: {
                            Label("Remove Pairing File", systemImage: "trash")
                        }
                    }
                    if let checkMessage {
                        Text(checkMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Native Install")
                } footer: {
                    Text("Installs through the system installation service — same result as installing from a computer.\n1. Tap Pair on This Device, then enable Developer Mode if prompted and enter the pairing code.\n2. Connect the built-in VPN before installing.\nRe-pair after changing the lock-screen passcode or restoring the device. Packages stay on this device.")
                }

            case .certificate:
                Section {
                    Label("Use your own signing certificate for OTA installs", systemImage: "lock.shield")
                    Label("Import a .p12 + mobileprovision via Custom Certificate when available", systemImage: "doc.badge.gearshape")
                } header: {
                    Text("Local certificate")
                } footer: {
                    Text("Create or import a certificate, install the profile, then trust it under Settings › General › About › Certificate Trust Settings.")
                }

            case .proxy:
                Section {
                    Label("Custom OTA / TrustCore domain", systemImage: "network")
                    Label("Point install manifests at your proxy host when using Surge, Loon, or a custom domain", systemImage: "link")
                } header: {
                    Text("Proxy service")
                } footer: {
                    Text("For setups that already route install manifests through Surge, Loon, or a custom domain.")
                }
            }

            Section {
                if let url = URL(string: "https://github.com/mengangs/ipadn") {
                    Link("Installation help", destination: url)
                }
            }
        }
        .navigationTitle("Installation settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { selected = currentMethod() }
        .fileImporter(
            isPresented: $importingPairing,
            allowedContentTypes: [.propertyList, .xml, .data, .item],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                _ = try Data(contentsOf: url)
                Task { @MainActor in
                    await manager.setUp()
                    checkMessage = "Selected pairing file. Finish pairing under Pair if needed."
                }
            } catch {
                issue = error.localizedDescription
            }
        }
        .alert("Installation settings", isPresented: Binding(
            get: { issue != nil },
            set: { if !$0 { issue = nil } }
        )) {
            Button("OK", role: .cancel) { issue = nil }
        } message: {
            Text(issue ?? "")
        }
    }

    private func currentMethod() -> Method {
        if methodKey == "native" { return .native }
        return .automatic
    }

    private func apply(_ method: Method) {
        switch method {
        case .automatic, .certificate, .proxy:
            methodKey = "ota"
        case .native:
            methodKey = "native"
        }
    }

    private func checkConnection() async {
        busy = true
        defer { busy = false }
        guard DevicePairingStore.hasSavedPairing else {
            checkMessage = "Import or create a pairing file first."
            return
        }
        await manager.setUp()
        if NativeInstaller.isSelected, DevicePairingStore.hasSavedPairing {
            checkMessage = "Connected. Native Install is ready."
        } else {
            checkMessage = "Pairing is saved. Select Native and connect VPN before installing."
        }
    }

}
