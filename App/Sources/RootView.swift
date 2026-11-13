import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.appearanceKey) private var appearance = "system"

    var body: some View {
        Group {
            if model.onboardingCompleted {
                MainTabView()
            } else {
                WelcomeView()
            }
        }
        .animation(.default, value: model.onboardingCompleted)
        .preferredColorScheme(Preferences.colorScheme(appearance))
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("今日", systemImage: "sun.max") {
                NavigationStack { TodayView() }
            }
            Tab("衣橱", systemImage: "hanger") {
                NavigationStack { WardrobeView() }
            }
            Tab("我的", systemImage: "person") {
                NavigationStack { ProfileView() }
            }
        }
    }
}
