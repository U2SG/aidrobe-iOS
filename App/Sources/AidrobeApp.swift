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
    private(set) var stylingChange = UUID()
    private(set) var askNavigationChange = UUID()
    private(set) var todayChange = UUID()
    private(set) var favoritesChange = UUID()
    var selectedTab: AppTab = .today
    /// Opt-in account setting: show purchase prices and cost per wear. Off until loaded.
    private(set) var tracksItemCosts = false
    private var preferencesGeneration: UUID?
    /// One album scan per signed-in account: its uploads keep going (and stay
    /// visible) when the page closes, and stop at sign-out.
    private var albumScanModel: AlbumScanModel?
    var outfitToDiscuss: Wire.OutfitResponse?
    var inspirationToDiscuss: Wire.InspirationResponse?
    var conversationToDiscuss: String?

    var conversationBookmark: ConversationBookmark? {
        guard let accountID = ConversationBookmark.accountID(
            accessToken: tokens.tokens?.accessToken,
            developmentUserID: environment.allowsDevLogin ? environment.devUserID : nil
        ) else { return nil }
        return ConversationBookmark(accountID: accountID, server: environment.apiBaseURL)
    }

    func stylingDidChange(_ styling: Wire.StylingResponse) {
        conversationBookmark?.save(styling.conversationId)
        stylingChange = UUID()
        if styling.status == .adopted { todayChange = UUID() }
    }

    func favoritesDidChange() {
        favoritesChange = UUID()
        todayChange = UUID()
        stylingChange = UUID()
    }

    func discussOutfit(_ outfit: Wire.OutfitResponse) {
        conversationToDiscuss = nil
        inspirationToDiscuss = nil
        outfitToDiscuss = outfit
        openAsk()
    }

    func discussInspiration(_ inspiration: Wire.InspirationResponse) {
        conversationToDiscuss = nil
        outfitToDiscuss = nil
        inspirationToDiscuss = inspiration
        openAsk()
    }

    func discussConversation(_ conversationID: String) {
        outfitToDiscuss = nil
        inspirationToDiscuss = nil
        conversationToDiscuss = conversationID
        openAsk()
    }

    private func openAsk() {
        askNavigationChange = UUID()
        stylingChange = UUID()
        selectedTab = .ask
    }

    /// Loads account-level display preferences once per signed-in account.
    func loadPreferencesIfNeeded() async {
        let generation = AccountLocalData.generation
        guard preferencesGeneration != generation,
              let settings = try? await api.send(Endpoints.settings()),
              generation == AccountLocalData.generation else { return }
        preferencesGeneration = generation
        tracksItemCosts = settings.trackItemCosts ?? false
    }

    /// Optimistic; reverts when the server refuses.
    func setTracksItemCosts(_ on: Bool) async {
        let previous = tracksItemCosts
        tracksItemCosts = on
        do {
            let settings = try await api.send(Endpoints.updateSettings(.init(trackItemCosts: on)))
            tracksItemCosts = settings.trackItemCosts ?? on
        } catch {
            tracksItemCosts = previous
        }
    }

    private static let onboardingKey = "aidrobe.onboarding.completed"

    init(environment: AppEnvironment = .current) {
        let tokens = TokenStore(store: KeychainStore())
        self.environment = environment
        self.tokens = tokens
        self.onboardingCompleted = UserDefaults.standard.bool(forKey: Self.onboardingKey)

        let relay = SessionRelay()
        self.api = APIClient(environment: environment, tokens: tokens) { event in
            let generation = tokens.generation
            Task { @MainActor in
                guard tokens.generation == generation, tokens.tokens == nil else { return }
                relay.model?.handle(event)
            }
        }
        self.wardrobe = WardrobeStore(api: api)
        relay.model = self
    }

    func completeOnboarding() {
        sessionNotice = nil
        onboardingCompleted = true
    }

    func albumScan() -> AlbumScanModel {
        if let model = albumScanModel { return model }
        let model = AlbumScanModel(api: api)
        albumScanModel = model
        return model
    }

    func signOut() {
        albumScanModel?.cancel()
        albumScanModel = nil
        tokens.clear()
        wardrobe.reset()
        AccountLocalData.clear()
        outfitToDiscuss = nil
        inspirationToDiscuss = nil
        conversationToDiscuss = nil
        selectedTab = .today
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
