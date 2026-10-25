import SwiftUI

@main
struct EviiFramesApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.evii, EviiTheme(isDark: model.isDark))
        }
    }
}
