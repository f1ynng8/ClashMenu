@MainActor
extension AppState {
    func closeAllConnections() async {
        await self.runConnectionMutation(
            actionName: tr("log.action_name.close_all_connections"),
            endpoint: .closeAllConnections)
    }

    private func runConnectionMutation(actionName: String, endpoint: Endpoint) async {
        // DRY: shared post-mutation flow for connection operations.
        await runNoResponseAction(actionName) {
            try await self.clientOrThrow().requestNoResponse(endpoint)
        }
    }
}
