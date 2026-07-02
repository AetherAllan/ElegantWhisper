import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()
    private var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: PermissionOnboardingWindowController?
    private var lastMessage = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupStatusItem()
        controller.onChange = { [weak self] in
            self?.rebuildMenu()
        }
        controller.onUserMessage = { [weak self] message in
            self?.lastMessage = message
            self?.rebuildMenu()
        }
        controller.start()
        rebuildMenu()
        showInitialWindow()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        onboardingWindow?.refresh()
        if controller.permissionStatus().missingTitles.isEmpty {
            controller.startHotkeyMonitorIfPermitted()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // ElegantWhisper is a background utility with a Dock settings window. Closing that window
        // must not kill the process, because the global keyboard monitor lives in AppController.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopHotkeyMonitor()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = AppConstants.productName
        statusItem = item
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let toggleTitle: String
        switch controller.state.mode {
        case .recording:
            toggleTitle = "Stop and Transcribe"
        case .preparing:
            toggleTitle = "Cancel Preparing"
        default:
            toggleTitle = "Start Recording"
        }
        menu.addItem(NSMenuItem(title: toggleTitle, action: #selector(toggleRecording), keyEquivalent: ""))

        let cancel = NSMenuItem(title: "Cancel Recording", action: #selector(cancelRecording), keyEquivalent: "")
        cancel.isEnabled = [.preparing, .recording, .transcribing, .refining].contains(controller.state.mode)
        menu.addItem(cancel)

        menu.addItem(.separator())
        let status = NSMenuItem(title: "Status: \(controller.state.mode.title)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if !lastMessage.isEmpty {
            let message = NSMenuItem(title: lastMessage, action: nil, keyEquivalent: "")
            message.isEnabled = false
            menu.addItem(message)
        }

        menu.addItem(languageMenu())
        let llm = NSMenuItem(title: "LLM Refinement", action: #selector(toggleLLM), keyEquivalent: "")
        llm.state = SettingsStore.shared.llmEnabled ? .on : .off
        menu.addItem(llm)

        menu.addItem(NSMenuItem(title: "Open \(AppConstants.productName)", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(permissionMenu())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.title = [.preparing, .recording].contains(controller.state.mode) ? "● \(AppConstants.productName)" : AppConstants.productName
    }

    private func languageMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for language in RecognitionLanguage.allCases {
            let languageItem = NSMenuItem(title: language.menuTitle, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            languageItem.representedObject = language.rawValue
            languageItem.state = SettingsStore.shared.language == language ? .on : .off
            submenu.addItem(languageItem)
        }
        item.submenu = submenu
        return item
    }

    private func permissionMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Permissions Status", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let status = controller.permissionStatus()

        submenu.addItem(disabledItem("Microphone: \(status.microphoneDetail)"))
        submenu.addItem(NSMenuItem(title: "Open Microphone Settings", action: #selector(openMicrophoneSettings), keyEquivalent: ""))
        submenu.addItem(.separator())
        submenu.addItem(disabledItem("Speech Recognition: \(status.speechDetail)"))
        submenu.addItem(NSMenuItem(title: "Open Speech Settings", action: #selector(openSpeechSettings), keyEquivalent: ""))
        submenu.addItem(.separator())
        submenu.addItem(disabledItem("Accessibility: \(status.accessibilityDetail)"))
        submenu.addItem(NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        submenu.addItem(.separator())
        submenu.addItem(disabledItem("Input Monitoring: \(status.inputMonitoringDetail)"))
        submenu.addItem(disabledItem(status.inputMonitoringDiagnostics))
        submenu.addItem(NSMenuItem(title: "Open Input Monitoring Settings", action: #selector(openInputMonitoringSettings), keyEquivalent: ""))

        if !status.missingTitles.isEmpty {
            item.title = "Permissions Status: Missing \(status.missingTitles.joined(separator: ", "))"
            if let hint = status.rebuildHint {
                submenu.addItem(.separator())
                submenu.addItem(disabledItem(hint))
            }
            submenu.addItem(disabledItem("Running from: \(status.bundlePath)"))
        }
        item.submenu = submenu
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleRecording() {
        controller.toggleRecording()
    }

    @objc private func cancelRecording() {
        controller.cancelCurrentOperation()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = RecognitionLanguage(rawValue: raw)
        else {
            return
        }
        controller.setLanguage(language)
    }

    @objc private func toggleLLM() {
        controller.setLLMEnabled(!SettingsStore.shared.llmEnabled)
    }

    @objc private func showSettings() {
        showMainWindow()
    }

    @objc private func openMicrophoneSettings() {
        controller.openMicrophoneSettings()
    }

    @objc private func openSpeechSettings() {
        controller.openSpeechSettings()
    }

    @objc private func openAccessibilitySettings() {
        controller.openAccessibilitySettings()
    }

    @objc private func openInputMonitoringSettings() {
        controller.openInputMonitoringSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showInitialWindow() {
        if controller.permissionStatus().missingTitles.isEmpty {
            controller.startHotkeyMonitorIfPermitted()
            showMainWindow()
        } else {
            showOnboarding()
        }
    }

    private func showOnboarding() {
        let onboarding = PermissionOnboardingWindowController()
        onboarding.onComplete = { [weak self] in
            self?.controller.startHotkeyMonitorIfPermitted()
            self?.showMainWindow()
            self?.rebuildMenu()
        }
        onboardingWindow = onboarding
        onboarding.showWindow(nil)
    }

    private func showMainWindow() {
        if settingsWindow == nil {
            settingsWindow = controller.settingsWindowController()
        }
        settingsWindow?.showWindow(nil)
    }
}
