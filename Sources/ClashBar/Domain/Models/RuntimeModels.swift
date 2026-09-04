import Foundation

enum APIHealth: String, Codable {
    case unknown
    case healthy
    case degraded
    case failed
}

enum CoreMode: String, Codable {
    case rule
    case global
    case direct
}

struct VersionInfo: Codable, Equatable {
    let version: String
}

struct CoreUpgradeResponse: Decodable, Equatable {
    let status: String?
    let message: String?
}
