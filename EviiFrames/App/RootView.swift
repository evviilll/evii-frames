import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme

    var body: some View {
        Group {
            if model.screenshot != nil, let cover = model.cover {
                coverView(cover)
            } else {
                tabs
                    .fullScreenCover(item: $model.cover) { cover in
                        coverView(cover)
                            .environmentObject(model)
                            .environment(\.evii, EviiTheme(isDark: model.isDark))
                    }
            }
        }
        .environment(\.evii, EviiTheme(isDark: model.isDark))
        .preferredColorScheme(model.isDark ? .dark : .light)
        .alert(
            "Evii Frames",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            )
        ) {
            Button("Гаразд", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .onAppear { model.checkHardware() }
    }

    private var tabs: some View {
        TabView(selection: $model.tab) {
            NavigationStack(path: $model.path) {
                HomeView()
                    .navigationDestination(for: AppRoute.self) { route in
                        destination(route)
                    }
            }
            .tabItem { Label("Головна", systemImage: "house") }
            .tag(AppTab.home)

            NavigationStack {
                QueueView()
            }
            .tabItem { Label("Черга", systemImage: "list.bullet") }
            .tag(AppTab.queue)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Налаштування", systemImage: "sun.max") }
            .tag(AppTab.settings)
        }
        .tint(theme.text)
        .toolbarBackground(theme.bg, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    @ViewBuilder
    private func destination(_ route: AppRoute) -> some View {
        switch route {
        case .slowMo(let id):
            SlowMoView(jobID: id)
        case .interpolation(let id):
            InterpolationView(jobID: id)
        case .interpSettings(let id):
            InterpolationSettingsView(jobID: id)
        case .export(let id):
            ExportView(jobID: id)
        case .recents:
            RecentsView()
        }
    }

    @ViewBuilder
    private func coverView(_ cover: Cover) -> some View {
        switch cover {
        case .processing:
            ProcessingView()
        case .done(let id):
            DoneView(jobID: id)
        }
    }
}
