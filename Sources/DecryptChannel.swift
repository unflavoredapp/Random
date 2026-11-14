//
//  DecryptChannel.swift
//  Device FairPlay vs Telegram bot (@FastDecryptBot via server bridge).
//

import Foundation
import SwiftUI

enum DecryptChannel: String, CaseIterable, Identifiable {
    case device
    case telegram

    var id: String { rawValue }

    var title: String {
        switch self {
        case .device: return "This Device"
        case .telegram: return "Telegram Bot"
        }
    }

    var icon: String {
        switch self {
        case .device: return "iphone"
        case .telegram: return "paperplane.fill"
        }
    }

    var blurb: String {
        switch self {
        case .device:
            return "FairPlay decrypt with this iPhone’s App Store keys (mremap). Opens the App Store for your Apple ID if the app isn’t installed yet — no Telegram."
        case .telegram:
            return "Queue through the server’s Telegram bridge to @FastDecryptBot. Works for App Store links you don’t have installed locally."
        }
    }

    static var current: DecryptChannel {
        get {
            let raw = UserDefaults.standard.string(forKey: "uzd_decrypt_channel") ?? DecryptChannel.device.rawValue
            return DecryptChannel(rawValue: raw) ?? .device
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "uzd_decrypt_channel") }
    }
}

struct DecryptChannelPicker: View {
    @AppStorage("uzd_decrypt_channel") private var channelRaw = DecryptChannel.device.rawValue

    private var channel: DecryptChannel {
        DecryptChannel(rawValue: channelRaw) ?? .device
    }

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("DECRYPT METHOD")
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(1.1)
                    .foregroundStyle(.white.opacity(0.45))

                HStack(spacing: 8) {
                    ForEach(DecryptChannel.allCases) { c in
                        let on = channel == c
                        Button {
                            channelRaw = c.rawValue
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: c.icon)
                                    .font(.system(size: 12, weight: .bold))
                                Text(c.title)
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundStyle(on ? .white : .white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(on ? TetherlessPalette.accent : Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(channel.blurb)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
