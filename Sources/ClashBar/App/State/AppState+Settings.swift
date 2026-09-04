import Foundation

@MainActor
extension AppState {
    func syncEditableSettings(from config: ConfigSnapshot) {
        if let tunEnabled = config.tunEnabled {
            self.isTunEnabled = tunEnabled
        }
    }

    @discardableResult
    func patchConfigBody(_ body: [String: ConfigPatchValue], syncingKey: String, successMessage: String) async -> Bool {
        settingsFeedbackClearTask?.cancel()
        settingsFeedbackClearTask = nil
        settingsSyncingKey = syncingKey
        settingsErrorMessage = nil
        settingsSavedMessage = nil
        defer { settingsSyncingKey = nil }

        do {
            ensureAPIClient()
            let payload = body.mapValues(\.jsonValue)
            try await self.settingsPatchTransport().requestNoResponse(.patchConfigs(body: payload))
            settingsSavedMessage = successMessage
            self.scheduleSettingsFeedbackAutoClearIfNeeded(message: successMessage)
            await refreshFromAPI(includeSlowCalls: false)
            return true
        } catch {
            let message = tr("app.settings.error.save_failed", syncingKey, error.localizedDescription)
            settingsErrorMessage = message
            settingsSavedMessage = nil
            await refreshFromAPI(includeSlowCalls: false)
            return false
        }
    }

    func scheduleSettingsFeedbackAutoClearIfNeeded(message: String) {
        guard message.trimmedNonEmpty != nil else { return }

        settingsFeedbackClearTask?.cancel()
        settingsFeedbackClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }

            guard let self else { return }
            if self.settingsSavedMessage == message {
                self.settingsSavedMessage = nil
            }
        }
    }

    func clientOrThrow() throws -> MihomoAPIClient {
        if apiClient == nil {
            ensureAPIClient()
        }
        if let apiClient {
            return apiClient
        }
        throw APIError.invalidURL
    }

    func modeSwitchTransport() throws -> MihomoAPITransporting {
        try self.resolvedTransport(override: modeSwitchTransportOverride)
    }

    func settingsPatchTransport() throws -> MihomoAPITransporting {
        try self.resolvedTransport(override: settingsPatchTransportOverride)
    }

    private func resolvedTransport(override: MihomoAPITransporting?) throws -> MihomoAPITransporting {
        if let override {
            return override
        }
        return try self.clientOrThrow()
    }
}
