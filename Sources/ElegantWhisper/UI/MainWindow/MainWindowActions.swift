import AppKit

@MainActor
extension MainWindowController {
    @objc func providerChanged() {
        let provider = selectedProvider()
        if let baseURL = provider.defaultBaseURL {
            baseURLField.stringValue = baseURL
        }
        if let model = provider.defaultModel {
            modelField.stringValue = model
        }
        showNotice(provider.note)
        renderCurrentPage()
    }

    @objc func savePolishing() {
        // API keys are intentionally allowed to become empty. Clearing the field is the user's way
        // to disable remote polishing without leaving stale credentials in Keychain.
        settings.llmProvider = selectedProvider()
        settings.llmEnabled = llmCheckbox.state == .on
        settings.apiBaseURL = baseURLField.stringValue
        settings.apiKey = apiKeyField.stringValue
        settings.model = modelField.stringValue
        settings.requestTimeout = TimeInterval(timeoutField.doubleValue)
        showNotice("Polishing settings saved")
        renderCurrentPage()
    }

    @objc func stylePackChanged() {
        guard let pack = selectedStylePack() else {
            return
        }
        stylePacks.setActive(id: pack.id)
        loadSelectedStylePackPrompt()
        showNotice("Style pack active: \(pack.name)")
        renderCurrentPage()
    }

    @objc func saveStylePack() {
        guard var pack = selectedStylePack() else {
            showNotice("No style pack selected")
            return
        }
        pack.systemPrompt = stylePromptView.string
        pack.active = true
        stylePacks.save(pack)
        updateEffectivePromptPreview()
        showNotice("Style pack saved")
        renderCurrentPage()
    }

    @objc func resetStylePack() {
        guard let pack = selectedStylePack(), pack.builtIn else {
            showNotice("Only built-in style packs can be reset")
            return
        }
        guard stylePacks.resetBuiltin(id: pack.id) else {
            showNotice("Unable to reset style pack")
            return
        }
        loadValues()
        showNotice("Built-in style pack reset")
        renderCurrentPage()
    }

    @objc func saveGeneralSettings() {
        settings.language = selectedLanguage(in: languagePopup)
        settings.keepClipboardWithoutTarget = clipboardCheckbox.state == .on
        settings.saveHistory = historyCheckbox.state == .on
        showNotice("Settings saved")
        renderCurrentPage()
    }

    @objc func testConnection() {
        savePolishing()
        showNotice("Testing LLM connection...")
        refiner.testConnection { [weak self] ok, message in
            self?.showNotice(ok ? message : "Connection failed: \(message)")
        }
    }

    @objc func reloadVisiblePage() {
        renderCurrentPage()
    }

    @objc func clearHistory() {
        history.clear()
        showNotice("History cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.renderCurrentPage()
        }
    }

    @objc func addDictionaryTerm() {
        let ok = dictionary.add(
            term: dictionaryTermField.stringValue,
            aliases: parseAliases(dictionaryAliasesField.stringValue),
            language: selectedLanguage(in: dictionaryLanguagePopup)
        )
        guard ok else {
            showNotice("Dictionary term is empty")
            return
        }
        dictionaryTermField.stringValue = ""
        dictionaryAliasesField.stringValue = ""
        showNotice("Dictionary term saved")
        renderCurrentPage()
    }

    @objc func deleteDictionaryTerm(_ sender: DictionaryActionButton) {
        guard let id = sender.entryID else {
            return
        }
        dictionary.delete(id: id)
        showNotice("Dictionary term deleted")
        renderCurrentPage()
    }

    @objc func copyHistory(_ sender: HistoryTextButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.historyText, forType: .string)
        showNotice("Copied history item")
    }

    @objc func useHistoryAsDictionaryTerm(_ sender: HistoryTextButton) {
        currentPage = .dictionary
        updateSidebarSelection()
        dictionaryTermField.stringValue = sender.historyText
        dictionaryAliasesField.stringValue = ""
        showNotice("Edit the term and add wrong forms before saving")
        renderCurrentPage()
    }

    @objc func openMicrophoneSettings() {
        controller.openMicrophoneSettings()
    }

    @objc func openSpeechSettings() {
        controller.openSpeechSettings()
    }

    @objc func openAccessibilitySettings() {
        controller.openAccessibilitySettings()
    }

    @objc func openInputMonitoringSettings() {
        controller.openInputMonitoringSettings()
    }

    func parseAliases(_ text: String) -> [String] {
        // Do not split on spaces: many correct terms and wrong recognitions are English phrases.
        text.components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
