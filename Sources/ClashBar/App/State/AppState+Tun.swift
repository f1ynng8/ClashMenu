import Foundation

enum TunModeError: LocalizedError {
    case runtimeStateMismatch(expected: Bool)

    var errorDescription: String? {
        switch self {
        case let .runtimeStateMismatch(expected):
            "TUN runtime state mismatch. expected=\(expected)"
        }
    }
}

@MainActor
extension AppState {
    func ensureTunPermissionsForConfigStartup(configPath: String) async throws {
        guard self.configFileDeclaresTunEnabled(at: configPath) else { return }
        // On app updates, bundled mihomo may lose setuid/root ownership.
        // Request permission proactively before starting a config that enables TUN.
        try await self.ensureTunPermissions(requestIfMissing: true)
    }

    func tunErrorMessage(_ error: Error) -> String {
        if let permissionError = error as? TunPermissionServiceError {
            switch permissionError {
            case .coreBinaryNotFound, .coreBinaryNotExecutable:
                return tr("app.tun.error.binary_not_found", workingDirectoryManager.coreDirectoryURL.path)
            case .permissionMissing:
                return tr("app.tun.error.permission_missing")
            case .authorizationCancelled:
                return tr("app.tun.error.authorization_cancelled")
            case let .authorizationFailed(message):
                return tr("app.tun.error.authorization_failed", message)
            case .permissionVerificationFailed:
                return tr("app.tun.error.permission_verify_failed")
            }
        }

        if let tunModeError = error as? TunModeError {
            switch tunModeError {
            case .runtimeStateMismatch:
                return tr("app.tun.error.runtime_state_mismatch")
            }
        }

        if let apiError = error as? APIError,
           case .statusCode = apiError
        {
            return tr("app.tun.error.patch_failed", apiError.localizedDescription)
        }

        return error.localizedDescription
    }

    func resolvedMihomoBinaryPath() -> String? {
        if let detected = processManager.detectedBinaryPath,
           !detected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return detected
        }

        let current = mihomoBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || current == "-" {
            return nil
        }
        return current
    }

    func ensureTunPermissions(requestIfMissing: Bool) async throws {
        guard let binaryPath = resolvedMihomoBinaryPath() else {
            throw TunPermissionServiceError.coreBinaryNotFound
        }

        do {
            try tunPermissionService.validateCurrentPermissions(binaryPath: binaryPath)
        } catch TunPermissionServiceError.permissionMissing {
            guard requestIfMissing else {
                throw TunPermissionServiceError.permissionMissing
            }
            appendLog(level: "info", message: tr("log.tun.permission_requesting"))
            try await tunPermissionService.grantPermissions(binaryPath: binaryPath)
            appendLog(level: "info", message: tr("log.tun.permission_granted"))
        }
    }

    func verifyTunRuntimeState(expectedEnabled: Bool) async throws {
        let maxAttempts = 32
        for _ in 0..<maxAttempts {
            do {
                let config = try await fetchRuntimeConfigSnapshot()
                let current = config.tunEnabled ?? false
                if isTunEnabled != current {
                    isTunEnabled = current
                }
                if current == expectedEnabled {
                    return
                }
            } catch {
                // Ignore transient API failures while core is restarting.
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw TunModeError.runtimeStateMismatch(expected: expectedEnabled)
    }

    func patchTunConfig(enable: Bool) async throws {
        let client = try clientOrThrow()
        var tunBody: [String: JSONValue] = ["enable": .bool(enable)]

        if enable, await !self.selectedConfigDeclaresTunStack() {
            tunBody["stack"] = .string("mixed")
        }

        var body: [String: JSONValue] = ["tun": .object(tunBody)]
        if enable {
            body["dns"] = .object(["enable": .bool(true)])
        }
        try await client.requestNoResponse(.patchConfigs(body: body))
    }

    func ensureTunMixedStackOnStartupIfNeeded() async {
        guard self.isRuntimeRunning else { return }

        do {
            let config = try await fetchRuntimeConfigSnapshot()
            guard config.tunEnabled == true else { return }
            let hasConfiguredStack = await self.selectedConfigDeclaresTunStack()

            let client = try clientOrThrow()
            var body: [String: JSONValue] = [
                "dns": .object(["enable": .bool(true)]),
            ]
            if !hasConfiguredStack {
                body["tun"] = .object(["stack": .string("mixed")])
            }
            try await client.requestNoResponse(.patchConfigs(body: body))
            if !hasConfiguredStack {
                _ = try await fetchRuntimeConfigSnapshot()
            }
        } catch {
            appendLog(level: "error", message: tr("log.tun.startup_check_failed", self.tunErrorMessage(error)))
        }
    }

    func selectedConfigDeclaresTunStack() async -> Bool {
        guard
            let configPath = await resolveSelectedConfigPath(),
            self.configFileDeclaresTunBlockKey("stack", at: configPath)
        else {
            return false
        }
        return true
    }

    func configFileDeclaresTunEnabled(at configPath: String) -> Bool {
        self.configFileDeclaresTunBlockKey("enable", expectedValue: "true", at: configPath)
    }

    private func configFileDeclaresTunBlockKey(
        _ key: String,
        expectedValue: String? = nil,
        at configPath: String) -> Bool
    {
        guard
            let raw = try? String(contentsOfFile: configPath, encoding: .utf8)
        else {
            return false
        }

        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let tunRange = self.topLevelBlockRange(for: "tun", lines: lines) else { return false }
        return self.childLineExists(for: key, expectedValue: expectedValue, lines: lines, range: tunRange)
    }

    private func childLineExists(
        for key: String,
        expectedValue: String? = nil,
        lines: [String],
        range: Range<Int>) -> Bool
    {
        for index in (range.lowerBound + 1)..<range.upperBound {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let leadingSpaces = line.prefix { $0 == " " || $0 == "\t" }.count
            guard leadingSpaces > 0 else { continue }

            let content = String(line.dropFirst(leadingSpaces)).trimmingCharacters(in: .whitespaces)
            let normalizedContent = content.lowercased()
            let keyPrefix = "\(key.lowercased()):"
            guard normalizedContent == keyPrefix || normalizedContent.hasPrefix("\(keyPrefix) ") else {
                continue
            }

            if let expectedValue {
                let actualValue = normalizedContent
                    .dropFirst(keyPrefix.count)
                    .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if actualValue == expectedValue.lowercased() {
                    return true
                }
            } else {
                return true
            }
        }
        return false
    }

    private func topLevelBlockRange(for key: String, lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { self.isTopLevelKeyLine($0, key: key) }) else {
            return nil
        }

        var end = lines.count
        if start + 1 < lines.count {
            for index in (start + 1)..<lines.count where self.isTopLevelMappingLine(lines[index]) {
                end = index
                break
            }
        }
        return start..<end
    }

    private func isTopLevelKeyLine(_ line: String, key: String) -> Bool {
        guard line.prefix(while: { $0 == " " || $0 == "\t" }).isEmpty else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
        return trimmed == "\(key):" || trimmed.hasPrefix("\(key): ")
    }

    private func isTopLevelMappingLine(_ line: String) -> Bool {
        guard line.prefix(while: { $0 == " " || $0 == "\t" }).isEmpty else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
        return trimmed.contains(":")
    }

    func refreshTunStatusFromRuntimeConfig() async {
        do {
            let config = try await fetchRuntimeConfigSnapshot()
            if let tunEnabled = config.tunEnabled, isTunEnabled != tunEnabled {
                isTunEnabled = tunEnabled
            }
        } catch {
            // Keep current UI state when runtime config refresh is unavailable.
        }
    }
}
