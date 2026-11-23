//
// Brand: AppAssassin · https://fastdecrypt.ai
//  DecryptClientStub.swift
//  Minimal DecryptClient surface for DecryptHelper (console status mirror only).
//  The real DecryptClient lives in DecryptView.swift on the host target.
//

import Foundation
import Combine

@MainActor
final class DecryptClient: ObservableObject {
    static let shared = DecryptClient()

    enum Phase: Equatable {
        case idle, queued, running, downloading, done, failed, handedOff
    }

    @Published var phase: Phase = .idle
    @Published var message: String = ""
    @Published var error: String?
    @Published var finishedName: String = ""
    @Published var finished: URL?
    @Published var busy: Bool = false

    private init() {}
}
