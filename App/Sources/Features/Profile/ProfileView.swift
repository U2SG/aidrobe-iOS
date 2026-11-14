import AidrobeKit
import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Preferences.cutoutKey) private var prefersCutout = true
    @AppStorage(Preferences.appearanceKey) private var appearance = "system"
    @AppStorage("aidrobe.settings.placeName") private var placeName = ""
    @State private var model: ProfileModel?

    var body: some View {
        List {
            if let model {
                figures(model)
                journal(model)
                recommendation(model)
            }
            Section {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Toggle("衣物去掉背景展示", isOn: $prefersCutout)
            } header: {
                Text("显示")
            } footer: {
                Text("在手机上完成，照片不会为此上传，原图始终保留。")
            }
            Section {
                Button("退出登录", role: .destructive) { app.signOut() }
            }
        }
        .listRowSeparatorTint(Color.separator)
        .scrollContentBackground(.hidden)
        .background(Color.background)
        .navigationTitle("我的")
        .toast(Binding(get: { model?.notice }, set: { model?.notice = $0 }))
        .task {
            if model == nil { model = ProfileModel(api: app.api) }
            await model?.load()
        }
    }

    private func figures(_ model: ProfileModel) -> some View {
        Section {
            HStack(alignment: .top, spacing: 0) {
                figure("\(app.wardrobe.items.count)", "件衣服")
                figure("\(model.daysThisMonth)", "天，本月穿搭")
                figure("\(model.historyTotal)", "次穿着记录")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.display(34, weight: .black, relativeTo: .largeTitle))
                .foregroundStyle(Color.label)
            Text(caption)
                .font(.caption)
                .foregroundStyle(Color.tertiaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func journal(_ model: ProfileModel) -> some View {
        Section("穿搭日记") {
            if model.history.isEmpty {
                Text("在今日页点「就穿这套」，这里会一天天记下来。")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryLabel)
            } else {
                ForEach(model.history.prefix(7), id: \.wearHistoryId) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(Garment.day(entry.wornDate) ?? entry.wornDate)
                            .foregroundStyle(Color.secondaryLabel)
                            .frame(width: 76, alignment: .leading)
                        Text(entry.outfit?.title ?? "自己搭的一套")
                            .foregroundStyle(Color.label)
                        Spacer()
                        if let feeling = feeling(entry.feedbackType) {
                            Text(feeling)
                                .font(.subheadline)
                                .foregroundStyle(Color.tertiaryLabel)
                        }
                    }
                }
                NavigationLink("全部记录") { JournalView() }
            }
        }
        Section {
            NavigationLink("衣橱洞察") { InsightsView() }
            NavigationLink("记住的偏好") { MemoryView() }
            NavigationLink("数据与隐私") { PrivacyView() }
        }
    }

    private func feeling(_ raw: String?) -> String? {
        switch raw.flatMap(FeedbackKind.init(rawValue:)) {
        case .love, .like: "挺好"
        case .dislike: "不太合适"
        default: nil
        }
    }

    private func recommendation(_ model: ProfileModel) -> some View {
        Section {
            Button {
                Task {
                    if let place = await model.useCurrentLocation() { placeName = place }
                }
            } label: {
                HStack {
                    Text("所在城市").foregroundStyle(Color.label)
                    Spacer()
                    if model.isLocating {
                        ProgressView()
                    } else {
                        Text(model.settings?.location == nil ? "用当前位置" : (placeName.isEmpty ? "已设置" : placeName))
                            .foregroundStyle(model.settings?.location == nil ? Color.accent : Color.secondaryLabel)
                    }
                }
            }
            DatePicker(
                "出门时间",
                selection: Binding(get: { model.departure }, set: { time in Task { await model.setDeparture(time) } }),
                displayedComponents: .hourAndMinute
            )
            Picker("路上", selection: Binding(
                get: { model.settings?.commuteExposure?.rawValue ?? "" },
                set: { raw in
                    guard let exposure = Wire.UpdateUserSettingsRequest.CommuteExposurePayload(rawValue: raw) else { return }
                    Task { await model.setCommute(exposure) }
                }
            )) {
                if model.settings?.commuteExposure == nil { Text("没设置").tag("") }
                Text("在户外的时间多").tag("more_outdoor")
                Text("在户外的时间少").tag("less_outdoor")
            }
        } header: {
            Text("搭配参考")
        } footer: {
            Text("城市决定天气，出门时间和路上的情况决定穿多厚。")
        }
    }
}
