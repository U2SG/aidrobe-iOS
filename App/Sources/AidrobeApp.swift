import AidrobeKit
import SwiftUI

@main
struct AidrobeApp: App {
    @State private var model = AppModel()

    init() {
        Typography.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                #if DEBUG
                .importDemo()
                #endif
                .environment(model)
                .tint(Color.accent)
        }
    }
}

/// App-wide session state. The navigation gate is the onboarding flag; any
/// expired or deactivated session also returns the user to Welcome.
@MainActor
@Observable
final class AppModel {
    let environment: AppEnvironment
    let tokens: TokenStore
    let api: APIClient
    let wardrobe: WardrobeStore

    private(set) var onboardingCompleted: Bool {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: Self.onboardingKey) }
    }

    private(set) var sessionNotice: String?

    private static let onboardingKey = "aidrobe.onboarding.completed"

    init(environment: AppEnvironment = .current) {
        let tokens = TokenStore(store: KeychainStore())
        self.environment = environment
        self.tokens = tokens
        self.onboardingCompleted = UserDefaults.standard.bool(forKey: Self.onboardingKey)

        let relay = SessionRelay()
        self.api = APIClient(environment: environment, tokens: tokens) { event in
            Task { @MainActor in relay.model?.handle(event) }
        }
        self.wardrobe = WardrobeStore(api: api)
        relay.model = self
    }

    func completeOnboarding() {
        sessionNotice = nil
        onboardingCompleted = true
    }

    func signOut() {
        tokens.clear()
        wardrobe.reset()
        onboardingCompleted = false
    }

    fileprivate func handle(_ event: SessionEvent) {
        sessionNotice = switch event {
        case .expired: "登录已过期，请重新登录"
        case .deactivated: "账号已注销"
        }
        signOut()
    }
}

/// Lets the API client's session callback reach the model created after it.
private final class SessionRelay: @unchecked Sendable {
    @MainActor weak var model: AppModel?
}
