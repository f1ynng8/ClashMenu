import Foundation

@MainActor
extension AppState {
    func startPolling() {
        self.ensurePeriodicTasksForCurrentVisibility()
        self.updateDataAcquisitionPolicy()
    }

    func cancelPolling() {
        mediumFrequencyTask?.cancel()
        lowFrequencyTask?.cancel()
        mediumFrequencyTask = nil
        lowFrequencyTask = nil
    }

    private func startPeriodicTask(
        intervalProvider: @escaping (AppState) -> UInt64,
        operation: @escaping (AppState) async -> Void) -> Task<Void, Never>
    {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await operation(self)
                do {
                    let interval = max(1_000_000_000, intervalProvider(self))
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func ensurePeriodicTasksForCurrentVisibility() {
        mediumFrequencyTask?.cancel()
        lowFrequencyTask?.cancel()
        mediumFrequencyTask = nil
        lowFrequencyTask = nil
    }

    func refreshFromAPI(includeSlowCalls: Bool) async {
        await self.refreshHighFrequency()
        await self.refreshMediumFrequency()
        if includeSlowCalls {
            await self.refreshLowFrequency()
        }
    }

    private func refreshHighFrequency() async {
        self.updateDataAcquisitionPolicy()
    }

    func updateDataAcquisitionPolicy() {
        guard processManager.isRunning else {
            self.ensurePeriodicTasksForCurrentVisibility()
            mediumFrequencyIntervalNanoseconds = foregroundMediumFrequencyIntervalNanoseconds
            lowFrequencyIntervalNanoseconds = backgroundLowFrequencyIntervalNanoseconds
            return
        }

        mediumFrequencyIntervalNanoseconds = backgroundMediumFrequencyIntervalNanoseconds
        lowFrequencyIntervalNanoseconds = backgroundLowFrequencyIntervalNanoseconds
        self.ensurePeriodicTasksForCurrentVisibility()
    }

    private func refreshMediumFrequency() async {
        await runRefresh {
            let client = try self.clientOrThrow()
            async let versionTask: VersionInfo = client.request(.version)
            async let configTask: ConfigSnapshot = client.request(.getConfigs)

            let (version, config) = try await (versionTask, configTask)
            self.version = version.version
            self.applyRuntimeConfigSnapshot(config)
        }
    }

    func fetchRuntimeConfigSnapshot() async throws -> ConfigSnapshot {
        let client = try clientOrThrow()
        let config: ConfigSnapshot = try await client.request(.getConfigs)
        self.applyRuntimeConfigSnapshot(config)
        return config
    }

    private func applyRuntimeConfigSnapshot(_ config: ConfigSnapshot) {
        let remoteMode = normalizeMode(config.mode)
        if let remoteMode {
            currentMode = remoteMode
        }
        logLevel = config.logLevel ?? logLevel

        port = config.port
        socksPort = config.socksPort
        redirPort = config.redirPort
        tproxyPort = config.tproxyPort
        mixedPort = config.mixedPort ?? 0

        if let externalController = config.externalController {
            applyExternalControllerFromConfig(externalController)
        }
        syncEditableSettings(from: config)
    }

    private func refreshLowFrequency() async {
        await self.refreshSystemProxyStatus()
    }

    func refreshProxyGroups() async {
        await runRefresh {
            let client = try self.clientOrThrow()
            let payload = try await self.fetchProxyGroupsAndProviders(using: client)
            self.applyProxyGroupsResponse(payload.groups, proxyProviders: payload.providers)
        }
    }

    private func fetchProxyGroupsAndProviders(using client: MihomoAPIClient) async throws -> (
        groups: ProxyGroupsResponse,
        providers: [String: ProviderDetail])
    {
        async let groupsTask: ProxyGroupsResponse = client.request(.proxies)
        async let proxyProvidersTask: ProviderSummary? = try? await client.request(.proxyProviders)
        let (groupsResponse, proxyProviders) = try await (groupsTask, proxyProvidersTask)
        return (groupsResponse, proxyProviders?.providers ?? [:])
    }

    private func applyProxyGroupsResponse(
        _ response: ProxyGroupsResponse,
        proxyProviders: [String: ProviderDetail] = [:])
    {
        let providerLookup = proxyProviders.isEmpty ? proxyProvidersDetail : proxyProviders
        let proxiesWithHealthcheckConfig = response.proxies.values.map { proxy in
            let provider = providerLookup[proxy.name]
            let resolvedTestURL = self.normalizedHealthcheckURL(proxy.testUrl)
                ?? self.normalizedHealthcheckURL(provider?.testUrl)
            let resolvedTimeout = self.normalizedHealthcheckTimeout(proxy.timeout)
                ?? self.normalizedHealthcheckTimeout(provider?.timeout)

            return ProxyGroup(
                name: proxy.name,
                type: proxy.type,
                now: proxy.now,
                all: proxy.all,
                testUrl: resolvedTestURL,
                timeout: resolvedTimeout,
                icon: proxy.icon,
                hidden: proxy.hidden,
                latestDelay: proxy.latestDelay)
        }

        let sortIndex = (response.proxies["GLOBAL"]?.all ?? []) + ["GLOBAL"]
        var sortIndexMap: [String: Int] = [:]
        for (index, name) in sortIndex.enumerated() where sortIndexMap[name] == nil {
            sortIndexMap[name] = index
        }

        proxyGroups = proxiesWithHealthcheckConfig
            .enumerated()
            .filter {
                !$0.element.all.isEmpty
            }
            .sorted { lhs, rhs in
                let lhsOrder = sortIndexMap[lhs.element.name] ?? -1
                let rhsOrder = sortIndexMap[rhs.element.name] ?? -1

                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        var historyMap: [String: Int] = [:]
        for proxy in response.proxies.values {
            if let latest = proxy.latestDelay {
                historyMap[proxy.name] = latest
            }
        }
        proxyHistoryLatestDelay = historyMap
    }

    func normalizedHealthcheckURL(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func normalizedHealthcheckTimeout(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    func refreshSystemProxyStatus() async {
        do {
            isSystemProxyEnabled = try await readSystemProxyEnabledState()
        } catch {
            appendLog(level: "error", message: tr("log.system_proxy.read_failed", systemProxyErrorMessage(error)))
        }
    }
}
