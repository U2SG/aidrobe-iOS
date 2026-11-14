import SwiftUI

/// Welcome: what the app promises, then in. Sign in with Apple arrives once the
/// Apple Developer team and backend `APPLE_CLIENT_ID` are configured; until
/// then non-production builds enter with the dev user.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    /// Called once the user has a session (Apple, or the dev user in non-production builds).
    let onStart: () -> Void

    private let promises = [
        ("只用你衣橱里真有的", "不推荐你没有的衣服，也不催你买。"),
        ("每天早上一套", "看天气、看场合，一眼决定，不用纠结。"),
        ("你说过的会记得", "太热、太正式、不合身，下次就不再这样搭。"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: Spacing.section)
            Text("衣然")
                .font(.display(64, weight: .black, relativeTo: .largeTitle))
                .foregroundStyle(Color.label)
            Text("今天穿什么，交给自己的衣橱。")
                .font(.title3)
                .foregroundStyle(Color.secondaryLabel)
                .padding(.top, Spacing.tight)
            Spacer(minLength: Spacing.section)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(promises.enumerated()), id: \.offset) { index, promise in
                    Divider().overlay(Color.separator)
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                        Text("0\(index + 1)")
                            .font(.display(17, weight: .regular, relativeTo: .body))
                            .foregroundStyle(Color.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(promise.0)
                                .font(.headline)
                                .foregroundStyle(Color.label)
                            Text(promise.1)
                                .font(.subheadline)
                                .foregroundStyle(Color.secondaryLabel)
                        }
                    }
                    .padding(.vertical, Spacing.row)
                }
                Divider().overlay(Color.separator)
            }
            Spacer(minLength: Spacing.section)
            if let notice = model.sessionNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Color.danger)
                    .padding(.bottom, Spacing.control)
            }
            AppleSignInButton(onSignedIn: onStart)
            if model.environment.allowsDevLogin {
                Button("开发版本：以测试账号进入", action: onStart)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.top, Spacing.tight)
            }
        }
        .padding(Spacing.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.background)
    }
}
