//
// Brand: Tetherless · https://tetherless.dev
//  FairPlayKeysCaptureSheet.swift
//  Dedicated guided sheet: open App Store / Media & Purchases → return → verify → confirm.
//

import SwiftUI

struct FairPlayKeysCaptureSheet: View {
    @ObservedObject private var store = AppleIDStore.shared
    @ObservedObject private var keys = FairPlayKeysFetcher.shared
    @Environment(\.dismiss) private var dismiss

    private var email: String {
        store.email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    sessionRow
                    stampedLiveInstallCard
                    phaseCard
                    sessionLicensesCard
                    if !keys.verifyLines.isEmpty {
                        verifyList
                    }
                    if let banner = keys.banner {
                        Text(banner)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .background {
                AppBackground()
            }
            .navigationTitle("FairPlay keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if keys.isWaiting || keys.needsConfirm {
                            // Keep in-progress capture; just dismiss the sheet.
                        } else {
                            keys.cancelCapture()
                        }
                        AppNav.shared.presentFairPlayKeysCapture = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        keys.refreshSessionLicenses()
                    } label: {
                        if keys.licensesScanning {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(keys.licensesScanning || email.isEmpty)
                    .accessibilityLabel("Refresh licenses")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            keys.refreshFromAck()
            keys.refreshSessionLicenses()
        }
        // Keep the sheet open after Confirm so keys + live paths stay visible;
        // user closes explicitly (Get / gate can continue underneath).
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Capture keys for companion decrypt", systemImage: "key.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Open-source decryptors (fairplay-decrypt / ipadecrypt) mint a credential only on jailbreak. AppAssassin uses on-device mremap like fouldecrypt/FairPlayed: enroll Media & Purchases for this Apple ID, keep ≥1 App Store app installed, then Confirm.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sessionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(TetherlessPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Active session")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(email.isEmpty ? "Sign in under Account first" : email)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 4)
            if !store.isSignedIn {
                Button("Account") {
                    AppNav.shared.presentFairPlayKeysCapture = false
                    dismiss()
                    AppNav.shared.goStoreLogin()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(TetherlessPalette.accent)
            }
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var stampedLiveInstallCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live install path (FairPlay)", systemImage: "internaldrive")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            if let live = DecryptCompanionHandoff.readLiveInstallPath() {
                Text(live.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !live.bundleID.isEmpty {
                    Text(live.bundleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.45))
                }
            } else {
                Text("None stamped yet. After Get downloads a Store IPA, the live App Store path for that bid appears here.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sessionLicensesCard: some View {
        let licenses = displayedLicenses
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("App Store licenses in session", systemImage: "doc.on.clipboard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                Text(licenseSummary(licenses))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }

            if keys.licensesScanning && licenses.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().tint(TetherlessPalette.accent)
                    Text("Scanning installd for App Store apps…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
            } else if licenses.isEmpty {
                Text("No App Store installs visible yet. Pair Native, install an app under \(email.isEmpty ? "this Apple ID" : email), then refresh.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(licenses.prefix(16)) { entry in
                        licenseRow(entry)
                        if entry.id != licenses.prefix(16).last?.id {
                            Divider().background(Color.white.opacity(0.08))
                        }
                    }
                }
                if licenses.count > 16 {
                    Text("+\(licenses.count - 16) more")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var displayedLicenses: [FairPlayKeysFetcher.LicenseEntry] {
        if !keys.sessionLicenses.isEmpty { return keys.sessionLicenses }
        return keys.lastReadiness.licenses
    }

    private func licenseSummary(_ licenses: [FairPlayKeysFetcher.LicenseEntry]) -> String {
        let sc = licenses.filter(\.hasSCInfo).count
        if licenses.isEmpty { return "0" }
        return "\(licenses.count) · \(sc) SC_Info"
    }

    private func licenseRow(_ entry: FairPlayKeysFetcher.LicenseEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.hasSCInfo ? "checkmark.seal.fill" : "app.badge")
                .font(.body)
                .foregroundStyle(entry.hasSCInfo ? TetherlessPalette.success : .white.opacity(0.35))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(entry.bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if !entry.version.isEmpty {
                        Text("v\(entry.version)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Text(entry.hasSCInfo ? "SC_Info" : "no SC_Info visible")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(entry.hasSCInfo ? TetherlessPalette.success.opacity(0.9) : .white.opacity(0.35))
                    if !entry.installPath.isEmpty {
                        Text(entry.installPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.35))
                            .textSelection(.enabled)
                            .lineLimit(2)
                    } else if !entry.pathTail.isEmpty {
                        Text(entry.pathTail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.28))
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var phaseCard: some View {
        switch keys.phase {
        case .grabbed(_, let at, let readiness):
            successCard(at: at, readiness: readiness)
        case .confirmSignIn(let e, let readiness):
            confirmCard(email: e, readiness: readiness)
        case .verifying, .redirecting, .waitingForReturn:
            waitingCard
        case .needsAccount:
            needsAccountCard
        case .idle:
            idleActions
        }
    }

    private var idleActions: some View {
        VStack(spacing: 10) {
            prerequisitesCard

            Button {
                keys.startFetchFromSession(preferSettings: false)
            } label: {
                Label("1 · Open App Store account", systemImage: "bag.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(TetherlessPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(email.isEmpty)

            Button {
                keys.startFetchFromSession(preferSettings: true)
            } label: {
                Label("1b · Open Media & Purchases", systemImage: "gearshape.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(email.isEmpty)

            Button {
                keys.openSeedAppStoreApp()
            } label: {
                Label("2 · Install a free App Store app", systemImage: "arrow.down.app")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(email.isEmpty)

            Button {
                keys.markGrabbedManually()
            } label: {
                Text("3 · Already signed in — verify & confirm")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(email.isEmpty)
        }
    }

    private var prerequisitesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Checklist (from open-source decryptors)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            checklistRow("App Store / Media & Purchases signed in as session Apple ID")
            checklistRow("≥1 owned App Store app installed on this iPhone")
            checklistRow("Confirm here — companion decrypts via mremap on the live install")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func checklistRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle")
                .font(.caption2.weight(.bold))
                .foregroundStyle(TetherlessPalette.accent)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().tint(TetherlessPalette.accent)
                Text(waitingTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Text(waitingDetail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    keys.startFetchFromSession(preferSettings: false)
                } label: {
                    Text("Reopen App Store")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    keys.startFetchFromSession(preferSettings: true)
                } label: {
                    Text("Media & Purchases")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if case .waitingForReturn = keys.phase {
                Button {
                    keys.markGrabbedManually()
                } label: {
                    Text("I’ve signed in — verify now")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(TetherlessPalette.accent.opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func confirmCard(email: String, readiness: FairPlayKeysFetcher.Readiness) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Confirm key capture", systemImage: "checkmark.shield")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Text(confirmCopy(email: email, readiness: readiness))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            if !readiness.licenses.isEmpty {
                Text(readiness.licenses.prefix(4).map(\.name).joined(separator: " · ")
                     + (readiness.licenses.count > 4 ? " · +\(readiness.licenses.count - 4)" : ""))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
            }

            Button {
                keys.confirmGrabbed()
            } label: {
                Text("Confirm keys for \(email)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(TetherlessPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)

            if readiness.storeApps == 0 {
                Button {
                    keys.openSeedAppStoreApp()
                } label: {
                    Text("Install free TestFlight first (recommended)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }

            Button {
                AppStoreDecryptGuide.openPurchaseHistory()
            } label: {
                Text("Open Purchase History to re-auth")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                keys.startFetchFromSession(preferSettings: true)
            } label: {
                Text("Not yet — open Media & Purchases again")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func confirmCopy(email: String, readiness: FairPlayKeysFetcher.Readiness) -> String {
        if readiness.scInfoHits > 0 {
            return "Saw \(readiness.scInfoHits) SC_Info folder(s) beside \(readiness.storeApps) store install(s). Confirm App Store showed \(email)."
        }
        if readiness.storeApps > 0 {
            return "Found \(readiness.storeApps) App Store install(s). SC_Info may be host-invisible — companion still decrypts from the live path. Confirm if Account Settings showed \(email)."
        }
        return "No App Store installs visible yet (open-source tools require ≥1). Install free TestFlight under \(email), or Confirm if you already signed in and have store apps."
    }

    private func successCard(at: Date, readiness: FairPlayKeysFetcher.Readiness) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Keys grabbed", systemImage: "checkmark.seal.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(TetherlessPalette.success)
            Text(successCopy(readiness))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.62))
            Text(at.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            Button {
                keys.startFetchFromSession()
            } label: {
                Text("Capture again")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(TetherlessPalette.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func successCopy(_ readiness: FairPlayKeysFetcher.Readiness) -> String {
        if readiness.storeApps > 0 || readiness.scInfoHits > 0 {
            return "Ready for companion decrypt · \(readiness.storeApps) store app(s) · \(readiness.scInfoHits) SC_Info."
        }
        return "Ready for companion decrypt. Prefer keeping ≥1 App Store app installed under this Apple ID."
    }

    private var needsAccountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in under Account first")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Text("FairPlay key capture is tied to the Apple ID session in TetherLess.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.62))
            Button {
                AppNav.shared.presentFairPlayKeysCapture = false
                dismiss()
                AppNav.shared.goStoreLogin()
            } label: {
                Text("Open Account")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(TetherlessPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var verifyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(keys.verifyLines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 4)
    }

    private var waitingTitle: String {
        switch keys.phase {
        case .redirecting: return "Opening…"
        case .waitingForReturn: return "Waiting for return…"
        case .verifying: return "Verifying…"
        default: return "Working…"
        }
    }

    private var waitingDetail: String {
        let who = email.isEmpty ? "your Apple ID" : email
        switch keys.phase {
        case .redirecting(_, let dest):
            switch dest {
            case .mediaAndPurchases:
                return "Opening Media & Purchases — sign in with \(who)."
            case .seedApp:
                return "Opening TestFlight — Install with \(who) so this iPhone has ≥1 App Store app."
            case .appStoreAccount:
                return "Opening App Store account — sign in with \(who)."
            }
        case .waitingForReturn(_, let dest):
            if dest == .seedApp {
                return "Install TestFlight (or any free app) while signed in as \(who), then return here."
            }
            return "In App Store, open Account Settings and make sure it shows \(who). Then return here."
        case .verifying:
            return "Checking installd for store apps + SC_Info, then Confirm for \(who)."
        default:
            return keys.banner ?? "Working…"
        }
    }
}
