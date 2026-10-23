//
//  PhoneIcon.swift
//  The iPhone picture from onboarding (asset "iphone_render"), used next to "This device" in the
//  certificate and account screens. Falls back to a drawn iPhone if the asset is missing.
//

import SwiftUI

struct PhoneIcon: View {
    var height: CGFloat = 30

    var body: some View {
        if UIImage(named: "iphone_render") != nil {
            Image("iphone_render").resizable().scaledToFit().frame(height: height)
        } else {
            drawn
        }
    }

    private var drawn: some View {
        let w = height * 0.5
        let r = height * 0.15
        return ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.34), Theme.accent.opacity(0.08)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .stroke(Theme.accent, lineWidth: max(1.2, height * 0.065))
            Capsule().fill(Theme.accent).frame(width: w * 0.36, height: max(1.5, height * 0.05)).offset(y: -height * 0.37)
            Capsule().fill(Theme.accent.opacity(0.65)).frame(width: w * 0.34, height: max(1, height * 0.03)).offset(y: height * 0.40)
        }
        .frame(width: w, height: height)
    }
}
