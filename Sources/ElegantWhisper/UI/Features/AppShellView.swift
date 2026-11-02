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
            .safeAreaInset(edge: .bottom) {
                SidebarStatusFooter()
                    .padding(12)
            }
        } detail: {
            switch model.route {
            case .home: HomeView()
            case .history: HistoryView()
            case .dictionary: DictionaryView()
            case .styles: StylesView()
            case .settings: AppSettingsView()
            case .about: AboutView()
            }
        }
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
            HStack(spacing: 5) {
                Keycap("Right ⌥")
                Text(model.currentLanguage.menuTitle)
                if model.llmEnabled {
                    Image(systemName: "sparkles")
                        .help("LLM polishing is on")
                }
            }
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
