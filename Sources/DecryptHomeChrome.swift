//
//  DecryptHomeChrome.swift
//  Lightweight TetherLess-style header for the Decrypt tab (hero + setup card).
//  The existing DecryptView search/backend stays underneath.
//

import SwiftUI

/// Soft chrome wrapper: gradient-friendly title row matching the Decrypt screenshot.
struct DecryptChromeHeader: View {
    var onSettings: (() -> Void)?

    var body: some View {
        HStack(alignment: .center) {
            Text("Decrypt")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            if let onSettings {
                Button(action: onSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
