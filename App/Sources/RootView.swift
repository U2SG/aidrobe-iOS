import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.appearanceKey) private var appearance = "system"
    @State private var isOnboarding = false

    var body: some View {
        Group {
            if model.onboardingCompleted {
                MainTabView()
            } else if isOnboarding {
                OnboardingFlowView {
                    isOnboarding = false
                    model.completeOnboarding()
                }
            } else {
                WelcomeView { isOnboarding = true }
            }
        }
        .animation(.default, value: model.onboardingCompleted)
        .animation(.default, value: isOnboarding)
        .preferredColorScheme(Preferences.colorScheme(appearance))
    }
}

enum AppTab: Hashable { case today, wardrobe, ask, profile }

struct MainTabView: View {
    @Environment(AppModel.self) private var app
    @State private var askPath = NavigationPath()

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("今日", systemImage: "sun.max", value: .today) {
                NavigationStack { TodayView() }
            }
            Tab("衣橱", systemImage: "hanger", value: .wardrobe) {
                NavigationStack { WardrobeView() }
            }
            Tab("问问", systemImage: "text.bubble", value: .ask) {
                NavigationStack(path: $askPath) {
                    AskView {
                        ToolLink(title: "该不该买", detail: "买之前，先看看衣橱里有没有", route: .shopping)
                        ToolLink(title: "出行打包", detail: "出门几天，从衣橱里带什么", route: .packing)
                    }
                    .navigationDestination(for: AskToolRoute.self) { route in
                        switch route {
                        case .shopping: ShouldIBuyView()
                        case .packing: PackingListsView()
                        }
                    }
                }
            }
            Tab("我的", systemImage: "person", value: .profile) {
                NavigationStack { ProfileView() }
            }
        }
        .onChange(of: app.askNavigationChange) { askPath = NavigationPath() }
    }
}

private enum AskToolRoute: Hashable { case shopping, packing }

/// A row that opens one of the tools under Ask, in the same shape as the
/// "这一套" list on Today.
private struct ToolLink: View {
    let title: String
    let detail: String
    let route: AskToolRoute

    var body: some View {
        NavigationLink(value: route) {
            VStack(spacing: 0) {
                HStack(spacing: Spacing.row) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body)
                            .foregroundStyle(Color.label)
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(Color.tertiaryLabel)
                    }
                    Spacer(minLength: Spacing.tight)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(Color.tertiaryLabel)
                }
                .frame(minHeight: 64)
                .contentShape(.rect)
                Divider().overlay(Color.separator)
            }
        }
        .buttonStyle(.plain)
    }
}
