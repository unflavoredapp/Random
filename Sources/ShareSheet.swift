//
// Brand: AppAssassin · https://fastdecrypt.ai
//  ShareSheet.swift
//  UIActivityViewController bridge for the host SwiftUI path.
//  DecryptHelper presents UIActivityViewController directly (UIKit).
//

#if !DECRYPT_HELPER
import SwiftUI

/// UIActivityViewController bridge (share a single file).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif
