import AppKit
import Foundation

@MainActor
extension AppState {
    private struct CoreBootstrapOptions {
        let providerTrigger: ProviderRefreshTrigger
        let refreshProxyGroupsAfterBootstrap: Bool
        let refreshSystemProxyBeforeBootstrap: Bool
        let refreshSystemProxyAfterBootstrap: Bool
    }

    func startCore(trigger: StartTrigger = .manual) async {
        guard !isCoreActionProcessing else { return }
        if trigger == .manual {
            self.runtimeStopReasons.remove(.manual)
            self.shouldAutoResumeManagedRuntime = false
        }
        coreActionState = .starting
        defer { coreActionState = .idle }
        do {
            guard let configPath = await resolveSelectedConfigPath() else {
                let message = tr("log.start.no_config")
                appendLog(level: "error", message: message)
                self.presentCoreFailureAlert(
                    title: self.tr("app.core.alert.start_failed.title"),
                    message: message,
                    dedupeKey: "core-start-failed")
                if trigger == .auto {
                    startupErrorMessage = message
                    statusText = "Stopped"
                    apiStatus = .unknown
                }
                return
            }

            try await ensureTunPermissionsForConfigStartup(configPath: configPath)

            guard await self.validateConfigBeforeCoreLaunch(configPath: configPath) else {
                if trigger == .auto {
                    let fileName = URL(fileURLWithPath: configPath).lastPathComponent
                    startupErrorMessage = tr("app.config.validation_failed.startup", fileName)
                    statusText = "Stopped"
                    apiStatus = .unknown
                } else {
                    statusText = "Failed"
                    apiStatus = .failed
                }
                return
            }

            let launchController = applyExternalControllerFromSelectedConfigFile(configPath: configPath)
            statusText = "Starting"
            _ = try await processManager.startAsync(configPath: configPath, controller: launchController)

            await self.completeCoreBootstrap(
                configPath: configPath,
                options: CoreBootstrapOptions(
                    providerTrigger: .start,
                    refreshProxyGroupsAfterBootstrap: false,
                    refreshSystemProxyBeforeBootstrap: true,
                    refreshSystemProxyAfterBootstrap: false))
            self.handleSuccessfulCoreStart(trigger: trigger)
            self.shouldRestoreCoreOnLaunch = true
        } catch {
            let errorMessage = self.coreErrorMessage(error)
            let message = tr("log.start.failed", errorMessage)
            appendLog(level: "error", message: message)
            self.presentCoreFailureAlert(
                title: self.tr("app.core.alert.start_failed.title"),
                message: message,
                dedupeKey: "core-start-failed")
            if trigger == .auto {
                statusText = "Stopped"
                apiStatus = .unknown
                startupErrorMessage = message
            } else {
                statusText = "Failed"
                apiStatus = .failed
            }
        }
    }

    func stopCore(trigger: StopTrigger = .manual) async {
        guard !isCoreActionProcessing else { return }
        if trigger == .manual {
            self.runtimeStopReasons.insert(.manual)
            self.shouldAutoResumeManagedRuntime = false
            self.shouldRestoreCoreOnLaunch = false
        }
        let recoverySnapshotBeforeStop = self.currentCoreFeatureRecoverySnapshot()
        coreActionState = .stopping
        defer { coreActionState = .idle }
        await self.prepareCoreFeatureRecoveryBeforeCoreTransition(
            fallbackRecovery: recoverySnapshotBeforeStop)
        cancelProviderRefresh(reason: "stop requested")
        await processManager.stopAsync()
        cancelPolling()
        statusText = "Stopped"
        apiStatus = .unknown
    }

    func restartCore(trigger: ProviderRefreshTrigger = .restart) async {
        guard !isCoreActionProcessing else { return }
        coreActionState = .restarting
        defer { coreActionState = .idle }
        cancelProviderRefresh(reason: "restart requested")
        do {
            guard let configPath = await resolveSelectedConfigPath() else {
                let message = tr("log.start.no_config")
                appendLog(level: "error", message: message)
                self.presentCoreFailureAlert(
                    title: self.tr("app.core.alert.restart_failed.title"),
                    message: message,
                    dedupeKey: "core-restart-failed")
                return
            }

            try await ensureTunPermissionsForConfigStartup(configPath: configPath)

            guard await self.validateConfigBeforeCoreLaunch(configPath: configPath) else {
                return
            }

            let launchController = applyExternalControllerFromSelectedConfigFile(configPath: configPath)
            let recoverySnapshotBeforeRestart = self.currentCoreFeatureRecoverySnapshot()
            await self.prepareCoreFeatureRecoveryBeforeCoreTransition(
                fallbackRecovery: recoverySnapshotBeforeRestart)
            _ = try await processManager.restartAsync(configPath: configPath, controller: launchController)
            await self.completeCoreBootstrap(
                configPath: configPath,
                options: CoreBootstrapOptions(
                    providerTrigger: trigger,
                    refreshProxyGroupsAfterBootstrap: true,
                    refreshSystemProxyBeforeBootstrap: false,
                    refreshSystemProxyAfterBootstrap: true))
        } catch {
            let errorMessage = self.coreErrorMessage(error)
            let message = tr("log.restart.failed", errorMessage)
            appendLog(level: "error", message: message)
            self.presentCoreFailureAlert(
                title: self.tr("app.core.alert.restart_failed.title"),
                message: message,
                dedupeKey: "core-restart-failed")
        }
    }

    func performPrimaryCoreAction() async {
        guard !isCoreActionProcessing else { return }
        if isRuntimeRunning {
            await self.restartCore()
        } else {
            await self.startCore(trigger: .manual)
        }
    }

    func setUILanguage(_ language: AppLanguage) {
        guard uiLanguage != language else { return }
        uiLanguage = language
        defaults.set(language.rawValue, forKey: uiLanguageKey)
    }

    func setAppearanceMode(_ mode: AppAppearanceMode) {
        guard appearanceMode != mode else { return }
        appearanceMode = mode
        defaults.set(mode.rawValue, forKey: appearanceModeKey)
        self.applyAppAppearance()
    }

    func quitApp() async {
        await self.disableSystemProxyForTerminationIfNeeded()
        self.prepareForTermination()
        if processManager.isRunning {
            await processManager.stopAsync()
        }
        NSApplication.shared.terminate(nil)
    }

    func shutdownForTermination() {
        self.disableSystemProxyForTerminationIfNeededBlocking()
        self.prepareForTermination()
        if processManager.isRunning {
            processManager.stop()
        }
    }

    private func disableSystemProxyForTerminationIfNeeded() async {
        let shouldRestoreOnNextLaunch = self.isSystemProxyEnabled || self.desiredSystemProxyEnabled
        self.desiredSystemProxyEnabled = shouldRestoreOnNextLaunch

        guard self.isSystemProxyEnabled else { return }

        self.isProxySyncing = true
        defer { self.isProxySyncing = false }

        do {
            try await self.applySystemProxy(enabled: false, host: self.controllerHost(), ports: .disabled)
            self.isSystemProxyEnabled = false
            self.appendLog(
                level: "info",
                message: self.tr("log.system_proxy.toggled", self.tr("log.system_proxy.disabled")))
        } catch {
            self.appendLog(
                level: "error",
                message: self.tr("log.system_proxy.toggle_failed", self.systemProxyErrorMessage(error)))
        }
    }

    private func disableSystemProxyForTerminationIfNeededBlocking() {
        let shouldRestoreOnNextLaunch = self.isSystemProxyEnabled || self.desiredSystemProxyEnabled
        self.desiredSystemProxyEnabled = shouldRestoreOnNextLaunch

        guard self.isSystemProxyEnabled else { return }

        self.systemProxyService.clearSystemProxyBlocking()
        self.isSystemProxyEnabled = false
    }

    private func prepareForTermination() {
        self.shouldRestoreCoreOnLaunch = self.isRuntimeRunning || self.shouldAutoResumeManagedRuntime
        self.runtimeStopReasons.removeAll()
        self.shouldAutoResumeManagedRuntime = false
        stopNetworkReachabilityMonitoring(resetState: true)
        stopConfigDirectoryMonitoring()
        cancelProviderRefresh(reason: "quit requested")
        cancelPolling()
    }

    func applyAppAppearance() {
        let app = NSApplication.shared
        switch appearanceMode {
        case .system:
            app.appearance = NSAppearance(named: .aqua)
        case .light:
            app.appearance = NSAppearance(named: .aqua)
        case .dark:
            app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func normalizeMode(_ raw: String?) -> CoreMode? {
        guard let raw else { return nil }
        return CoreMode(rawValue: raw.lowercased())
    }

    func registerManagedCoreStop(reason: RuntimeStopReason) {
        self.runtimeStopReasons.insert(reason)
        self.runtimeStopReasons.remove(.manual)
        self.shouldAutoResumeManagedRuntime = true
    }

    func resolveRuntimeStopReason(_ reason: RuntimeStopReason) {
        self.runtimeStopReasons.remove(reason)
    }

    var canAutoResumeManagedRuntime: Bool {
        guard self.shouldAutoResumeManagedRuntime else { return false }
        guard !self.runtimeStopReasons.contains(.manual) else { return false }
        return self.runtimeStopReasons.isEmpty
    }

    private func handleSuccessfulCoreStart(trigger: StartTrigger) {
        switch trigger {
        case .manual:
            self.runtimeStopReasons.removeAll()
            self.shouldAutoResumeManagedRuntime = false
        case .networkRecovery:
            self.runtimeStopReasons.remove(.networkLoss)
            self.shouldAutoResumeManagedRuntime = false
        case .systemWakeRecovery:
            self.runtimeStopReasons.remove(.systemSleep)
            self.shouldAutoResumeManagedRuntime = false
        case .auto:
            break
        }
    }

    @discardableResult
    func validateConfigBeforeCoreLaunch(configPath: String) async -> Bool {
        guard let details = await self.configValidationFailureDetails(configPath: configPath) else {
            return true
        }

        self.handleConfigValidationFailure(configPath: configPath, details: details)
        return false
    }

    private func presentConfigValidationFailedAlert(fileName: String, details: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = tr("app.config.validation_failed.title")
        alert.informativeText = tr("app.config.validation_failed.message", fileName, details)
        alert.addButton(withTitle: tr("ui.action.ok"))
        self.prepareModalWindowPresentation()
        self.configureModalWindow(alert.window)
        alert.runModal()
    }

    func configValidationFailureDetails(configPath: String) async -> String? {
        do {
            try await processManager.validateConfigAsync(configPath: configPath)
            return nil
        } catch {
            let detailsRaw = self.coreErrorMessage(error).trimmingCharacters(in: .whitespacesAndNewlines)
            return detailsRaw.isEmpty ? tr("ui.common.unknown") : detailsRaw
        }
    }

    func handleConfigValidationFailure(configPath: String, details: String) {
        let fileName = URL(fileURLWithPath: configPath).lastPathComponent
        appendLog(level: "error", message: tr("log.config.validate_failed", fileName, details))
        self.presentConfigValidationFailedAlert(fileName: fileName, details: details)
    }

    func presentCoreFailureAlert(
        title: String,
        message: String,
        dedupeKey: String,
        style: NSAlert.Style = .warning)
    {
        let now = Date()
        if self.lastCoreFailureAlertKey == dedupeKey,
           let lastAt = self.lastCoreFailureAlertAt,
           now.timeIntervalSince(lastAt) < self.coreFailureAlertThrottleInterval
        {
            return
        }

        self.lastCoreFailureAlertKey = dedupeKey
        self.lastCoreFailureAlertAt = now

        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: tr("ui.action.ok"))
        self.prepareModalWindowPresentation()
        self.configureModalWindow(alert.window)
        alert.runModal()
    }

    func restartCoreIfNeededForConfigSwitch(previousPath: String?, nextPath: String?) async {
        guard let nextPath else { return }
        guard previousPath != nextPath else { return }
        guard processManager.isRunning else { return }

        proxyGroups = []
        groupLatencies = [:]
        groupLatencyLoading = []
        appendLog(level: "info", message: tr("log.config.changed_restart"))
        cancelProviderRefresh(reason: "config switch requested")
        await self.restartCore(trigger: .configSwitch)
    }

    func refreshProxyGroupsAfterRestart() async {
        for _ in 0..<8 {
            await refreshProxyGroups()
            if apiStatus == .healthy { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    func attemptLaunchStateRestoreIfNeeded() async {
        if didAttemptLaunchStateRestore { return }
        didAttemptLaunchStateRestore = true
        await self.startCore(trigger: .auto)
    }

    private func completeCoreBootstrap(
        configPath: String,
        options: CoreBootstrapOptions) async
    {
        statusText = "Running"
        apiStatus = .healthy
        ensureAPIClient()
        startPolling()
        await refreshFromAPI(includeSlowCalls: true)

        await ensureTunMixedStackOnStartupIfNeeded()
        enqueueProviderRefresh(trigger: options.providerTrigger)

        if options.refreshProxyGroupsAfterBootstrap {
            await self.refreshProxyGroupsAfterRestart()
        }

        // Keep startup responsive even when helper registration or system proxy reads are slow.
        scheduleSystemProxyStartupPostflight(
            refreshStatusBeforeOverlay: options.refreshSystemProxyBeforeBootstrap,
            refreshStatusAfterBootstrap: options.refreshSystemProxyAfterBootstrap)

        defaults.set(configPath, forKey: lastSuccessfulConfigPathKey)
        startupErrorMessage = nil
        await self.restoreCoreFeaturesAfterStartupIfNeeded()
        await self.refreshTunStatusFromRuntimeConfig()
        enforceNetworkManagedCorePolicyIfNeeded()
    }

    private func currentCoreFeatureRecoverySnapshot() -> CoreFeatureRecoveryState {
        self.mergeCoreFeatureRecoveryStates(
            CoreFeatureRecoveryState(
                systemProxyEnabled: self.isSystemProxyEnabled),
            self.pendingCoreFeatureRecoveryState)
    }

    private func mergeCoreFeatureRecoveryStates(
        _ first: CoreFeatureRecoveryState?,
        _ second: CoreFeatureRecoveryState?) -> CoreFeatureRecoveryState
    {
        CoreFeatureRecoveryState(
            systemProxyEnabled: (first?.systemProxyEnabled ?? false) || (second?.systemProxyEnabled ?? false))
    }

    private func prepareCoreFeatureRecoveryBeforeCoreTransition(
        fallbackRecovery: CoreFeatureRecoveryState) async
    {
        let runtimeRunningBeforeTransition = self.isRuntimeRunning
        let capturedRecovery = CoreFeatureRecoveryState(
            systemProxyEnabled: runtimeRunningBeforeTransition && self.isSystemProxyEnabled)

        let baseRecovery: CoreFeatureRecoveryState = if capturedRecovery.shouldRecoverAnyFeature {
            capturedRecovery
        } else {
            // Keep the pre-transition snapshot when runtime state changes race with stop/restart actions.
            fallbackRecovery
        }

        let recovery = self.mergeCoreFeatureRecoveryStates(baseRecovery, self.pendingCoreFeatureRecoveryState)
        self.pendingCoreFeatureRecoveryState = recovery.shouldRecoverAnyFeature ? recovery : nil

        guard self.isSystemProxyEnabled else { return }
        self.isProxySyncing = true
        defer { self.isProxySyncing = false }

        do {
            try await self.applySystemProxy(enabled: false, host: self.controllerHost(), ports: .disabled)
            self.isSystemProxyEnabled = false
            self.appendLog(
                level: "info",
                message: self.tr("log.system_proxy.toggled", self.tr("log.system_proxy.disabled")))
        } catch {
            self.appendLog(
                level: "error",
                message: self.tr("log.system_proxy.toggle_failed", self.systemProxyErrorMessage(error)))
            await self.refreshSystemProxyStatus()
        }
    }

    func restoreCoreFeaturesAfterStartupIfNeeded() async {
        guard let recovery = self.pendingCoreFeatureRecoveryState else { return }
        guard recovery.shouldRecoverAnyFeature else {
            self.pendingCoreFeatureRecoveryState = nil
            return
        }
        guard self.isRuntimeRunning else { return }

        if self.autoStopCoreOnNetworkDisconnectEnabled, self.networkReachabilityStatus == .offline {
            return
        }

        var remainingSystemProxyRecovery = recovery.systemProxyEnabled

        if recovery.systemProxyEnabled {
            self.isProxySyncing = true
            defer { self.isProxySyncing = false }

            do {
                let target = try await self.resolveSystemProxyTargetFromRuntimeConfig()
                try await self.applySystemProxy(enabled: true, host: target.host, ports: target.ports)
                self.isSystemProxyEnabled = true
                remainingSystemProxyRecovery = false
                self.appendLog(
                    level: "info",
                    message: self.tr("log.system_proxy.toggled", self.tr("log.system_proxy.enabled")))
            } catch {
                self.appendLog(
                    level: "error",
                    message: self.tr("log.system_proxy.toggle_failed", self.systemProxyErrorMessage(error)))
                await self.refreshSystemProxyStatus()
            }
        }

        let remaining = CoreFeatureRecoveryState(
            systemProxyEnabled: remainingSystemProxyRecovery)
        self.pendingCoreFeatureRecoveryState = remaining.shouldRecoverAnyFeature ? remaining : nil
    }
}
