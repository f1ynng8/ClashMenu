import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
extension AppState {
    func reloadSceneConfiguration() {
        do {
            try self.workingDirectoryManager.bootstrapDirectories()
        } catch {
            self.sceneDefinitions = []
            self.sceneConfigDisplayName = "-"
            self.sceneStatusMessage = error.localizedDescription
            return
        }

        let configURL = self.resolvedSceneConfigurationURL()
        self.sceneConfigDisplayName = configURL?.lastPathComponent ?? "-"

        guard let configURL else {
            self.sceneDefinitions = []
            self.sceneStatusMessage = nil
            if self.sceneControlMode != .disabled {
                self.activeSceneName = nil
            }
            return
        }

        do {
            let scenes = try self.sceneConfigurationService.loadScenes(from: configURL)
            self.sceneDefinitions = scenes
            self.sceneStatusMessage = nil
            if let manualSceneName = self.manualSceneName,
               !scenes.contains(where: { $0.name == manualSceneName })
            {
                self.manualSceneNameStorage = ""
            }
        } catch {
            self.sceneDefinitions = []
            self.sceneStatusMessage = error.localizedDescription
            self.appendLog(level: "error", message: self.local("场景配置加载失败：\(error.localizedDescription)", "Failed to load scene config: \(error.localizedDescription)"))
        }
    }

    func managedSceneConfigFiles() -> [ManagedConfigFile] {
        guard let configURL = self.resolvedSceneConfigurationURL() else { return [] }
        let hasRemoteSource = self.sceneRemoteConfigURLStorage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        return [
            ManagedConfigFile(
                fileName: configURL.lastPathComponent,
                source: hasRemoteSource ? .subscription : .local),
        ]
    }

    func importSceneConfigurationFile() {
        self.prepareModalWindowPresentation()
        let panel = NSOpenPanel()
        self.configureModalWindow(panel)
        panel.title = self.local("选择场景配置文件", "Select Scene Configuration")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var allowedTypes: [UTType] = []
        if let yamlType = UTType(filenameExtension: "yaml") {
            allowedTypes.append(yamlType)
        }
        if let ymlType = UTType(filenameExtension: "yml"), !allowedTypes.contains(ymlType) {
            allowedTypes.append(ymlType)
        }
        if !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes
        }

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        do {
            let data = try Data(contentsOf: sourceURL)
            let targetURL = try self.sceneConfigurationFileURLForWrite()
            try self.configImportService.writeConfigData(data, to: targetURL)
            self.sceneConfigPathStorage = targetURL.path
            self.sceneRemoteConfigURLStorage = ""
            self.defaults.removeObject(forKey: self.sceneRemoteConfigURLKey)
            self.reloadSceneConfiguration()
            self.scheduleSceneEvaluationIfNeeded(force: true)
            self.appendLog(level: "info", message: self.local("已导入场景配置：\(targetURL.lastPathComponent)", "Imported scene config: \(targetURL.lastPathComponent)"))
        } catch {
            self.appendLog(level: "error", message: self.local("导入场景配置失败：\(error.localizedDescription)", "Failed to import scene config: \(error.localizedDescription)"))
        }
    }

    func importRemoteSceneConfigurationFile() async {
        guard let remoteURL = self.promptSceneRemoteConfigurationURL() else { return }
        guard self.isSupportedRemoteConfigURL(remoteURL) else {
            self.appendLog(
                level: "error",
                message: self.local(
                    "场景订阅链接无效：\(remoteURL.absoluteString)",
                    "Invalid scene subscription URL: \(remoteURL.absoluteString)"))
            return
        }

        do {
            let targetURL = try self.sceneConfigurationFileURLForWrite()
            let userAgent = await self.remoteSubscriptionUserAgent()
            let data = try await self.configImportService.downloadRemoteConfigData(from: remoteURL, userAgent: userAgent)
            try self.configImportService.writeConfigData(data, to: targetURL)
            self.sceneConfigPathStorage = targetURL.path
            self.sceneRemoteConfigURLStorage = remoteURL.absoluteString
            self.reloadSceneConfiguration()
            self.scheduleSceneEvaluationIfNeeded(force: true)
            self.appendLog(
                level: "info",
                message: self.local(
                    "已导入场景订阅：\(targetURL.lastPathComponent)",
                    "Imported remote scene configuration: \(targetURL.lastPathComponent)"))
        } catch {
            self.appendLog(
                level: "error",
                message: self.local(
                    "导入场景订阅失败：\(error.localizedDescription)",
                    "Failed to import remote scene configuration: \(error.localizedDescription)"))
        }
    }

    func updateRemoteSceneConfigurationFile() async {
        guard let remoteURL = URL(string: self.sceneRemoteConfigURLStorage.trimmingCharacters(in: .whitespacesAndNewlines)),
              self.isSupportedRemoteConfigURL(remoteURL)
        else {
            self.appendLog(
                level: "info",
                message: self.local(
                    "当前没有可更新的场景订阅链接。",
                    "No remote scene subscription URL is configured."))
            return
        }

        do {
            let targetURL = try self.sceneConfigurationFileURLForWrite()
            let userAgent = await self.remoteSubscriptionUserAgent()
            let data = try await self.configImportService.downloadRemoteConfigData(from: remoteURL, userAgent: userAgent)
            try self.configImportService.writeConfigData(data, to: targetURL)
            self.sceneConfigPathStorage = targetURL.path
            self.reloadSceneConfiguration()
            self.scheduleSceneEvaluationIfNeeded(force: true)
            self.appendLog(
                level: "info",
                message: self.local(
                    "场景订阅更新成功：\(targetURL.lastPathComponent)",
                    "Scene subscription updated successfully: \(targetURL.lastPathComponent)"))
        } catch {
            self.appendLog(
                level: "error",
                message: self.local(
                    "更新场景订阅失败：\(error.localizedDescription)",
                    "Failed to update scene subscription: \(error.localizedDescription)"))
        }
    }

    func setSceneControlMode(_ mode: SceneControlMode) {
        let previousMode = self.sceneControlMode
        self.sceneControlMode = mode
        switch mode {
        case .disabled:
            self.sceneEvaluationTask?.cancel()
            self.sceneEvaluationTask = nil
            self.activeSceneName = nil
            self.activeSceneSSID = nil
            self.activeSceneRuntimeConfigPath = nil
            self.lastAppliedSceneSignature = nil
        case .automatic:
            self.scheduleSceneEvaluationIfNeeded(force: true)
        case .manual:
            if previousMode == .automatic,
               let activeSceneName = self.activeSceneName,
               self.sceneDefinitions.contains(where: { $0.name == activeSceneName })
            {
                self.manualSceneNameStorage = activeSceneName
                self.sceneEvaluationTask?.cancel()
                self.sceneEvaluationTask = nil
                return
            }

            if self.manualSceneName == nil {
                self.manualSceneNameStorage = self.sceneDefinitions.first?.name ?? ""
            }
            self.scheduleSceneEvaluationIfNeeded(force: true)
        }
    }

    func selectManualScene(named name: String) {
        guard self.sceneDefinitions.contains(where: { $0.name == name }) else { return }
        self.objectWillChange.send()
        self.manualSceneNameStorage = name
        if self.sceneControlMode != .manual {
            self.sceneControlMode = .manual
        }
        self.scheduleSceneEvaluationIfNeeded(force: true)
    }

    func scheduleSceneEvaluationIfNeeded(force: Bool = false) {
        self.sceneEvaluationTask?.cancel()
        guard self.sceneControlMode != .disabled else { return }
        guard !self.sceneDefinitions.isEmpty else { return }

        self.sceneEvaluationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.sceneControlMode == .automatic && self.networkReachabilityStatus == .offline {
                return
            }
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            await self.evaluateAndApplyScene(force: force)
        }
    }

    func evaluateAndApplyScene(force: Bool = false) async {
        guard !self.sceneDefinitions.isEmpty else { return }

        let targetScene: SceneDefinition?
        let ssid: String?

        switch self.sceneControlMode {
        case .disabled:
            return
        case .automatic:
            let resolution = self.wifiNetworkService.resolveCurrentSSID()
            switch resolution {
            case let .connected(resolvedSSID):
                ssid = resolvedSSID
                self.appendLog(
                    level: "info",
                    message: self.local(
                        "场景自动识别：当前 Wi-Fi SSID 为 \(resolvedSSID)。",
                        "Scene auto-detection: current Wi-Fi SSID is \(resolvedSSID)."))
                targetScene = self.sceneDefinitions.first(where: { $0.matches(ssid: resolvedSSID) })
            case .notConnected:
                ssid = nil
                self.appendLog(
                    level: "info",
                    message: self.local(
                        "场景自动识别：当前未连接 Wi-Fi，将按兜底规则匹配。",
                        "Scene auto-detection: not connected to Wi-Fi, falling back to default matching."))
                targetScene = self.sceneDefinitions.first(where: { $0.matches(ssid: nil) })
            case .unavailable:
                self.appendLog(
                    level: "warning",
                    message: self.local(
                        "无法读取当前 Wi‑Fi SSID，已跳过自动场景切换。请检查系统位置服务权限。",
                        "Unable to read current Wi-Fi SSID. Skipped automatic scene switching. Check Location Services permission."))
                return
            }
        case .manual:
            switch self.wifiNetworkService.resolveCurrentSSID() {
            case let .connected(resolvedSSID):
                ssid = resolvedSSID
            case .notConnected, .unavailable:
                ssid = nil
            }
            targetScene = self.sceneDefinitions.first(where: { $0.name == self.manualSceneName })
        }

        guard let targetScene else { return }
        await self.applyScene(targetScene, ssid: ssid, force: force)
    }

    private func applyScene(_ scene: SceneDefinition, ssid: String?, force: Bool) async {
        let signature = "\(self.sceneControlMode.rawValue)|\(scene.name)|\(ssid ?? "-")"
        if !force, self.lastAppliedSceneSignature == signature {
            self.activeSceneName = scene.name
            self.activeSceneSSID = ssid
            return
        }

        if self.isCoreActionProcessing {
            self.appendLog(
                level: "info",
                message: self.local(
                    "场景「\(scene.name)」等待当前核心操作完成后再次应用。",
                    "Scene \"\(scene.name)\" will be applied after the current core action completes."))
            self.scheduleSceneEvaluationIfNeeded(force: true)
            return
        }

        self.lastAppliedSceneSignature = signature
        self.activeSceneName = scene.name
        self.activeSceneSSID = ssid

        let ssidDescription = ssid ?? self.local("未连接 Wi-Fi", "Not connected to Wi-Fi")
        self.appendLog(
            level: "info",
            message: self.local(
                "场景匹配结果：SSID=\(ssidDescription)，命中场景「\(scene.name)」。",
                "Scene match result: SSID=\(ssidDescription), matched scene \"\(scene.name)\"."))

        switch scene.action {
        case .stop:
            self.activeSceneRuntimeConfigPath = nil
            if self.isRuntimeRunning {
                await self.stopCore(trigger: .manual)
            }
            await self.syncSystemProxyForScene(enabled: false)
            await self.syncSystemDNSForScene(serverAddresses: scene.systemDNS)
            self.desiredSystemProxyEnabled = false
            self.shouldAutoResumeManagedRuntime = false
            self.appendLog(level: "info", message: self.local("已应用场景：\(scene.name)，停止内核。", "Applied scene \(scene.name), stopped core."))
        case .start:
            guard let config = scene.config,
                  let baseURL = self.sceneBaseConfigURL(for: config.baseFile)
            else {
                self.appendLog(level: "error", message: self.local("场景 \(scene.name) 的基础配置文件不存在。", "Base config missing for scene \(scene.name)."))
                return
            }

            do {
                try self.sceneConfigurationService.buildRuntimeConfig(
                    baseURL: baseURL,
                    overrides: config.overrides,
                    outputURL: self.workingDirectoryManager.activeSceneConfigURL)
                self.activeSceneRuntimeConfigPath = self.workingDirectoryManager.activeSceneConfigURL.path
                self.configManager.selectConfig(baseURL)
                _ = self.syncSelectedConfigSelection(baseURL)
                self.syncConfigDisplayState()
            } catch {
                self.appendLog(level: "error", message: self.local("生成场景运行时配置失败：\(error.localizedDescription)", "Failed to build scene runtime config: \(error.localizedDescription)"))
                return
            }

            if self.isRuntimeRunning {
                await self.restartCore(trigger: .configSwitch)
            } else {
                await self.startCore(trigger: .manual)
            }

            self.desiredSystemProxyEnabled = scene.systemProxyEnabled
            await self.syncSystemProxyForScene(enabled: scene.systemProxyEnabled)
            await self.syncSystemDNSForScene(serverAddresses: scene.systemDNS)
            self.appendLog(level: "info", message: self.local("已应用场景：\(scene.name)。", "Applied scene \(scene.name)."))
        }
    }

    private func syncSystemProxyForScene(enabled: Bool) async {
        if enabled, self.isRuntimeRunning {
            do {
                let target = try await self.resolveSystemProxyTargetFromRuntimeConfig()
                try await self.applySystemProxy(enabled: true, host: target.host, ports: target.ports)
                self.isSystemProxyEnabled = true
            } catch {
                self.appendLog(level: "error", message: self.tr("log.system_proxy.toggle_failed", self.systemProxyErrorMessage(error)))
                await self.refreshSystemProxyStatus()
            }
            return
        }

        do {
            try await self.applySystemProxy(enabled: false, host: self.controllerHost(), ports: .disabled)
            self.isSystemProxyEnabled = false
        } catch {
            self.appendLog(level: "error", message: self.tr("log.system_proxy.toggle_failed", self.systemProxyErrorMessage(error)))
            await self.refreshSystemProxyStatus()
        }
    }

    private func syncSystemDNSForScene(serverAddresses: [String]) async {
        do {
            try await self.applySystemDNS(serverAddresses: serverAddresses)
            if serverAddresses.isEmpty {
                self.appendLog(
                    level: "info",
                    message: self.local(
                        "已恢复系统自动 DNS。",
                        "Restored automatic system DNS."))
            } else {
                self.appendLog(
                    level: "info",
                    message: self.local(
                        "已应用系统 DNS：\(serverAddresses.joined(separator: ", "))。",
                        "Applied system DNS: \(serverAddresses.joined(separator: ", "))."))
            }
        } catch {
            self.appendLog(
                level: "error",
                message: self.local(
                    "同步系统 DNS 失败：\(error.localizedDescription)",
                    "Failed to sync system DNS: \(error.localizedDescription)"))
        }
    }

    private func resolvedSceneConfigurationURL() -> URL? {
        let stored = self.sceneConfigPathStorage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty {
            let candidate = URL(fileURLWithPath: stored)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let fallback = self.workingDirectoryManager.importedSceneConfigURL
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private func sceneConfigurationFileURLForWrite() throws -> URL {
        try self.workingDirectoryManager.bootstrapDirectories()
        return self.workingDirectoryManager.importedSceneConfigURL
    }

    private func promptSceneRemoteConfigurationURL() -> URL? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = self.local("导入场景订阅链接", "Import Scene Subscription URL")
        alert.informativeText = self.local(
            "请输入场景配置的订阅链接，导入后会保存为固定的 scene.yaml。",
            "Enter the scene configuration subscription URL. It will be saved as a fixed scene.yaml.")
        alert.addButton(withTitle: self.local("导入", "Import"))
        alert.addButton(withTitle: self.local("取消", "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://example.com/scene.yaml"
        field.stringValue = self.sceneRemoteConfigURLStorage.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.accessoryView = field

        self.prepareModalWindowPresentation()
        self.configureModalWindow(alert.window)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let urlText = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remoteURL = URL(string: urlText), !urlText.isEmpty else { return nil }
        return remoteURL
    }

    private func sceneBaseConfigURL(for fileName: String) -> URL? {
        guard let normalized = self.normalizedConfigFileName(fileName), normalized == fileName else { return nil }
        guard let configDirectory = self.ensureConfigDirectoryAvailable() else { return nil }
        let candidate = configDirectory.appendingPathComponent(fileName, isDirectory: false)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
