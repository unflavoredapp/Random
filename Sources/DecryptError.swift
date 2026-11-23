//
// Brand: AppAssassin · https://fastdecrypt.ai
//  DecryptError.swift
//  Shared LocalizedError used by host decrypt UI and lean DecryptHelper.
//

import Foundation

struct DecryptError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
