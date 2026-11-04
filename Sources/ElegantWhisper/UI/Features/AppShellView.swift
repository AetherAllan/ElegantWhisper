import SwiftUI

struct AppShellView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $model.route) {
                Section {
                    ForEach(AppRoute.primary) { route in
                        Label(route.title, systemImage: route.symbolName)
                            .tag(route)
                    }
                }
                Section("Application") {
                    ForEach(AppRoute.application) { route in
                        Label(route.title, systemImage: route.symbolName)
                            .tag(route)
                    }
                }
            }
            .navigationTitle(AppConstants.productName)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            // Prism: the sidebar is page-black too, so the black toolbar above it is not a seam.
            // Standard keeps the system sidebar material.
            .scrollContentBackground(model.currentTheme == .prism ? .hidden : .automatic)
            .background(model.currentTheme == .prism ? PrismPalette.background : Color.clear)
            .safeAreaInset(edge: .bottom) {
                SidebarStatusFooter()
                    .padding(12)
            }
        } detail: {
            Group {
                switch model.route {
                case .home: HomeView()
                case .history: HistoryView()
                case .dictionary: DictionaryView()
                case .styles: StylesView()
                case .settings: AppSettingsView()
                case .about: AboutView()
                }
            }
            // One page color for every view: Forms, Lists, and text editors below lose their own
            // backdrops, so a page never shows two grays.
            .scrollContentBackground(.hidden)
            .background(model.currentTheme.pageBackground)
        }
        .environment(\.appTheme, model.currentTheme)
        // Prism is a dark look by design, whatever the system appearance.
        .preferredColorScheme(model.currentTheme == .prism ? .dark : nil)
        // Without this the toolbar stays system gray above the black page, a visible seam.
        .toolbarBackground(model.currentTheme.pageBackground, for: .windowToolbar)
        .toolbarBackgroundVisibility(model.currentTheme == .prism ? .visible : .automatic, for: .windowToolbar)
        .tint(model.currentTheme == .prism ? PrismPalette.accent : nil)
        .overlay(alignment: .bottom) {
            if !model.notice.isEmpty {
                NoticeToast(text: model.notice) { model.notice = "" }
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.notice)
        .task(id: model.notice) {
            guard !model.notice.isEmpty else { return }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                // A newer notice replaced this one; its own task handles dismissal.
                return
            }
            model.notice = ""
        }
        .onAppear { model.refreshAfterActivation() }
    }
}

/// Always-visible summary of what the hotkey will do right now.
private struct SidebarStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DictationStatusBadge(mode: model.mode)
            // One fact per line: the sidebar is narrow, and wrapping split "OpenRouter" and the
            // keycap mid-word.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Keycap("Right ⌥")
                    Text(model.currentLanguage.menuTitle)
                }
                if model.currentProvider != .apple {
                    // Online recognition is a privacy-relevant choice; keep it visible.
                    Label(model.currentProvider.title, systemImage: "cloud")
                }
                if model.llmEnabled {
                    Label(model.outputMode == .dictate ? "Dictate" : "Polishing", systemImage: "sparkles")
                }
            }
            .lineLimit(1)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardBackground(cornerRadius: 12)
    }
}

private struct NoticeToast: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}
