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
                    Label(AppRoute.settings.title, systemImage: AppRoute.settings.symbolName)
                        .tag(AppRoute.settings)
                }
            }
            .navigationTitle(AppConstants.productName)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                if !model.notice.isEmpty {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(model.notice).lineLimit(2)
                        Spacer()
                        Button("Dismiss") { model.notice = "" }
                            .buttonStyle(.plain)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    Divider()
                }

                switch model.route {
                case .home: HomeView()
                case .history: HistoryView()
                case .dictionary: DictionaryView()
                case .styles: StylesView()
                case .settings: AppSettingsView()
                }
            }
        }
        .onAppear { model.refreshAfterActivation() }
    }
}
