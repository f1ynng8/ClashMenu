import Foundation

@MainActor
extension AppState {
    func upgradeCore() async -> CoreUpgradeResult {
        do {
            let response: CoreUpgradeResponse = try await self.clientOrThrow().request(.upgradeCore)
            let result = await self.enrichCoreUpgradeResultIfNeeded(self.coreUpgradeResult(from: response))
            self.logCoreUpgradeResult(result)
            return result
        } catch {
            let result = self.coreUpgradeResult(from: error)
            self.logCoreUpgradeResult(result)
            return result
        }
    }

    func flushFakeIPCache() async {
        await runNoResponseAction(tr("log.action_name.flush_fakeip_cache")) {
            try await self.clientOrThrow().requestNoResponse(.flushFakeIPCache)
        }
    }

    func flushDNSCache() async {
        await runNoResponseAction(tr("log.action_name.flush_dns_cache")) {
            try await self.clientOrThrow().requestNoResponse(.flushDNSCache)
        }
    }

    private func enrichCoreUpgradeResultIfNeeded(_ result: CoreUpgradeResult) async -> CoreUpgradeResult {
        switch result {
        case let .updated(version) where version == nil:
            if let latestVersion = await self.fetchCoreVersionForUpgradeResult() {
                return .updated(version: latestVersion)
            }
            return result
        case let .alreadyLatest(version) where version == nil:
            if let latestVersion = await self.fetchCoreVersionForUpgradeResult() {
                return .alreadyLatest(version: latestVersion)
            }
            return result
        case .updated, .alreadyLatest, .failed:
            return result
        }
    }

    private func fetchCoreVersionForUpgradeResult() async -> String? {
        do {
            try await Task.sleep(nanoseconds: 750_000_000)
        } catch {
            return nil
        }

        guard !Task.isCancelled else { return nil }

        do {
            let versionInfo: VersionInfo = try await self.clientOrThrow().request(.version)
            let normalized = AppSemanticVersion.normalizedDisplayVersion(from: versionInfo.version)
            self.version = normalized
            return normalized
        } catch {
            return nil
        }
    }

    private func coreUpgradeResult(from response: CoreUpgradeResponse) -> CoreUpgradeResult {
        if let status = response.status?.trimmedNonEmpty,
           status.caseInsensitiveCompare("ok") == .orderedSame
        {
            return .updated(version: nil)
        }

        if let message = response.message?.trimmedNonEmpty {
            return self.coreUpgradeResult(fromMessage: message)
        }

        return .failed(message: tr("ui.common.unknown"))
    }

    private func coreUpgradeResult(from error: Error) -> CoreUpgradeResult {
        if let apiError = error as? APIError,
           case let .statusCode(_, responseBody) = apiError
        {
            if let data = responseBody.data(using: .utf8),
               let response = try? JSONDecoder().decode(CoreUpgradeResponse.self, from: data)
            {
                let result = self.coreUpgradeResult(from: response)
                if case let .failed(message) = result, message == tr("ui.common.unknown") {
                    return self.coreUpgradeResult(fromMessage: responseBody)
                }
                return result
            }

            return self.coreUpgradeResult(fromMessage: responseBody)
        }

        return self.coreUpgradeResult(fromMessage: error.localizedDescription)
    }

    private func coreUpgradeResult(fromMessage message: String) -> CoreUpgradeResult {
        let trimmedMessage = message.trimmed
        guard !trimmedMessage.isEmpty else {
            return .failed(message: tr("ui.common.unknown"))
        }

        if self.isAlreadyLatestCoreUpgradeMessage(trimmedMessage) {
            return .alreadyLatest(version: self.latestVersion(in: trimmedMessage))
        }

        return .failed(message: trimmedMessage)
    }

    private func logCoreUpgradeResult(_ result: CoreUpgradeResult) {
        switch result {
        case let .updated(version):
            if let version, !version.isEmpty {
                self.appendLog(level: "info", message: tr("log.core_upgrade.updated_version", version))
            } else {
                self.appendLog(level: "info", message: tr("log.core_upgrade.updated"))
            }
        case let .alreadyLatest(version):
            if let version, !version.isEmpty {
                self.appendLog(level: "info", message: tr("log.core_upgrade.latest_version", version))
            } else {
                self.appendLog(level: "info", message: tr("log.core_upgrade.latest"))
            }
        case let .failed(message):
            self.appendLog(level: "error", message: tr("log.core_upgrade.failed", message))
        }
    }

    private func isAlreadyLatestCoreUpgradeMessage(_ message: String) -> Bool {
        message.range(
            of: "already using latest version",
            options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func latestVersion(in message: String) -> String? {
        let pattern = #"v?\d+(?:\.\d+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.matches(in: message, range: range).last,
              let swiftRange = Range(match.range, in: message)
        else {
            return nil
        }

        let raw = String(message[swiftRange])
        return AppSemanticVersion.normalizedDisplayVersion(from: raw)
    }
}
