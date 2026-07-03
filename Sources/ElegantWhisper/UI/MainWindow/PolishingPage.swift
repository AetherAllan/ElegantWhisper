import AppKit

@MainActor
extension MainWindowController {
    func polishingPage() -> NSStackView {
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        stylePackPopup.target = self
        stylePackPopup.action = #selector(stylePackChanged)
        llmCheckbox.target = self
        llmCheckbox.action = #selector(markPolishingDirty)
        baseURLField.delegate = self
        apiKeyField.delegate = self
        modelField.delegate = self
        timeoutField.delegate = self

        let form = MainWindowUI.form([
            ("Provider", providerPopup),
            ("API Base URL", baseURLField),
            ("API Key", apiKeyField),
            ("Model", modelField),
            ("Timeout Seconds", timeoutField)
        ])
        let buttons = MainWindowUI.buttonRow([
            MainWindowUI.button("Test Connection", target: self, action: #selector(testConnection)),
            MainWindowUI.button("Save Polishing", target: self, action: #selector(savePolishing), primary: true)
        ])

        let styleForm = MainWindowUI.form([
            ("Active Style", stylePackPopup),
            ("System Prompt", stylePromptScroll),
            ("Effective Prompt", effectivePromptScroll)
        ])
        let styleButtons = MainWindowUI.buttonRow([
            MainWindowUI.button("Save Style", target: self, action: #selector(saveStylePack), primary: true),
            MainWindowUI.button("Reset Built-in", target: self, action: #selector(resetStylePack))
        ])

        let provider = selectedProvider()
        let safety = MainWindowUI.body("""
        \(provider.note)

        Polishing here means conservative correction only. The model must not summarize, translate, expand, delete, or change meaning. If the request fails, ElegantWhisper uses the original transcript.
        """)
        safety.maximumNumberOfLines = 0

        return MainWindowUI.page(
            title: "Polishing",
            subtitle: "OpenAI-compatible correction for obvious speech recognition errors.",
            views: [
                MainWindowUI.card([llmCheckbox, form, buttons]),
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Style Pack", selectedStylePack()?.name ?? "None"),
                    MainWindowUI.body("Use \(LLMPromptBuilder.hotwordPlaceholder) where dictionary terms should be injected."),
                    styleForm,
                    styleButtons
                ]),
                MainWindowUI.card([
                    MainWindowUI.sectionHeader("Behavior", "Conservative correction"),
                    safety
                ])
            ]
        )
    }
}
