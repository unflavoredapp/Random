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
                    phaseCard
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
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { keys.refreshFromAck() }
        .onChange(of: keys.phase) { phase in
            if case .grabbed = phase {
                // Auto-dismiss shortly after success so decrypt can continue.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    AppNav.shared.presentFairPlayKeysCapture = false
                    dismiss()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Capture keys for companion decrypt", systemImage: "key.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("iOS only stores FairPlay keys after a real App Store / Media & Purchases sign-in. TetherLess cannot mint them from the Store login token.")
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

    @ViewBuilder
    private var phaseCard: some View {
        switch keys.phase {
        case .grabbed(_, let at, let hints):
            successCard(at: at, hints: hints)
        case .confirmSignIn(let e, let hints):
            confirmCard(email: e, hints: hints)
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
            Button {
                keys.startFetchFromSession(preferSettings: false)
            } label: {
                Label("Open App Store account", systemImage: "bag.fill")
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
                Label("Open Media & Purchases", systemImage: "gearshape.fill")
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
                Text("Already signed in — verify & confirm")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(email.isEmpty)
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

    private func confirmCard(email: String, hints: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Confirm key capture", systemImage: "checkmark.shield")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Text(hints > 0
                 ? "Saw \(hints) App Store license folder(s). Tap Confirm if App Store showed \(email)."
                 : "TetherLess often can’t see SC_Info from the sandbox — that doesn’t mean sign-in failed. If App Store Account Settings showed \(email), tap Confirm.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

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

    private func successCard(at: Date, hints: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Keys grabbed", systemImage: "checkmark.seal.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(TetherlessPalette.success)
            Text(hints > 0
                 ? "Ready for companion decrypt · \(hints) license folder(s) seen."
                 : "Ready for companion decrypt.")
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
            return dest == .mediaAndPurchases
                ? "Opening Media & Purchases — sign in with \(who)."
                : "Opening App Store account — sign in with \(who)."
        case .waitingForReturn:
            return "In App Store, open Account Settings and make sure it shows \(who). Then return here and Confirm — don’t worry if the license scan is empty."
        case .verifying:
            return "Wrapping up — next step is Confirm keys for \(who)."
        default:
            return keys.banner ?? "Working…"
        }
    }
}
