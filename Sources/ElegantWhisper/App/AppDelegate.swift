import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = AppController()
    private var statusItem: NSStatusItem?
    private var mainWindow: MainWindowController?
    private var onboardingWindow: PermissionOnboardingWindowController?
    private weak var microphoneMenuItem: NSMenuItem?
    private var statusIcon: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()
        setupStatusItem()
        controller.onChange = { [weak self] in
            self?.rebuildMenu()
            self?.mainWindow?.refresh()
        }
        controller.onUserMessage = { [weak self] message in
            self?.mainWindow?.showNotice(message)
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
        controller.restoreOutputMuteOnTerminate()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusIcon = makeStatusIcon()
        if let button = item.button {
            button.image = statusIcon
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = AppConstants.productName
        }
        statusItem = item
    }

    private func makeStatusIcon() -> NSImage? {
        // StatusBarIcon.png: transparent glyph, 72px bitmap for Retina. Point size 22pt.
        guard let url = Bundle.main.url(forResource: "StatusBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else {
            return NSImage(systemSymbolName: "waveform", accessibilityDescription: AppConstants.productName)
        }
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = true
        return image
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: AppConstants.productName)
        appMenu.addItem(NSMenuItem(title: "About \(AppConstants.productName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(AppConstants.productName)", action: #selector(quit), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // AppKit text controls rely on the responder chain for editing commands. Without this
        // standard menu, secure text fields can focus correctly yet ignore Cmd+V.
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Open \(AppConstants.productName)", action: #selector(showMainWindowMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(languageMenu())
        let mic = microphoneMenu()
        microphoneMenuItem = mic
        menu.addItem(mic)
        let llm = NSMenuItem(title: "LLM Polishing", action: #selector(toggleLLM), keyEquivalent: "")
        llm.state = SettingsStore.shared.llmEnabled ? .on : .off
        menu.addItem(llm)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
        updateStatusItemAppearance()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else {
            return
        }
        button.title = ""
        button.image = statusIcon
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        // Keep template tint system-default. Red/black recording tints read as a solid blob
        // on dark menu bars; recording state already shows in the floating panel.
        button.contentTintColor = nil
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

    private func microphoneMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        populateMicrophoneSubmenu(submenu)
        item.submenu = submenu
        return item
    }

    private func populateMicrophoneSubmenu(_ submenu: NSMenu) {
        submenu.removeAllItems()
        let devices = AudioInputDevices.list()
        let currentUID = AudioInputDevices.currentUID()
        // Switching mid-capture leaves AVAudioEngine on the old HAL stream; only allow when idle.
        let canSwitch = controller.state.mode == .idle

        if devices.isEmpty {
            let empty = NSMenuItem(title: "No input devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }

        for device in devices {
            let deviceItem = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            deviceItem.representedObject = device.uid
            deviceItem.state = device.uid == currentUID ? .on : .off
            deviceItem.isEnabled = canSwitch
            submenu.addItem(deviceItem)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === microphoneMenuItem?.submenu {
            populateMicrophoneSubmenu(menu)
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = RecognitionLanguage(rawValue: raw)
        else {
            return
        }
        controller.setLanguage(language)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard controller.state.mode == .idle,
              let uid = sender.representedObject as? String
        else {
            return
        }
        Task { @MainActor in
            if await AudioInputDevices.select(uid: uid) {
                rebuildMenu()
            } else {
                showMicrophoneSwitchFailedAlert()
            }
        }
    }

    private func showMicrophoneSwitchFailedAlert() {
        let alert = NSAlert()
        alert.messageText = "Could not switch microphone"
        alert.informativeText = "The system default input device did not change. Try again, or pick another device in System Settings."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func toggleLLM() {
        controller.setLLMEnabled(!SettingsStore.shared.llmEnabled)
    }

    @objc private func showMainWindowMenu() {
        showMainWindow()
    }

    @objc private func showSettings() {
        showMainWindow()
        mainWindow?.showPage(.settings)
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
        if mainWindow == nil {
            mainWindow = controller.mainWindowController()
        }
        mainWindow?.showWindow(nil)
    }
}
