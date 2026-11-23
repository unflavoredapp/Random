//
// Brand: AppAssassin · https://fastdecrypt.ai
//  DecryptHelperApp.swift
//  Lean FastDecryptBot shell — FairPlay + companion console only.
//  Embedded into the host app and cloned by DecryptCompanionPackager
//  instead of the ~45 MB host Mach-O (Tetherless-style DecryptHelper).
//

import SwiftUI

@main
struct DecryptHelperApp: App {
    var body: some Scene {
        WindowGroup {
            DecryptCompanionRoot()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .preferredColorScheme(.dark)
        }
    }
}
