import AppKit
import Combine

@MainActor
final class NativeConfigurationManagerWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate
{
    enum Mode: Equatable {
        case scene
        case clash
    }

    private let appState: AppState
    private let mode: Mode
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let listTitleLabel = NSTextField(labelWithString: "")
    private let importLocalButton = NSButton(title: "", target: nil, action: nil)
    private let importRemoteButton = NSButton(title: "", target: nil, action: nil)
    private let updateButton = NSButton(title: "", target: nil, action: nil)

    private var entries: [ManagedConfigFile] = []
    private var observers: [AnyCancellable] = []
    private var isBusy = false

    init(appState: AppState, mode: Mode) {
        self.appState = appState
        self.mode = mode

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 300)
        window.center()
        super.init(window: window)

        self.configureWindow()
        self.buildContentView()
        self.bindState()
        self.refreshFromState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        switch self.mode {
        case .scene:
            self.appState.reloadSceneConfiguration()
        case .clash:
            self.appState.reloadConfigFileList()
        }
        self.refreshFromState()
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureWindow() {
        guard let window else { return }
        window.delegate = self
        window.level = .statusBar
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.titleVisibility = .visible
    }

    private func buildContentView() {
        guard let window else { return }

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(listContainer)

        self.listTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        self.listTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(self.listTitleLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("configuration"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 360
        column.width = 440
        self.tableView.addTableColumn(column)
        self.tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        self.tableView.headerView = nil
        self.tableView.rowHeight = 38
        self.tableView.intercellSpacing = NSSize(width: 0, height: 2)
        self.tableView.usesAlternatingRowBackgroundColors = true
        self.tableView.selectionHighlightStyle = .none
        self.tableView.delegate = self
        self.tableView.dataSource = self

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = self.tableView
        listContainer.addSubview(scrollView)

        self.emptyLabel.font = .systemFont(ofSize: 13)
        self.emptyLabel.textColor = .secondaryLabelColor
        self.emptyLabel.alignment = .center
        self.emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(self.emptyLabel)

        let actionStack = NSStackView(views: [
            self.importLocalButton,
            self.importRemoteButton,
            self.updateButton,
        ])
        actionStack.orientation = .vertical
        actionStack.alignment = .leading
        actionStack.spacing = 10
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(actionStack)

        [self.importLocalButton, self.importRemoteButton, self.updateButton].forEach { button in
            button.bezelStyle = .rounded
            button.target = self
            button.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }
        self.importLocalButton.action = #selector(self.importLocalConfiguration(_:))
        self.importRemoteButton.action = #selector(self.importRemoteConfiguration(_:))
        self.updateButton.action = #selector(self.updateRemoteConfigurations(_:))

        NSLayoutConstraint.activate([
            listContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            listContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            listContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            listContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),

            self.listTitleLabel.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            self.listTitleLabel.topAnchor.constraint(equalTo: listContainer.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: self.listTitleLabel.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),

            self.emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            self.emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            self.emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 12),
            self.emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -12),

            actionStack.leadingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: 20),
            actionStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            actionStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
        ])
    }

    private func bindState() {
        self.observers = [
            self.appState.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshFromState()
                }
            },
        ]
    }

    private func refreshFromState() {
        switch self.mode {
        case .scene:
            self.entries = self.appState.managedSceneConfigFiles()
        case .clash:
            self.entries = self.appState.managedClashConfigFiles()
        }

        self.syncLocalizedText()
        self.emptyLabel.isHidden = !self.entries.isEmpty
        self.tableView.reloadData()

        let clashMutationsEnabled = self.appState.canAdjustCoreControlsManually
            && !self.appState.isCoreActionProcessing
            && !self.isBusy
        switch self.mode {
        case .scene:
            self.importLocalButton.isEnabled = !self.isBusy
            self.importRemoteButton.isEnabled = !self.isBusy
            self.updateButton.isEnabled = !self.isBusy
                && self.appState.sceneRemoteConfigURLStorage.trimmedNonEmpty != nil
        case .clash:
            self.importLocalButton.isEnabled = clashMutationsEnabled
            self.importRemoteButton.isEnabled = clashMutationsEnabled
            self.updateButton.isEnabled = clashMutationsEnabled
        }
    }

    private func syncLocalizedText() {
        guard let window else { return }
        switch self.mode {
        case .scene:
            window.title = self.local("场景配置文件管理", "Scene Configuration Manager")
            self.listTitleLabel.stringValue = self.local("场景配置文件", "Scene Configuration")
            self.emptyLabel.stringValue = self.local("暂无场景配置文件", "No scene configuration")
            self.updateButton.title = self.local("更新订阅链接", "Update Subscription")
        case .clash:
            window.title = self.local("Clash 配置文件管理", "Clash Configuration Manager")
            self.listTitleLabel.stringValue = self.local("Clash 配置文件", "Clash Configurations")
            self.emptyLabel.stringValue = self.local("暂无 Clash 配置文件", "No Clash configurations")
            self.updateButton.title = self.local("更新全部订阅", "Update All Subscriptions")
        }
        self.importLocalButton.title = self.local("导入本地配置", "Import Local")
        self.importRemoteButton.title = self.local("导入订阅链接", "Import Subscription")
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        self.entries.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int) -> NSView?
    {
        guard self.entries.indices.contains(row) else { return nil }
        let entry = self.entries[row]
        let cell = NSTableCellView()

        let sourceLabel = NSTextField(labelWithString: self.sourceTitle(entry.source))
        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sourceLabel.textColor = entry.source == .subscription ? .systemBlue : .secondaryLabelColor
        sourceLabel.alignment = .left
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(sourceLabel)

        let fileNameLabel = NSTextField(labelWithString: entry.fileName)
        fileNameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(fileNameLabel)

        var constraints = [
            sourceLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            sourceLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            sourceLabel.widthAnchor.constraint(equalToConstant: 92),
            fileNameLabel.leadingAnchor.constraint(equalTo: sourceLabel.trailingAnchor, constant: 8),
            fileNameLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ]

        if self.mode == .clash {
            let deleteButton = NSButton(
                title: self.local("删除", "Delete"),
                target: self,
                action: #selector(self.deleteConfiguration(_:)))
            deleteButton.bezelStyle = .rounded
            deleteButton.controlSize = .small
            deleteButton.isEnabled = self.appState.canAdjustCoreControlsManually
                && !self.appState.isCoreActionProcessing
                && !self.isBusy
            deleteButton.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(deleteButton)
            constraints.append(contentsOf: [
                deleteButton.leadingAnchor.constraint(greaterThanOrEqualTo: fileNameLabel.trailingAnchor, constant: 8),
                deleteButton.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                deleteButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            constraints.append(fileNameLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8))
        }

        NSLayoutConstraint.activate(constraints)
        return cell
    }

    private func sourceTitle(_ source: ManagedConfigSource) -> String {
        switch source {
        case .local:
            self.local("本地", "Local")
        case .subscription:
            self.local("订阅", "Subscription")
        }
    }

    @objc
    private func importLocalConfiguration(_ sender: Any?) {
        guard !self.isBusy else { return }
        if self.mode == .clash, !self.appState.canAdjustCoreControlsManually {
            return
        }

        self.isBusy = true
        self.refreshFromState()
        switch self.mode {
        case .scene:
            self.appState.importSceneConfigurationFile()
        case .clash:
            self.appState.importLocalConfigFile()
            self.appState.reloadConfigFileList()
        }
        self.isBusy = false
        self.refreshFromState()
    }

    @objc
    private func importRemoteConfiguration(_ sender: Any?) {
        guard !self.isBusy else { return }
        if self.mode == .clash, !self.appState.canAdjustCoreControlsManually {
            return
        }

        self.performAsyncOperation { [weak self] in
            guard let self else { return }
            switch self.mode {
            case .scene:
                await self.appState.importRemoteSceneConfigurationFile()
            case .clash:
                await self.appState.importRemoteConfigFile()
                self.appState.reloadConfigFileList()
            }
        }
    }

    @objc
    private func updateRemoteConfigurations(_ sender: Any?) {
        guard !self.isBusy else { return }
        if self.mode == .clash, !self.appState.canAdjustCoreControlsManually {
            return
        }

        self.performAsyncOperation { [weak self] in
            guard let self else { return }
            switch self.mode {
            case .scene:
                await self.appState.updateRemoteSceneConfigurationFile()
            case .clash:
                await self.appState.updateAllRemoteConfigFiles()
                self.appState.reloadConfigFileList()
            }
        }
    }

    @objc
    private func deleteConfiguration(_ sender: NSButton) {
        guard self.mode == .clash else { return }
        let row = self.tableView.row(for: sender)
        guard self.entries.indices.contains(row) else { return }
        let entry = self.entries[row]

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = self.local("删除 Clash 配置文件？", "Delete Clash Configuration?")
        var message = self.local(
            "将从磁盘删除“\(entry.fileName)”。如果它来自订阅，对应的订阅链接也会解除。",
            "\(entry.fileName) will be deleted from disk. Its subscription link will also be removed if present.")
        if entry.fileName == self.appState.selectedConfigName, self.appState.isRuntimeRunning {
            message += self.local(
                "\n\n这是当前使用的配置。删除后将自动切换到其他配置并重启核心；没有剩余配置时核心将停止。",
                "\n\nThis configuration is currently in use. ClashMenu will switch to another configuration and restart the core, or stop it if none remain.")
        }
        alert.informativeText = message
        alert.addButton(withTitle: self.local("删除", "Delete"))
        alert.addButton(withTitle: self.local("取消", "Cancel"))

        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor [weak self] in
                self?.performDelete(fileName: entry.fileName)
            }
        }
    }

    private func performDelete(fileName: String) {
        self.performAsyncOperation { [weak self] in
            guard let self else { return }
            if let message = await self.appState.deleteClashConfigFile(named: fileName) {
                self.presentError(message)
            }
        }
    }

    private func performAsyncOperation(_ operation: @escaping @MainActor () async -> Void) {
        guard !self.isBusy else { return }
        self.isBusy = true
        self.refreshFromState()
        Task { @MainActor [weak self] in
            await operation()
            guard let self else { return }
            self.isBusy = false
            self.refreshFromState()
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = self.local("操作失败", "Operation Failed")
        alert.informativeText = message
        alert.addButton(withTitle: self.local("确定", "OK"))
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            self.appState.prepareModalWindowPresentation()
            self.appState.configureModalWindow(alert.window)
            alert.runModal()
        }
    }

    private func local(_ zh: String, _ en: String) -> String {
        self.appState.uiLanguage == .zhHans ? zh : en
    }
}
