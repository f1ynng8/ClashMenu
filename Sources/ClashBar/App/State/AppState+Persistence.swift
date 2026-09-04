import Foundation

@MainActor
extension AppState {
    func resolveSelectedConfigPath() async -> String? {
        if self.sceneControlMode != .disabled,
           let sceneConfigPath = self.activeSceneRuntimeConfigPath,
           !sceneConfigPath.isEmpty,
           FileManager.default.fileExists(atPath: sceneConfigPath)
        {
            return sceneConfigPath
        }

        if let selected = configManager.selectedConfig {
            let selectedPath = self.syncSelectedConfigSelection(selected)
            self.syncConfigDisplayState()
            return selectedPath
        }

        if let selectedName = defaults.string(forKey: selectedConfigKey),
           let selected = configManager.availableConfigs.first(where: { $0.lastPathComponent == selectedName })
        {
            configManager.selectConfig(selected)
            let selectedPath = self.syncSelectedConfigSelection(selected)
            self.syncConfigDisplayState()
            return selectedPath
        }

        if let legacySelectedPath = defaults.string(forKey: legacySelectedConfigKey) {
            let legacyName = URL(fileURLWithPath: legacySelectedPath).lastPathComponent
            defaults.set(legacyName, forKey: selectedConfigKey)
            defaults.removeObject(forKey: legacySelectedConfigKey)
            if let selected = configManager.availableConfigs.first(where: { $0.lastPathComponent == legacyName }) {
                configManager.selectConfig(selected)
                let selectedPath = self.syncSelectedConfigSelection(selected)
                self.syncConfigDisplayState()
                return selectedPath
            }
        }

        _ = configManager.reloadConfigs()
        if let selected = configManager.selectedConfig {
            let selectedPath = self.syncSelectedConfigSelection(selected)
            self.syncConfigDisplayState()
            return selectedPath
        }

        return nil
    }

    func restoreSavedConfigDirectory() {
        configManager.setConfigDirectory(workingDirectoryManager.configDirectoryURL)
        if let selected = configManager.selectedConfig {
            _ = self.syncSelectedConfigSelection(selected)
        }
        self.syncConfigDisplayState()
    }

    func restoreLastSuccessfulConfigIfAvailable() {
        guard let lastPath = defaults.string(forKey: lastSuccessfulConfigPathKey), !lastPath.isEmpty else { return }
        let candidate = URL(fileURLWithPath: lastPath)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return }
        guard let matched = configManager.availableConfigs.first(where: {
            $0.standardizedFileURL.resolvingSymlinksInPath().path == candidate.standardizedFileURL
                .resolvingSymlinksInPath().path
        }) else {
            return
        }
        configManager.selectConfig(matched)
        _ = self.syncSelectedConfigSelection(matched)
        self.syncConfigDisplayState()
    }

    func syncConfigDisplayState() {
        configDirectoryPath = configManager.configDirectory?.path ?? "-"
        availableConfigFileNames = configManager.availableConfigs.map(\.lastPathComponent)
        if selectedConfigName == "-", let first = availableConfigFileNames.first {
            selectedConfigName = first
        }
        self.pruneRemoteConfigSourcesIfNeeded()
    }

    func ensureAPIClient() {
        if let apiClient {
            apiClient.updateCredentials(controller: controller, secret: controllerSecret)
        } else {
            apiClient = MihomoAPIClient(controller: controller, secret: controllerSecret)
        }
    }

    func clearLegacyTunPreferences() {
        defaults.removeObject(forKey: legacyDesiredTunEnabledKey)
        defaults.removeObject(forKey: legacyEditableSettingsSnapshotKey)
    }

    func loadPersistedUILanguage() -> AppLanguage {
        if let raw = defaults.string(forKey: uiLanguageKey),
           let language = AppLanguage(rawValue: raw)
        {
            return language
        }
        defaults.set(AppLanguage.zhHans.rawValue, forKey: uiLanguageKey)
        return .zhHans
    }

    func loadPersistedAppearanceMode() -> AppAppearanceMode {
        if let raw = defaults.string(forKey: appearanceModeKey),
           let mode = AppAppearanceMode(rawValue: raw)
        {
            return mode
        }
        defaults.set(AppAppearanceMode.system.rawValue, forKey: appearanceModeKey)
        return .system
    }

    func loadPersistedRemoteConfigSources() -> [String: String] {
        guard let stored = defaults.dictionary(forKey: remoteConfigSourcesKey) as? [String: String] else {
            return [:]
        }

        var result: [String: String] = [:]
        for (fileName, urlString) in stored {
            guard let normalizedName = normalizedConfigFileName(fileName), normalizedName == fileName else { continue }
            guard let url = URL(string: urlString), isSupportedRemoteConfigURL(url) else { continue }
            result[normalizedName] = url.absoluteString
        }
        return result
    }

    func persistRemoteConfigSources() {
        if remoteConfigSources.isEmpty {
            defaults.removeObject(forKey: remoteConfigSourcesKey)
        } else {
            defaults.set(remoteConfigSources, forKey: remoteConfigSourcesKey)
        }
    }

    func pruneRemoteConfigSourcesIfNeeded() {
        let availableNames = Set(availableConfigFileNames)
        let filtered = remoteConfigSources.filter { availableNames.contains($0.key) }
        guard filtered != remoteConfigSources else { return }
        remoteConfigSources = filtered
        self.persistRemoteConfigSources()
    }
}
