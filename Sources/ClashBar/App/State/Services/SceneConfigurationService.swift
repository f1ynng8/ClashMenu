import Foundation
import Yams

struct SceneDefinition: Equatable {
    struct Triggers: Equatable {
        let ssids: [String]
    }

    struct SceneConfig: Equatable {
        let baseFile: String
        let overrides: [String: Any]

        static func == (lhs: SceneConfig, rhs: SceneConfig) -> Bool {
            lhs.baseFile == rhs.baseFile && NSDictionary(dictionary: lhs.overrides).isEqual(to: rhs.overrides)
        }
    }

    let name: String
    let description: String
    let triggers: Triggers
    let systemProxyEnabled: Bool
    let systemDNS: [String]
    let action: SceneAction
    let config: SceneConfig?

    func matches(ssid: String?) -> Bool {
        if let ssid {
            if self.triggers.ssids.contains(ssid) {
                return true
            }
        }
        return self.triggers.ssids.contains("*")
    }
}

enum SceneConfigurationError: LocalizedError {
    case invalidRoot
    case missingScenes
    case invalidScene(index: Int, reason: String)
    case duplicateSceneName(String)
    case invalidConfig(String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            "Scene YAML root must be a dictionary."
        case .missingScenes:
            "Scene YAML is missing a non-empty scenes array."
        case let .invalidScene(index, reason):
            "Invalid scene at index \(index): \(reason)"
        case let .duplicateSceneName(name):
            "Duplicate scene name: \(name)"
        case let .invalidConfig(reason):
            reason
        }
    }
}

struct SceneConfigurationService {
    func loadScenes(from url: URL) throws -> [SceneDefinition] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try self.loadScenes(fromYAML: raw)
    }

    func loadScenes(fromYAML raw: String) throws -> [SceneDefinition] {
        guard let root = try Yams.load(yaml: raw) as? [String: Any] else {
            throw SceneConfigurationError.invalidRoot
        }
        guard let sceneItems = root["scenes"] as? [Any], !sceneItems.isEmpty else {
            throw SceneConfigurationError.missingScenes
        }

        var names = Set<String>()
        var scenes: [SceneDefinition] = []
        for (index, item) in sceneItems.enumerated() {
            guard let dict = item as? [String: Any] else {
                throw SceneConfigurationError.invalidScene(index: index, reason: "scene must be a dictionary")
            }
            let scene = try self.parseScene(dict, index: index)
            guard names.insert(scene.name).inserted else {
                throw SceneConfigurationError.duplicateSceneName(scene.name)
            }
            scenes.append(scene)
        }
        return scenes
    }

    func buildRuntimeConfig(baseURL: URL, overrides: [String: Any], outputURL: URL) throws {
        let baseRaw = try String(contentsOf: baseURL, encoding: .utf8)
        let loaded = try Yams.load(yaml: baseRaw)
        guard let baseRoot = loaded as? [String: Any] else {
            throw SceneConfigurationError.invalidConfig("Base config must be a YAML dictionary: \(baseURL.lastPathComponent)")
        }

        let merged = try self.mergeRootConfig(base: baseRoot, overrides: overrides)
        let dumped = try Yams.dump(object: merged, indent: 2, width: -1, allowUnicode: true, sortKeys: false)
        try dumped.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private func parseScene(_ dict: [String: Any], index: Int) throws -> SceneDefinition {
        guard let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else {
            throw SceneConfigurationError.invalidScene(index: index, reason: "name is required")
        }

        let description = (dict["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let triggersDict = dict["triggers"] as? [String: Any],
              let ssids = triggersDict["ssids"] as? [String],
              !ssids.isEmpty
        else {
            throw SceneConfigurationError.invalidScene(index: index, reason: "triggers.ssids is required")
        }

        let systemProxyEnabled = (dict["system-proxy"] as? Bool) ?? false
        let systemDNS = try self.parseSystemDNS(dict["system-dns"], index: index)
        guard let actionRaw = (dict["action"] as? String)?.lowercased(),
              let action = SceneAction(rawValue: actionRaw)
        else {
            throw SceneConfigurationError.invalidScene(index: index, reason: "action must be start or stop")
        }

        let config: SceneDefinition.SceneConfig?
        if action == .start {
            guard let configDict = dict["config"] as? [String: Any] else {
                throw SceneConfigurationError.invalidScene(index: index, reason: "start scene requires config")
            }
            guard let baseFile = (configDict["base_file"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !baseFile.isEmpty
            else {
                throw SceneConfigurationError.invalidScene(index: index, reason: "config.base_file is required")
            }
            let overrides = configDict["overrides"] as? [String: Any] ?? [:]
            config = SceneDefinition.SceneConfig(baseFile: baseFile, overrides: overrides)
        } else {
            config = nil
        }

        return SceneDefinition(
            name: name,
            description: description,
            triggers: .init(ssids: ssids),
            systemProxyEnabled: systemProxyEnabled,
            systemDNS: systemDNS,
            action: action,
            config: config)
    }

    private func parseSystemDNS(_ value: Any?, index: Int) throws -> [String] {
        guard let value else { return [] }
        guard let rawServers = value as? [String] else {
            throw SceneConfigurationError.invalidScene(index: index, reason: "system-dns must be a string array")
        }

        var seen = Set<String>()
        return rawServers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private func mergeRootConfig(base: [String: Any], overrides: [String: Any]) throws -> [String: Any] {
        var result = base
        for (key, overrideValue) in overrides {
            switch key {
            case "rules":
                if let overrideArray = overrideValue as? [Any], let baseArray = result[key] as? [Any] {
                    result[key] = overrideArray + baseArray
                } else {
                    result[key] = overrideValue
                }
            case "rule-providers", "proxy-providers":
                let baseDict = result[key] as? [String: Any] ?? [:]
                let overrideDict = overrideValue as? [String: Any] ?? [:]
                result[key] = baseDict.merging(overrideDict) { _, new in new }
            case "proxies", "proxy-groups":
                let baseArray = result[key] as? [Any] ?? []
                let overrideArray = overrideValue as? [Any] ?? []
                result[key] = self.mergeNamedObjectArrays(base: baseArray, overrides: overrideArray)
            default:
                result[key] = overrideValue
            }
        }
        return result
    }

    private func mergeNamedObjectArrays(base: [Any], overrides: [Any]) -> [Any] {
        var overrideByName: [String: Any] = [:]
        var overrideOrder: [String] = []
        var unnamedOverrides: [Any] = []

        for item in overrides {
            guard let dict = item as? [String: Any], let name = dict["name"] as? String, !name.isEmpty else {
                unnamedOverrides.append(item)
                continue
            }
            if overrideByName[name] == nil {
                overrideOrder.append(name)
            }
            overrideByName[name] = dict
        }

        var result: [Any] = []
        var consumedNames = Set<String>()

        for item in base {
            guard let dict = item as? [String: Any], let name = dict["name"] as? String, !name.isEmpty else {
                result.append(item)
                continue
            }
            if let replacement = overrideByName[name] {
                result.append(replacement)
                consumedNames.insert(name)
            } else {
                result.append(item)
            }
        }

        for name in overrideOrder where !consumedNames.contains(name) {
            if let value = overrideByName[name] {
                result.append(value)
            }
        }
        result.append(contentsOf: unnamedOverrides)
        return result
    }

}
