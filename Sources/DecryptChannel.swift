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
            return "All in one: silent App Store purchase/download when possible, then FairPlay decrypt inside TetherLess with this iPhone’s keys (mremap). No helper app — falls back to App Store install only if needed."
        case .telegram:
            return "Optional remote path via the server’s Telegram bridge to @FastDecryptBot. Not required for normal device decrypt."
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
