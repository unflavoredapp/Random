//
//  AppleAuthModels.swift
//  Real GrandSlam / Developer Portal models (no mocks).
//

import Foundation

struct AppleAuthSession: Codable, Equatable, Sendable {
    var dsid: String
    var authToken: String
    var email: String
    var anisette: AnisetteHeaders
    var createdAt: Date
    var expiresAt: Date?
    var timeToLive: TimeInterval?
    var teamID: String?
    var teamName: String?
    var isFreeTeam: Bool
    var xcodeVersion: String

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    init(
        dsid: String,
        authToken: String,
        email: String,
        anisette: AnisetteHeaders,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        timeToLive: TimeInterval? = nil,
        teamID: String? = nil,
        teamName: String? = nil,
        isFreeTeam: Bool = true,
        xcodeVersion: String = "14.0"
    ) {
        self.dsid = dsid
        self.authToken = authToken
        self.email = email
        self.anisette = anisette
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.timeToLive = timeToLive
        self.teamID = teamID
        self.teamName = teamName
        self.isFreeTeam = isFreeTeam
        self.xcodeVersion = xcodeVersion
    }
}

struct Team: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var isFree: Bool

    var teamId: String { id }

    init(teamId: String, name: String, isFree: Bool) {
        self.id = teamId
        self.name = name
        self.isFree = isFree
    }

    init(id: String, name: String, isFree: Bool) {
        self.id = id
        self.name = name
        self.isFree = isFree
    }
}

typealias DevTeam = Team

struct DevCertificate: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var serialNumber: String
    var expires: Date?
    var machineName: String?
    var certificateData: Data?

    init(
        id: String,
        name: String,
        serialNumber: String,
        expires: Date? = nil,
        machineName: String? = nil,
        certificateData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.serialNumber = serialNumber
        self.expires = expires
        self.machineName = machineName
        self.certificateData = certificateData
    }
}

struct DevDevice: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var udid: String
    var model: String?
    var status: String?

    init(id: String, name: String, udid: String, model: String? = nil, status: String? = nil) {
        self.id = id
        self.name = name
        self.udid = udid
        self.model = model
        self.status = status
    }
}

struct DevAppID: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var bundleID: String
}

struct DevProvisioningProfile: Sendable {
    var id: String?
    var name: String
    var data: Data
}

enum AppleAuthError: LocalizedError, Sendable {
    case message(String)
    case incorrectCredentials
    case incorrectCode
    case needsTwoFactor
    case appSpecificPasswordRequired
    case tooManyAttempts(String)
    case accountRepairRequired(String)
    case network(String)
    case portal(Int, String)
    case csrFailed(String)
    case missingPendingAuth

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .incorrectCredentials: return "Incorrect Apple ID or password."
        case .incorrectCode: return "Incorrect verification code."
        case .needsTwoFactor: return "Two-factor authentication required."
        case .appSpecificPasswordRequired: return "An app-specific password is required."
        case .tooManyAttempts(let m): return m
        case .accountRepairRequired(let m): return m
        case .network(let m): return m
        case .portal(let c, let m): return "Developer Portal error \(c): \(m)"
        case .csrFailed(let m): return "CSR generation failed: \(m)"
        case .missingPendingAuth: return "Start Apple ID sign-in again."
        }
    }
}

enum TwoFactorPending: Equatable, Sendable {
    case trustedDevice
    case sms(phoneID: String)
}
