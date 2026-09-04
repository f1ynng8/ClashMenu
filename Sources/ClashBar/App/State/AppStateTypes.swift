import Foundation

enum RuntimeVisualStatus {
    case stopped
    case starting
    case runningHealthy
    case runningDegraded
    case failed
}

enum SceneControlMode: String, CaseIterable {
    case disabled
    case automatic
    case manual
}

enum SceneAction: String {
    case start
    case stop
}

enum ManagedConfigSource: Equatable {
    case local
    case subscription
}

struct ManagedConfigFile {
    let fileName: String
    let source: ManagedConfigSource
}

enum StartTrigger {
    case manual
    case auto
    case networkRecovery
    case systemWakeRecovery
}

enum StopTrigger {
    case manual
    case networkLoss
    case systemSleep
}

enum RuntimeStopReason: Hashable {
    case manual
    case networkLoss
    case systemSleep
}

enum CoreActionState {
    case idle
    case starting
    case stopping
    case restarting
}

enum CoreUpgradeResult: Equatable {
    case updated(version: String?)
    case alreadyLatest(version: String?)
    case failed(message: String)
}

enum ConfigPatchValue: Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)
    indirect case object([String: ConfigPatchValue])

    var jsonValue: JSONValue {
        switch self {
        case let .bool(value):
            .bool(value)
        case let .int(value):
            .int(value)
        case let .string(value):
            .string(value)
        case let .object(value):
            .object(value.mapValues(\.jsonValue))
        }
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }
}

enum ProviderRefreshTrigger {
    case start
    case restart
    case configSwitch
}

enum ProviderRefreshPhase {
    case idle
    case updating
    case succeeded
    case failed
    case cancelled
}

struct ProviderRefreshStatus {
    let phase: ProviderRefreshPhase
    let trigger: ProviderRefreshTrigger?
    let progressDone: Int
    let progressTotal: Int
    let message: String?
    let updatedAt: Date?

    static let idle = ProviderRefreshStatus(
        phase: .idle,
        trigger: nil,
        progressDone: 0,
        progressTotal: 0,
        message: nil,
        updatedAt: nil)
}

struct ProviderNodeKey: Hashable {
    let provider: String
    let node: String
}

struct MenuBarDisplay: Equatable {
    let symbolName: String
    let brandIconState: BrandIconState
}

struct CoreFeatureRecoveryState {
    let systemProxyEnabled: Bool

    var shouldRecoverAnyFeature: Bool {
        self.systemProxyEnabled
    }
}

struct SystemProxyPorts: Equatable, Sendable {
    let httpPort: Int?
    let httpsPort: Int?
    let socksPort: Int?

    static let disabled = SystemProxyPorts(httpPort: nil, httpsPort: nil, socksPort: nil)

    var hasEnabledPort: Bool {
        self.httpPort != nil || self.httpsPort != nil || self.socksPort != nil
    }

    var primaryPort: Int? {
        self.httpPort ?? self.httpsPort ?? self.socksPort
    }
}
