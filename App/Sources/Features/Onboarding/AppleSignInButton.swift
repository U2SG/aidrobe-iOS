import AidrobeKit
import AuthenticationServices
import SwiftUI

/// Sign in with Apple: the identity token goes to the backend, which answers
/// with our own session tokens. Needs the Sign in with Apple capability on
/// the app id; until that is configured the attempt fails and says so.
struct AppleSignInButton: View {
    let onSignedIn: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var failure: String?
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: Spacing.tight) {
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = []
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 52)
            .clipShape(.capsule)
            .disabled(isWorking)
            .opacity(isWorking ? 0.6 : 1)
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Color.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func handle(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                failure = "没有拿到 Apple 的登录凭证，再试一次"
                return
            }
            isWorking = true
            Task {
                defer { isWorking = false }
                do {
                    let tokens = try await app.api.send(Endpoints.loginWithApple(identityToken: token))
                    app.tokens.save(TokenPair(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken))
                    failure = nil
                    onSignedIn()
                } catch {
                    failure = userMessage(for: error)
                }
            }
        case let .failure(error):
            // Dismissing the sheet is not a failure worth a message.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            failure = "用 Apple 登录暂时不可用，稍后再试"
        }
    }
}
