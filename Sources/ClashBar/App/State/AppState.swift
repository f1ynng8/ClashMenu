import AppKit
import CoreLocation
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private static let defaultSystemProxyBypassList =
        "localhost,127.0.0.1,*.local,10/8,169.254/16,172.16/12,192.168/16,apple.com,*.apple.com"

    @Published var statusText: String = "Stopped" {
        didSet { self.refreshMenuBarDisplaySnapshotIfNeeded() }
    }

    @Published var version: String = "-"
    @Published var controller: String = "127.0.0.1:9090"
    @Published var externalControllerDisplay: String = "127.0.0.1:9090"
    @Published var controllerSecret: String?

    @Published var currentMode: CoreMode = .rule
    @Published var logLevel: String = "info"
    @Published var port: Int?
    @Published var socksPort: Int?
    @Published var redirPort: Int?
    @Published var tproxyPort: Int?
    @Published var mixedPort: Int = 7890

    @Published var mihomoBinaryPath: String = "-"
    @Published var selectedConfigName: String = "-"
    @Published var configDirectoryPath: String = "-"
    @Published var availableConfigFileNames: [String] = []

    @Published var proxyGroups: [ProxyGroup] = []
    @Published var groupLatencyLoading: Set<String> = []
    @Published var groupLatencies: [String: [String: Int]] = [:]
    @Published var proxyHistoryLatestDelay: [String: Int] = [:]

    @Published var providerProxyCount: Int = 0
    @Published var providerRuleCount: Int = 0
    @Published var rulesCount: Int = 0
    @Published var proxyProvidersDetail: [String: ProviderDetail] = [:]
    @Published var expandedProxyProviders: Set<String> = []
    @Published var providerNodeLatencies: [String: [String: Int]] = [:]
    @Published var providerNodeTesting: Set<ProviderNodeKey> = []
    @Published var providerBatchTesting: Set<String> = []
    @Published var providerUpdating: Set<String> = []
    @Published var ruleProviders: [String: ProviderDetail] = [:]
    @Published var ruleItems: [RuleItem] = []
    @Published var isRuleProvidersRefreshing: Bool = false

    @Published var isSystemProxyEnabled: Bool = false
    @Published var isProxySyncing: Bool = false
    @Published var isTunEnabled: Bool = false

    @Published var apiStatus: APIHealth = .unknown {
        didSet { self.refreshMenuBarDisplaySnapshotIfNeeded() }
    }

    @Published var errorLogs: [AppErrorLogEntry] = []
    @Published var startupErrorMessage: String?
    @Published var coreActionState: CoreActionState = .idle
    @Published var providerRefreshStatus: ProviderRefreshStatus = .idle
    @Published var uiLanguage: AppLanguage = .zhHans
    @Published var appearanceMode: AppAppearanceMode = .system
    @Published var launchAtLoginEnabled: Bool = false
    @Published var launchAtLoginErrorMessage: String?
    @Published var latestAppReleaseInfo: AppReleaseInfo?
    @Published var sceneConfigDisplayName: String = "-"
    @Published var sceneDefinitions: [SceneDefinition] = []
    @Published var activeSceneName: String?
    @Published var activeSceneSSID: String?
    @Published var sceneStatusMessage: String?
    @Published private(set) var menuBarDisplaySnapshot = MenuBarDisplay(
        symbolName: "bolt.slash.circle",
        brandIconState: .stopped)

    @Published var settingsSyncingKey: String?
    @Published var settingsErrorMessage: String?
    @Published var settingsSavedMessage: String?

    var runtimeVisualStatus: RuntimeVisualStatus {
        let normalized = self.statusText.lowercased()
        if normalized == "starting" { return .starting }
        if normalized == "failed" { return .failed }

        let running = self.processManager.isRunning || normalized == "running"
        if running {
            switch self.apiStatus {
            case .healthy:
                return .runningHealthy
            case .failed:
                return .failed
            case .degraded, .unknown:
                return .runningDegraded
            }
        }
        return .stopped
    }

    var runtimeStatusText: String {
        switch self.runtimeVisualStatus {
        case .starting: tr("app.runtime.starting")
        case .runningHealthy, .runningDegraded: tr("app.runtime.running")
        case .failed: tr("app.runtime.failed")
        case .stopped: tr("app.runtime.stopped")
        }
    }

    var isExternalControllerWildcardIPv4: Bool {
        guard let host = self.controllerHost(from: self.externalControllerDisplay) else {
            return false
        }
        return host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "0.0.0.0"
    }

    // DRY: unify "running" checks across AppState and extensions.
    var isRuntimeRunning: Bool {
        self.processManager.isRunning || self.statusText.caseInsensitiveCompare("running") == .orderedSame
    }

    var menuBarSymbolName: String {
        switch self.runtimeVisualStatus {
        case .runningHealthy:
            "bolt.horizontal.circle.fill"
        case .runningDegraded:
            "bolt.horizontal.circle"
        case .starting:
            "clock.arrow.circlepath"
        case .failed:
            "exclamationmark.triangle.fill"
        case .stopped:
            "bolt.slash.circle"
        }
    }

    var menuBarDisplay: MenuBarDisplay {
        self.menuBarDisplaySnapshot
    }

    private var computedMenuBarDisplay: MenuBarDisplay {
        MenuBarDisplay(
            symbolName: self.menuBarSymbolName,
            brandIconState: self.runtimeVisualStatus == .runningHealthy ? .running : .stopped)
    }

    func refreshMenuBarDisplaySnapshotIfNeeded() {
        let next = self.computedMenuBarDisplay
        guard next != self.menuBarDisplaySnapshot else { return }
        self.menuBarDisplaySnapshot = next
    }

    var isModeSwitchEnabled: Bool {
        self.processManager.isRunning && self.apiStatus == .healthy
    }

    var sceneControlMode: SceneControlMode {
        get { SceneControlMode(rawValue: self.sceneControlModeStorage) ?? .disabled }
        set {
            guard self.sceneControlMode != newValue else { return }
            self.objectWillChange.send()
            self.sceneControlModeStorage = newValue.rawValue
            self.updateNetworkReachabilityMonitoringState()
        }
    }

    var manualSceneName: String? {
        let trimmed = self.manualSceneNameStorage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isSceneControlEnabled: Bool {
        self.sceneControlMode != .disabled
    }

    var canAdjustCoreControlsManually: Bool {
        !self.isSceneControlEnabled
    }

    var sceneMenuDisplayTitle: String {
        switch self.sceneControlMode {
        case .disabled:
            return self.local("场景已禁用", "Scenes Disabled")
        case .automatic:
            let sceneName = self.activeSceneName ?? self.local("未匹配", "Unmatched")
            return self.local("自动-\(sceneName)", "Auto-\(sceneName)")
        case .manual:
            let sceneName = self.activeSceneName ?? self.manualSceneName ?? self.local("未选择", "Unselected")
            return self.local("手动-\(sceneName)", "Manual-\(sceneName)")
        }
    }

    var autoStopCoreOnNetworkDisconnectEnabled: Bool {
        get { self.autoStopCoreOnNetworkLoss }
        set {
            guard self.autoStopCoreOnNetworkLoss != newValue else { return }
            self.autoStopCoreOnNetworkLoss = newValue
            self.updateNetworkReachabilityMonitoringState()
        }
    }

    var autoStopCoreOnSystemSleepEnabled: Bool {
        get { self.autoStopCoreOnSystemSleep }
        set {
            guard self.autoStopCoreOnSystemSleep != newValue else { return }
            self.autoStopCoreOnSystemSleep = newValue
            self.updateNetworkReachabilityMonitoringState()
        }
    }

    var recoveryCheckDelaySeconds: Int {
        get { max(1, self.recoveryCheckDelaySecondsStorage) }
        set {
            let clamped = max(1, min(newValue, 60))
            guard self.recoveryCheckDelaySecondsStorage != clamped else { return }
            self.objectWillChange.send()
            self.recoveryCheckDelaySecondsStorage = clamped
        }
    }

    var systemProxyBypassListText: String {
        get {
            let sanitized = self.normalizedSystemProxyBypassListText(self.systemProxyBypassListStorage)
            return sanitized.isEmpty ? Self.defaultSystemProxyBypassList : sanitized
        }
        set {
            let sanitized = self.normalizedSystemProxyBypassListText(newValue)
            let valueToStore = sanitized.isEmpty ? Self.defaultSystemProxyBypassList : sanitized
            guard self.systemProxyBypassListStorage != valueToStore else { return }
            self.objectWillChange.send()
            self.systemProxyBypassListStorage = valueToStore
        }
    }

    var systemProxyBypassHosts: [String] {
        Self.parseSystemProxyBypassHosts(self.systemProxyBypassListText)
    }

    var recoveryCheckDelayNanoseconds: UInt64 {
        UInt64(self.recoveryCheckDelaySeconds) * 1_000_000_000
    }

    var isCoreActionProcessing: Bool {
        self.coreActionState != .idle
    }

    var primaryCoreActionLabel: String {
        if self.isCoreActionProcessing { return tr("app.primary.processing") }
        return self.isRuntimeRunning ? tr("app.primary.restart") : tr("app.primary.start")
    }

    var primaryCoreActionIconName: String {
        if self.isCoreActionProcessing { return "hourglass" }
        return self.isRuntimeRunning ? "arrow.clockwise" : "play.fill"
    }

    var isPrimaryCoreActionEnabled: Bool {
        !self.isCoreActionProcessing
    }

    let processManager: any MihomoControlling
    let configManager: ConfigDirectoryManager
    let workingDirectoryManager: WorkingDirectoryManager
    let systemProxyService: SystemProxyService
    let tunPermissionService: TunPermissionService
    let configImportService: ConfigImportService
    let appLaunchService: AppLaunchService
    let networkReachabilityMonitor: NetworkReachabilityMonitor
    let sceneConfigurationService: SceneConfigurationService
    let wifiNetworkService: WiFiNetworkService
    let locationPermissionService: LocationPermissionService
    var apiClient: MihomoAPIClient?
    var modeSwitchTransportOverride: MihomoAPITransporting?
    var settingsPatchTransportOverride: MihomoAPITransporting?

    var mediumFrequencyTask: Task<Void, Never>?
    var lowFrequencyTask: Task<Void, Never>?
    var settingsFeedbackClearTask: Task<Void, Never>?
    var providerRefreshTask: Task<Void, Never>?
    var networkAutoStopTask: Task<Void, Never>?
    var networkAutoStartTask: Task<Void, Never>?
    var networkWakeRecoveryTask: Task<Void, Never>?
    var sceneEvaluationTask: Task<Void, Never>?
    var configDirectoryMonitorTask: Task<Void, Never>?
    var mihomoLogFlushTask: Task<Void, Never>?
    var providerRefreshGeneration: Int = 0
    var pendingMihomoLogs: [AppErrorLogEntry] = []
    var modeSwitchInFlight = false
    var configFileSignatureSnapshot: [String: String] = [:]
    var pendingConfigChangeRestart = false
    var lastLatestAppReleaseCheckAt: Date?
    var isLatestAppReleaseCheckInFlight = false

    let defaults = UserDefaults.standard
    @AppStorage("clashmenu.auto.stop.core.network.loss") private var autoStopCoreOnNetworkLoss: Bool = true
    @AppStorage("clashmenu.auto.stop.core.system.sleep") private var autoStopCoreOnSystemSleep: Bool = true
    @AppStorage("clashmenu.recovery.check.delay.seconds") private var recoveryCheckDelaySecondsStorage: Int = 3
    @AppStorage("clashmenu.system.proxy.bypass.list")
    private var systemProxyBypassListStorage: String = AppState.defaultSystemProxyBypassList
    @AppStorage("clashmenu.scene.mode") var sceneControlModeStorage: String = SceneControlMode.disabled.rawValue
    @AppStorage("clashmenu.scene.manual.name") var manualSceneNameStorage: String = ""
    @AppStorage("clashmenu.scene.config.path") var sceneConfigPathStorage: String = ""
    @AppStorage("clashmenu.scene.config.remote.url") var sceneRemoteConfigURLStorage: String = ""
    @AppStorage("clashmenu.core.restore_on_launch") var shouldRestoreCoreOnLaunch: Bool = false
    @AppStorage("clashmenu.proxy.node.hide_unavailable") var hideUnavailableProxyNodes: Bool = false
    @AppStorage("clashmenu.system_proxy.desired") var desiredSystemProxyEnabled: Bool = false
    let selectedConfigKey = "clashmenu.config.selected.filename"
    let legacySelectedConfigKey = "clashmenu.config.selected"
    let sceneRemoteConfigURLKey = "clashmenu.scene.config.remote.url"
    let remoteConfigSourcesKey = "clashmenu.config.remote.sources.v1"
    let lastSuccessfulConfigPathKey = "clashmenu.last.success.config.path"
    let bundledDefaultConfigSeededKey = "clashmenu.config.bundled_default.seeded.v1"
    let legacyDesiredTunEnabledKey = "clashmenu.tun.desired"
    let legacyEditableSettingsSnapshotKey = "clashmenu.settings.editable.snapshot.v1"
    let uiLanguageKey = "clashmenu.ui.language"
    let appearanceModeKey = "clashmenu.ui.appearance.mode"
    let hiddenPanelMaxInMemoryLogEntries = 20
    let maxBufferedMihomoLogEntries = 40
    let mihomoLogFlushIntervalNanoseconds: UInt64 = 150_000_000
    let foregroundMediumFrequencyIntervalNanoseconds: UInt64 = 4_000_000_000
    let backgroundMediumFrequencyIntervalNanoseconds: UInt64 = 12_000_000_000
    let backgroundLowFrequencyIntervalNanoseconds: UInt64 = 120_000_000_000
    let latestAppReleaseRefreshInterval: TimeInterval = 6 * 60 * 60
    let latestAppReleaseRetryInterval: TimeInterval = 30 * 60
    let networkOfflineStopDebounceNanoseconds: UInt64 = 20_000_000_000
    // DRY: shared defaults for latency/provider healthcheck endpoints.
    let defaultHealthcheckURL = "https://www.gstatic.com/generate_204"
    let defaultHealthcheckTimeoutMilliseconds = 5000
    var mediumFrequencyIntervalNanoseconds: UInt64 = 4_000_000_000
    var lowFrequencyIntervalNanoseconds: UInt64 = 20_000_000_000
    var clashmenuLogFileURL: URL?
    var mihomoLogFileURL: URL?
    var clashmenuLogStore: AppLogStore?
    var mihomoLogStore: AppLogStore?
    var didAttemptLaunchStateRestore = false
    var didCheckSystemProxyConsistencyOnLaunch = false
    var lastCoreFailureAlertKey: String?
    var lastCoreFailureAlertAt: Date?
    let coreFailureAlertThrottleInterval: TimeInterval = 20
    var networkReachabilityStatus: NetworkReachabilityStatus = .unknown
    var networkReachabilitySuppressedUntil: Date?
    var runtimeStopReasons: Set<RuntimeStopReason> = []
    var shouldAutoResumeManagedRuntime = false
    var isNetworkReachabilityMonitoring = false
    var isSystemSleeping = false
    var systemSleepWakeObserver: SystemSleepWakeObserver?
    var activeSceneRuntimeConfigPath: String?
    var lastAppliedSceneSignature: String?
    var pendingCoreFeatureRecoveryState: CoreFeatureRecoveryState?
    var remoteConfigSources: [String: String] = [:]
    var externalControllerWarningKeys: Set<String> = []
    let streamJSONDecoder = JSONDecoder()
    let initialNoCoreSetupGuideShownKey = "clashmenu.core.install.guide.shown.v1"
    let bundlesMihomoCore: Bool
    var didPresentInitialNoCoreSetupGuide = false

    init(
        processManager: (any MihomoControlling)? = nil,
        configManager: ConfigDirectoryManager? = nil,
        workingDirectoryManager: WorkingDirectoryManager = WorkingDirectoryManager(),
        systemProxyService: SystemProxyService = SystemProxyService(),
        tunPermissionService: TunPermissionService = TunPermissionService(),
        configImportService: ConfigImportService = ConfigImportService(),
        appLaunchService: AppLaunchService = AppLaunchService(),
        networkReachabilityMonitor: NetworkReachabilityMonitor = NetworkReachabilityMonitor(),
        sceneConfigurationService: SceneConfigurationService = SceneConfigurationService(),
        wifiNetworkService: WiFiNetworkService = WiFiNetworkService(),
        locationPermissionService: LocationPermissionService = LocationPermissionService(),
        clashmenuLogStore: AppLogStore? = nil,
        mihomoLogStore: AppLogStore? = nil,
        startBackgroundRefresh: Bool = true)
    {
        self.processManager = processManager ?? MihomoProcessManager(workingDirectoryManager: workingDirectoryManager)
        self.workingDirectoryManager = workingDirectoryManager
        self.systemProxyService = systemProxyService
        self.tunPermissionService = tunPermissionService
        self.configImportService = configImportService
        self.appLaunchService = appLaunchService
        self.networkReachabilityMonitor = networkReachabilityMonitor
        self.sceneConfigurationService = sceneConfigurationService
        self.wifiNetworkService = wifiNetworkService
        self.locationPermissionService = locationPermissionService
        self.clashmenuLogStore = clashmenuLogStore
        self.mihomoLogStore = mihomoLogStore
        self.configManager = configManager ?? ConfigDirectoryManager(workingDirectoryManager: workingDirectoryManager)
        self.bundlesMihomoCore = Self.resolveBundledMihomoCoreFlag()
        self.uiLanguage = loadPersistedUILanguage()
        self.appearanceMode = loadPersistedAppearanceMode()
        applyAppAppearance()
        refreshLaunchAtLoginStatus()

        self.mihomoBinaryPath = self.processManager.detectedBinaryPath ?? "-"
        if let managedProcess = self.processManager as? MihomoProcessManager {
            managedProcess.onLog = { [weak self] line in
                Task { @MainActor in
                    self?.appendMihomoLog(level: "info", message: line)
                }
            }
            managedProcess.onTermination = { [weak self] code in
                Task { @MainActor in
                    let message = self?.tr("log.process.terminated", code) ?? ""
                    self?.statusText = "Failed"
                    self?.apiStatus = .failed
                    self?.appendLog(level: "error", message: message)
                    self?.cancelPolling()
                    if self?.coreActionState == .idle, let self, !message.isEmpty {
                        self.presentCoreFailureAlert(
                            title: self.tr("app.core.alert.process_terminated.title"),
                            message: message,
                            dedupeKey: "core-process-terminated",
                            style: .critical)
                    }
                }
            }
        }
        do {
            try self.workingDirectoryManager.bootstrapDirectories()
            clashmenuLogFileURL = self.workingDirectoryManager.logsDirectoryURL.appendingPathComponent(
                "clashmenu.log",
                isDirectory: false)
            mihomoLogFileURL = self.workingDirectoryManager.logsDirectoryURL.appendingPathComponent(
                "mihomo.log",
                isDirectory: false)

            if let clashmenuLogFileURL, self.clashmenuLogStore == nil {
                self.clashmenuLogStore = AppLogStore(logFileURL: clashmenuLogFileURL)
            }
            if let mihomoLogFileURL, self.mihomoLogStore == nil {
                self.mihomoLogStore = AppLogStore(logFileURL: mihomoLogFileURL, maxArchives: 4)
            }
            ensureLogFileExists()
            seedBundledConfigIfNeeded()
        } catch {
            appendLog(level: "error", message: tr("log.working_dir_init_failed", error.localizedDescription))
        }
        restoreSavedConfigDirectory()
        restoreLastSuccessfulConfigIfAvailable()
        self.remoteConfigSources = loadPersistedRemoteConfigSources()
        pruneRemoteConfigSourcesIfNeeded()
        self.clearLegacyTunPreferences()

        if startBackgroundRefresh {
            Task {
                await refreshFromAPI(includeSlowCalls: true)
                await refreshSystemProxyStatus()
                await ensureSystemProxyConsistencyOnFirstLaunchIfNeeded()
            }

            self.startConfigDirectoryMonitoringIfNeeded()
        }
        if startBackgroundRefresh, self.shouldRestoreCoreOnLaunch, self.sceneControlMode == .disabled {
            if !self.shouldDeferAutoStartForMissingManagedCore() {
                Task { [weak self] in
                    await self?.attemptLaunchStateRestoreIfNeeded()
                }
            }
        }

        self.configureSystemSleepWakeObservationIfNeeded()
        self.reloadSceneConfiguration()
        self.updateNetworkReachabilityMonitoringState()
        self.scheduleSceneEvaluationIfNeeded(force: true)
        self.refreshMenuBarDisplaySnapshotIfNeeded()
    }

    deinit {
        networkAutoStopTask?.cancel()
        networkAutoStartTask?.cancel()
        networkWakeRecoveryTask?.cancel()
        sceneEvaluationTask?.cancel()
        configDirectoryMonitorTask?.cancel()
        mihomoLogFlushTask?.cancel()
        mediumFrequencyTask?.cancel()
        lowFrequencyTask?.cancel()
        providerRefreshTask?.cancel()
    }

    private func normalizedSystemProxyBypassListText(_ value: String) -> String {
        Self.parseSystemProxyBypassHosts(value).joined(separator: ",")
    }

    private static func parseSystemProxyBypassHosts(_ value: String) -> [String] {
        var seen = Set<String>()
        return value
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private static func resolveBundledMihomoCoreFlag() -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ClashMenuBundlesMihomoCore") else {
            return true
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return NSString(string: string).boolValue
        }
        return true
    }

    func local(_ zh: String, _ en: String) -> String {
        self.uiLanguage == .zhHans ? zh : en
    }
}
