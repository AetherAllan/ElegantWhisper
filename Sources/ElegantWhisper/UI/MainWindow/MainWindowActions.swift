import AppKit

@MainActor
extension MainWindowController {
    @objc func providerChanged() {
        polishingDirty = true
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
        polishingDirty = false
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
        guard let pack = selectedStylePack() else {
            showNotice("No style pack selected")
            return
        }
        guard stylePacks.resetBuiltin(id: pack.id) else {
            showNotice("Only built-in style packs can be reset")
            return
        }
        populateStylePackPopup()
        loadSelectedStylePackPrompt()
        showNotice("Built-in style pack reset")
        renderCurrentPage()
    }

    @objc func saveGeneralSettings() {
        settings.language = selectedLanguage(in: languagePopup)
        settings.keepClipboardWithoutTarget = clipboardCheckbox.state == .on
        settings.saveHistory = historyCheckbox.state == .on
        settings.postEditLearningEnabled = learningCheckbox.state == .on
        generalDirty = false
        showNotice("Settings saved")
        renderCurrentPage()
    }

    @objc func markPolishingDirty() {
        polishingDirty = true
    }

    @objc func markGeneralDirty() {
        generalDirty = true
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
            language: selectedLanguage(in: dictionaryLanguagePopup)
        )
        guard ok else {
            showNotice("Dictionary term is empty")
            return
        }
        dictionaryTermField.stringValue = ""
        showNotice("Dictionary term saved")
        renderCurrentPage()
    }

    @objc func deleteDictionaryTerm(_ sender: NSButton) {
        guard let id = uuid(from: sender) else {
            return
        }
        dictionary.delete(id: id)
        showNotice("Dictionary term deleted")
        renderCurrentPage()
    }

    @objc func copyHistory(_ sender: NSButton) {
        guard let item = historyItem(from: sender) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        showNotice("Copied history item")
    }

    @objc func useHistoryAsDictionaryTerm(_ sender: NSButton) {
        guard let item = historyItem(from: sender) else {
            return
        }
        currentPage = .dictionary
        updateSidebarSelection()
        dictionaryTermField.stringValue = item.text
        showNotice("Edit the term before saving")
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

    func historyItem(from sender: NSButton) -> HistoryItem? {
        guard let id = uuid(from: sender) else {
            return nil
        }
        return history.items().first { $0.id == id }
    }

    func uuid(from sender: NSButton) -> UUID? {
        guard let rawValue = sender.identifier?.rawValue else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }

    @objc func acceptLearningCandidate(_ sender: NSButton) {
        guard let candidate = learningCandidate(from: sender) else {
            return
        }
        _ = dictionary.add(term: candidate.replacement, language: candidate.language)
        LearningCandidateStore.shared.remove(id: candidate.id)
        showNotice("Added")
        renderCurrentPage()
    }

    @objc func dismissLearningCandidate(_ sender: NSButton) {
        guard let candidate = learningCandidate(from: sender) else {
            return
        }
        LearningCandidateStore.shared.remove(id: candidate.id)
        showNotice("Dismissed")
        renderCurrentPage()
    }

    func learningCandidate(from sender: NSButton) -> LearningCandidate? {
        guard let id = uuid(from: sender) else {
            return nil
        }
        return LearningCandidateStore.shared.items().first { $0.id == id }
    }
}
