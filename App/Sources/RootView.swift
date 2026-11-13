import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.onboardingCompleted {
                MainTabView()
            } else {
                WelcomeView()
            }
        }
        .animation(.default, value: model.onboardingCompleted)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("今日", systemImage: "sun.max") {
                NavigationStack { TodayView() }
            }
            Tab("衣橱", systemImage: "hanger") {
                NavigationStack { PlaceholderView(title: "衣橱") }
            }
            Tab("问问", systemImage: "sparkles") {
                NavigationStack { PlaceholderView(title: "问问") }
            }
            Tab("我的", systemImage: "person") {
                NavigationStack { ProfileView() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

struct PlaceholderView: View {
    let title: String

    var body: some View {
        ContentUnavailableView(title, systemImage: "hammer", description: Text("即将推出"))
            .navigationTitle(title)
    }
}
