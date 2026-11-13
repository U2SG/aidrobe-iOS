import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Button("退出登录", role: .destructive) {
                    model.signOut()
                }
            }
        }
        .navigationTitle("我的")
    }
}
