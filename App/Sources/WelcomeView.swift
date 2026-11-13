import SwiftUI

/// P0 welcome: dev "skip" only. Sign in with Apple lands in P1 once the
/// Apple Developer team and backend `APPLE_CLIENT_ID` are configured.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Spacing.section) {
            Spacer()
            VStack(spacing: 8) {
                Text("衣然")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color.label)
                Text("用你真实的衣橱，决定今天穿什么")
                    .font(.callout)
                    .foregroundStyle(Color.secondaryLabel)
            }
            Spacer()
            if let notice = model.sessionNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Color.danger)
            }
            if model.environment.allowsDevLogin {
                Button("开发环境：跳过登录") {
                    model.completeOnboarding()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(Spacing.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
    }
}
