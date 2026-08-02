import AppKit
import Combine

@MainActor
final class NativeSettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    private let appState: AppState

    private let launchAtLoginButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let autoStopCoreOnNetworkDisconnectButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let autoStopCoreOnSystemSleepButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let recoveryCheckDelayLabel = NSTextField(labelWithString: "")
    private let recoveryCheckDelayField = NSTextField(string: "")
    private let recoveryCheckDelayStepper = NSStepper()
    private let languageLabel = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let generalSectionLabel = NSTextField(labelWithString: "")
    private let configurationSectionLabel = NSTextField(labelWithString: "")
    private let sceneConfigManagerButton = NSButton(title: "", target: nil, action: nil)
    private let clashConfigManagerButton = NSButton(title: "", target: nil, action: nil)
    private let proxySectionLabel = NSTextField(labelWithString: "")
    private let systemProxyBypassLabel = NSTextField(labelWithString: "")
    private let advancedSectionLabel = NSTextField(labelWithString: "")
    private let upgradeMihomoCoreButton = NSButton(title: "", target: nil, action: nil)
    private let flushFakeIPButton = NSButton(title: "", target: nil, action: nil)
    private let flushDNSButton = NSButton(title: "", target: nil, action: nil)

    private var observers: [AnyCancellable] = []
    private var selectedLanguageMap: [Int: AppLanguage] = [:]
    private var isEditingSystemProxyBypassText = false
    private lazy var sceneConfigManagerWindowController = NativeConfigurationManagerWindowController(
        appState: self.appState,
        mode: .scene)
    private lazy var clashConfigManagerWindowController = NativeConfigurationManagerWindowController(
        appState: self.appState,
        mode: .clash)
    private lazy var systemProxyBypassScrollView: NSScrollView = {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }()
    private lazy var systemProxyBypassTextView: NSTextView = {
        let textView = (self.systemProxyBypassScrollView.documentView as? NSTextView) ?? NSTextView()
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.delegate = self
        return textView
    }()

    init(appState: AppState) {
        self.appState = appState

        let contentRect = NSRect(x: 0, y: 0, width: 360, height: 500)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
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
        self.appState.refreshLaunchAtLoginStatus()
        self.refreshFromState()
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        self.refreshFromState()
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
        window.contentMinSize = NSSize(width: 360, height: 470)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
        ])

        let generalSection = self.makeSection(label: self.generalSectionLabel)
        let generalContent = self.makeSectionContentStack()
        let languageRow = self.makePopupRow(label: self.languageLabel, popup: self.languagePopup)
        generalContent.addArrangedSubview(languageRow)
        [
            self.launchAtLoginButton,
            self.autoStopCoreOnNetworkDisconnectButton,
            self.autoStopCoreOnSystemSleepButton,
        ].forEach { button in
            button.setButtonType(.switch)
            button.target = self
            button.alignment = .left
            button.setContentHuggingPriority(.required, for: .horizontal)
            generalContent.addArrangedSubview(button)
        }
        let recoveryDelayRow = self.makeStepperRow(
            label: self.recoveryCheckDelayLabel,
            field: self.recoveryCheckDelayField,
            stepper: self.recoveryCheckDelayStepper)
        generalContent.addArrangedSubview(recoveryDelayRow)
        generalSection.addArrangedSubview(generalContent)
        stack.addArrangedSubview(generalSection)
        stack.setCustomSpacing(20, after: generalSection)

        self.launchAtLoginButton.action = #selector(self.toggleLaunchAtLogin(_:))
        self.autoStopCoreOnNetworkDisconnectButton.action = #selector(self.toggleAutoStopCoreOnNetworkDisconnect(_:))
        self.autoStopCoreOnSystemSleepButton.action = #selector(self.toggleAutoStopCoreOnSystemSleep(_:))
        self.recoveryCheckDelayField.delegate = self
        self.recoveryCheckDelayStepper.target = self
        self.recoveryCheckDelayStepper.action = #selector(self.changeRecoveryCheckDelayStepper(_:))
        self.recoveryCheckDelayStepper.minValue = 1
        self.recoveryCheckDelayStepper.maxValue = 60
        self.recoveryCheckDelayStepper.increment = 1

        self.languagePopup.target = self
        self.languagePopup.action = #selector(self.changeLanguage(_:))

        let configurationSection = self.makeSection(label: self.configurationSectionLabel)
        let configurationContent = self.makeSectionContentStack()
        [self.sceneConfigManagerButton, self.clashConfigManagerButton].forEach { button in
            button.bezelStyle = .rounded
            button.target = self
            button.alignment = .left
            button.widthAnchor.constraint(equalToConstant: 180).isActive = true
            configurationContent.addArrangedSubview(button)
        }
        configurationSection.addArrangedSubview(configurationContent)
        stack.addArrangedSubview(configurationSection)
        stack.setCustomSpacing(20, after: configurationSection)

        self.sceneConfigManagerButton.action = #selector(self.openSceneConfigManager(_:))
        self.clashConfigManagerButton.action = #selector(self.openClashConfigManager(_:))

        let proxySection = self.makeSection(label: self.proxySectionLabel)
        let proxyContent = self.makeSectionContentStack()
        let bypassRow = self.makeTextViewSettingRow(
            label: self.systemProxyBypassLabel,
            scrollView: self.systemProxyBypassScrollView)
        proxyContent.addArrangedSubview(bypassRow)
        proxySection.addArrangedSubview(proxyContent)
        stack.addArrangedSubview(proxySection)
        stack.setCustomSpacing(30, after: proxySection)

        _ = self.systemProxyBypassTextView

        let advancedSection = self.makeSection(label: self.advancedSectionLabel)
        let actionsRow = self.makeSectionContentStack()
        self.upgradeMihomoCoreButton.bezelStyle = .rounded
        self.flushFakeIPButton.bezelStyle = .rounded
        self.flushDNSButton.bezelStyle = .rounded
        self.upgradeMihomoCoreButton.target = self
        self.flushFakeIPButton.target = self
        self.flushDNSButton.target = self
        self.upgradeMihomoCoreButton.action = #selector(self.upgradeMihomoCore(_:))
        self.flushFakeIPButton.action = #selector(self.flushFakeIP(_:))
        self.flushDNSButton.action = #selector(self.flushDNS(_:))
        actionsRow.addArrangedSubview(self.upgradeMihomoCoreButton)
        actionsRow.addArrangedSubview(self.flushFakeIPButton)
        actionsRow.addArrangedSubview(self.flushDNSButton)
        advancedSection.addArrangedSubview(actionsRow)
        stack.addArrangedSubview(advancedSection)
    }

    private func makePopupRow(label: NSTextField, popup: NSPopUpButton) -> NSView {
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.setContentHuggingPriority(.required, for: .horizontal)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        popup.widthAnchor.constraint(lessThanOrEqualToConstant: 116).isActive = true

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        popup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(popup)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: popup.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.topAnchor.constraint(equalTo: container.topAnchor),
            popup.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])

        return container
    }

    private func makeStepperRow(label: NSTextField, field: NSTextField, stepper: NSStepper) -> NSView {
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.setContentHuggingPriority(.required, for: .horizontal)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = .right
        field.controlSize = .small
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true

        stepper.translatesAutoresizingMaskIntoConstraints = false
        stepper.controlSize = .small

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(field)
        container.addSubview(stepper)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stepper.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            stepper.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            stepper.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])

        return container
    }

    private func makeTextViewSettingRow(label: NSTextField, scrollView: NSScrollView) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let contentSize = NSSize(width: 328, height: 82)
        scrollView.widthAnchor.constraint(equalToConstant: contentSize.width).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: contentSize.height).isActive = true

        container.addArrangedSubview(label)
        container.addArrangedSubview(scrollView)
        return container
    }

    private func makeSection(label: NSTextField) -> NSStackView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        section.addArrangedSubview(label)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 328).isActive = true
        section.addArrangedSubview(separator)
        return section
    }

    private func makeSectionContentStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
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
        self.syncLocalizedText()
        self.launchAtLoginButton.state = self.appState.launchAtLoginEnabled ? .on : .off
        self.autoStopCoreOnNetworkDisconnectButton.state = self.appState.autoStopCoreOnNetworkDisconnectEnabled ? .on : .off
        self.autoStopCoreOnSystemSleepButton.state = self.appState.autoStopCoreOnSystemSleepEnabled ? .on : .off
        self.recoveryCheckDelayField.stringValue = "\(self.appState.recoveryCheckDelaySeconds)"
        self.recoveryCheckDelayStepper.integerValue = self.appState.recoveryCheckDelaySeconds
        if !self.isEditingSystemProxyBypassText {
            self.systemProxyBypassTextView.string = self.formattedSystemProxyBypassListForDisplay()
        }
        self.upgradeMihomoCoreButton.isEnabled = self.appState.isRuntimeRunning

        for (tag, language) in self.selectedLanguageMap where language == self.appState.uiLanguage {
            self.languagePopup.selectItem(withTag: tag)
        }
    }

    private func syncLocalizedText() {
        guard let window else { return }
        window.title = self.local("设置", "Settings")
        self.generalSectionLabel.stringValue = self.local("通用设置", "General Settings")
        self.configurationSectionLabel.stringValue = self.local("配置文件", "Configurations")
        self.sceneConfigManagerButton.title = self.local("场景配置文件管理", "Scene Config Manager")
        self.clashConfigManagerButton.title = self.local("Clash 配置文件管理", "Clash Config Manager")
        self.proxySectionLabel.stringValue = self.local("代理设置", "Proxy Settings")
        self.advancedSectionLabel.stringValue = self.local("高级操作", "Advanced")
        self.launchAtLoginButton.title = self.tr("ui.settings.launch_at_login")
        self.autoStopCoreOnNetworkDisconnectButton.title = self.tr("ui.settings.auto_stop_core_on_network_disconnect")
        self.autoStopCoreOnSystemSleepButton.title = self.tr("ui.settings.auto_stop_core_on_system_sleep")
        self.recoveryCheckDelayLabel.stringValue = self.tr("ui.settings.recovery_check_delay")
        self.languageLabel.stringValue = self.tr("ui.settings.language")
        self.systemProxyBypassLabel.stringValue = self.tr("ui.settings.system_proxy_bypass_hosts")
        self.upgradeMihomoCoreButton.title = self.tr("ui.action.upgrade_mihomo_core")
        self.flushFakeIPButton.title = self.local("清理 FakeIP 缓存", "Clear FakeIP Cache")
        self.flushDNSButton.title = self.local("清理 DNS 缓存", "Clear DNS Cache")

        self.languagePopup.removeAllItems()
        self.selectedLanguageMap.removeAll()
        for (index, language) in AppLanguage.allCases.enumerated() {
            let title = switch language {
            case .zhHans:
                self.local("简体中文", "Simplified Chinese")
            case .en:
                "English"
            }
            self.languagePopup.addItem(withTitle: title)
            self.languagePopup.lastItem?.tag = index
            self.selectedLanguageMap[index] = language
        }

    }

    private func tr(_ key: String) -> String {
        L10n.t(key, language: self.appState.uiLanguage)
    }

    private func tr(_ key: String, _ args: CVarArg...) -> String {
        L10n.t(key, language: self.appState.uiLanguage, args: args)
    }

    private func local(_ zh: String, _ en: String) -> String {
        self.appState.uiLanguage == .zhHans ? zh : en
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = self.local("操作失败", "Operation Failed")
        alert.informativeText = message
        alert.addButton(withTitle: self.tr("ui.action.ok"))
        self.presentAlert(alert)
    }

    private func presentInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: self.tr("ui.action.ok"))
        self.presentAlert(alert)
    }

    func presentAlert(_ alert: NSAlert, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        self.appState.prepareModalWindowPresentation()
        self.appState.configureModalWindow(alert.window)

        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                completion?(response)
            }
            return
        }

        let response = alert.runModal()
        completion?(response)
    }

    @objc
    private func toggleLaunchAtLogin(_ sender: NSButton) {
        let enabled = sender.state == .on
        self.appState.applyLaunchAtLogin(enabled)
        if let message = self.appState.launchAtLoginErrorMessage {
            sender.state = self.appState.launchAtLoginEnabled ? .on : .off
            self.presentError(message)
        }
    }

    @objc
    private func toggleAutoStopCoreOnNetworkDisconnect(_ sender: NSButton) {
        self.appState.autoStopCoreOnNetworkDisconnectEnabled = sender.state == .on
    }

    @objc
    private func toggleAutoStopCoreOnSystemSleep(_ sender: NSButton) {
        self.appState.autoStopCoreOnSystemSleepEnabled = sender.state == .on
    }

    @objc
    private func changeRecoveryCheckDelayStepper(_ sender: NSStepper) {
        self.applyRecoveryCheckDelay(sender.integerValue)
    }

    @objc
    private func changeLanguage(_ sender: NSPopUpButton) {
        guard let language = self.selectedLanguageMap[sender.selectedTag()] else { return }
        self.appState.setUILanguage(language)
        self.refreshFromState()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field == self.recoveryCheckDelayField {
            self.applyRecoveryCheckDelay(Int(field.stringValue) ?? self.appState.recoveryCheckDelaySeconds)
            return
        }
    }

    private func applyRecoveryCheckDelay(_ seconds: Int) {
        self.appState.recoveryCheckDelaySeconds = seconds
        self.refreshFromState()
    }

    private func applySystemProxyBypassList(_ value: String) {
        self.appState.systemProxyBypassListText = value
        self.refreshFromState()
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView == self.systemProxyBypassTextView else { return }
        self.isEditingSystemProxyBypassText = false
        self.applySystemProxyBypassList(textView.string)
    }

    func textDidBeginEditing(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView == self.systemProxyBypassTextView else { return }
        self.isEditingSystemProxyBypassText = true
    }

    private func formattedSystemProxyBypassListForDisplay() -> String {
        self.appState.systemProxyBypassHosts.joined(separator: ",\n")
    }

    @objc
    private func upgradeMihomoCore(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.appState.upgradeCore()
            switch result {
            case let .updated(version):
                let resolvedVersion = version ?? self.appState.version
                let message = resolvedVersion.trimmedNonEmpty.map {
                    self.tr("app.core_upgrade.updated_version", $0)
                } ?? self.tr("app.core_upgrade.updated")
                self.presentInfo(
                    title: self.tr("app.core_upgrade.alert.updated.title"),
                    message: message)
            case let .alreadyLatest(version):
                let resolvedVersion = version ?? self.appState.version
                let message = resolvedVersion.trimmedNonEmpty.map {
                    self.tr("app.core_upgrade.already_latest_version", $0)
                } ?? self.tr("app.core_upgrade.already_latest")
                self.presentInfo(
                    title: self.tr("app.core_upgrade.alert.latest.title"),
                    message: message)
            case let .failed(message):
                self.presentError(message)
            }
        }
    }

    @objc
    private func flushFakeIP(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let message = await self.appState.runNoResponseAction(
                self.local("清理 FakeIP 缓存", "Clear FakeIP Cache"),
                operation: {
                    try await self.appState.clientOrThrow().requestNoResponse(.flushFakeIPCache)
                })
            {
                self.presentError(message)
            }
        }
    }

    @objc
    private func flushDNS(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let message = await self.appState.runNoResponseAction(
                self.local("清理 DNS 缓存", "Clear DNS Cache"),
                operation: {
                    try await self.appState.clientOrThrow().requestNoResponse(.flushDNSCache)
                })
            {
                self.presentError(message)
            }
        }
    }

    @objc
    private func openSceneConfigManager(_ sender: Any?) {
        self.sceneConfigManagerWindowController.present()
    }

    @objc
    private func openClashConfigManager(_ sender: Any?) {
        self.clashConfigManagerWindowController.present()
    }

}
