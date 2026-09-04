import Foundation

@MainActor
extension AppState {
    func runRefresh(_ block: () async throws -> Void) async {
        do {
            ensureAPIClient()
            try await block()
            apiStatus = .healthy
        } catch {
            apiStatus = .degraded
            appendLog(level: "error", message: error.localizedDescription)
        }
    }

    @discardableResult
    func runNoResponseAction(_ name: String, operation: () async throws -> Void) async -> String? {
        do {
            ensureAPIClient()
            try await operation()
            appendLog(level: "info", message: tr("log.action.success", name))
            return nil
        } catch {
            let message = error.localizedDescription
            appendLog(level: "error", message: tr("log.action.failed", name, message))
            return message
        }
    }
}
