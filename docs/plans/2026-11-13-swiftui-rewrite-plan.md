# 衣然 iOS SwiftUI 重写方案（草案 v0.1）

> 状态：P0 已完成（`d9abaf3`）。2026-11-13 依据重启分析报告（`drobe/analysis/00-decision-report.md`）收窄范围：**只做主线**，见下方「范围调整」。基线：后端 `aidrobe-BE@bf593dd`，RN 前端 `aidrobe-FE redesign/mvp-v0.8-ui@d902f20`（Expo SDK 57）。
> 范围：iOS 端用纯 SwiftUI 重写，功能对齐 RN 前端 V2 界面 + V3 全部能力；Android 继续用 RN 版本。

## 0. 范围调整（2026-11-13，优先于下文）

- 现状分析结论：项目停滞的阻塞都在后端与运行环境，iOS 重写不解决任何一项；后端 V3 形象照 / 试穿 / 画质门禁固定为 Fake 适配器。
- **iOS 只做主线**：引导（开发登录 → Apple 登录）、导入确认（单件 / 多件）、今日一套、换一件、记穿着、反馈；外加 **Apple Vision 端上主体抠图实验**（对应分析报告任务 4、5）。
- 问答、购物（SenseCheck / Should I Buy）、打包、洞察、记忆、风格灵感、V3 形象照与试穿、遥测：**暂停**，主线经真机验收后再逐项决定。
- 下文第 1、5 节的「全量对齐」与 P2–P5 仅作远期参考。
- 本仓允许本机编译、单测与模拟器运行（用户 2026-11-13 确认），CI 为合并门禁。

### 界面方向（2026-11-13 重设计）

- 三个标签：今日 / 衣橱 / 我的。问问等暂停的功能不留占位入口。
- 今日是「每日一页」：日期、平铺搭配板（按单品高矮自动排两列）、单品清单（逐件可换）、理由、底部一条操作栏（换一套 / 就穿这套 / 不合适）。右上角可以说明「今天有什么不一样」并据此重搭。
- 衣橱按品类分组的目录 + 单品页（穿着次数、状态、合身、改名、移除）；导入入口在右上角。
- 我的：三项数字、穿搭日记、搭配参考（当前位置、出门时间、通勤）、外观与抠图开关。
- 抠图在端上用 Apple Vision 完成并缓存，服务器原图不动，单品页可切回原图。
- 尚待真机确认：宋体标题的按需下载、抠图在真实照片上的效果、天气行（本机后端不返回天气）。

## 1. 目标与边界

- **目标**：iOS 26 起步、尽量使用系统原生控件（自带 Liquid Glass）、和后端契约逐字段一致的原生 App。
- **对齐基准**：RN 前端开启 `ENABLE_MVP_V2_UI` + 三个 V3 开关时**用户能到达的页面**（约 30 个），不移植 V1 遗留页面（V1 Today、Discover、OutfitCalendar、OutfitPlanPicker、SettingsScreen、LandingPage）和死代码（genui）。
- **不改后端**：仍走同一套 `/v1/*` 接口；如发现必须的后端改动，单独提后端 PR。
- **Bundle ID 沿用 `app.aidrobe.ios`**：后端 Apple 登录校验 `id_token.aud == APPLE_CLIENT_ID`，沿用同一 Bundle ID 才能做到后端零配置改动。RN 仓 `eas.json` 没有任何 iOS 提交配置，iOS 版从未上架，因此不存在老用户迁移（Keychain / 引导标记无需搬迁）。RN 工程今后只出 Android 包。

## 2. 技术选型

| 层 | 选择 | 理由 |
|---|---|---|
| 语言 / 并发 | Swift 6.4，严格并发检查 | 编译期消除数据竞争 |
| UI | SwiftUI（iOS 26），`@Observable` | 原生控件 + Liquid Glass 免费获得 |
| 工程 | Xcode 工程 + 本地 SPM 包（`AidrobeKit`） | 业务逻辑可独立 `swift test`，App target 只放界面 |
| 网络 | P0 第一天做验证：`swift-openapi-generator` 从 `docs/openapi.json` 生成客户端；若 FastAPI 的 `anyOf:[X, null]` 等导致生成类型难用，退回手写 `Codable` 模型。两种方案都在外面包一层门面 | 规格里已把信封建模成 `ResponseModel_X_`，V3 裸模型也有描述；门面负责业务码非 0 抛错、`data.reason` 解析、超时分级 |
| 状态 / 缓存 | 每个功能一个 `@Observable` Store + 轻量查询缓存（stale 60 s）+ 失效事件总线 | 替代 React Query；不引入 TCA，保持简单 |
| 持久化 | Keychain（token、设备 id）、`UserDefaults`（偏好、引导完成标记、提醒频控） | 数据量小，不需要 SwiftData |
| 图片 | 自写 `ImagePipeline`（`URLCache` + 内存 `NSCache` + 降采样） | 避免第三方依赖；签名 URL 不落盘持久化 |
| 测试 | Swift Testing（`AidrobeKit` 单测）+ XCUITest 冒烟 | RN 仓 `scripts/*.test.ts` 的纯逻辑用例直接翻译成 Swift 用例 |
| CI | GitHub Actions `macos-26-arm64` runner（默认 Xcode 26.6，Xcode 27 为预览）：build + 单测 + 文案禁词 + 契约文件哈希比对 | 仓库须公开才免费（私有仓 macOS 分钟按 10 倍计费，会重演 8 月的扣费卡死）。代码只用 iOS 26 SDK 的 API，保证 Xcode 26.6 与本机 27.2 都能编译 |

第三方依赖只计划引入 Apple 官方的 `swift-openapi-generator` / `swift-openapi-runtime` / `swift-openapi-urlsession`。

## 3. 原生控件映射

| RN 现状 | SwiftUI 原生 |
|---|---|
| JS 底部标签栏（4 个 tab） | `TabView` + `Tab`（iOS 26 自带玻璃标签栏、滚动最小化） |
| native-stack | `NavigationStack` + 类型化路由 `NavigationPath` |
| 自绘 bottom sheet（详情页 6 个、衣橱 4 个…） | `.sheet` + `presentationDetents` |
| 自绘菜单 / 操作列表 | `Menu`、`contextMenu`、`confirmationDialog` |
| 自绘 chips 筛选 | `Picker(.segmented)`、`.searchable` + search scopes |
| 自绘开关 / 选项行 | `Form` / `List` + `Toggle`、`Picker` |
| 自绘滚轮时间选择 | `DatePicker(.wheel / .compact)` |
| RN `Share`（只能发链接） | `ShareLink` + `Transferable` 图片：用 `ImageRenderer` 把屏幕上的搭配视图直接渲染成图片分享 —— 不依赖后端 #163 的拼图接口、不分享过期链接、自然反映本地替换，#159 的三条 review 都不存在 |
| expo-image-picker | `PhotosPicker`（多选批量导入）+ 相机 `UIImagePickerController` 包装 |
| expo-apple-authentication | `SignInWithAppleButton` |
| expo-location + 逆地理 | `CLLocationUpdate` + `CLGeocoder` |
| 空状态组件 | `ContentUnavailableView` |
| 洞察图表（自绘） | Swift Charts |
| 下拉刷新 / focus refetch | `.refreshable`、`scenePhase` + `onAppear` 按 stale 刷新 |
| Toast | 顶部 overlay（系统无 toast，保留自定义，玻璃材质） |
| Skia 光球 / 天气背景 / 倒计时环 | SwiftUI `Canvas`、`MeshGradient`、Metal shader（`.colorEffect`） |
| Haptics（RN 无） | `.sensoryFeedback`（新增，零成本） |

视觉：`src/theme/design.ts` 的暖色 token 转成 Asset Catalog 颜色 + `Theme` 常量；字体用系统字体和 Dynamic Type 文本样式对齐原字号表。

## 4. 模块拆分（`AidrobeKit`）

```
AidrobeKit/
  Core/        Env 配置、Keychain、UserDefaults 偏好、日志、Feature flags
  API/         生成的客户端 + APIClient 门面（信封、错误、超时、单飞 refresh、X-Correlation-Id）
  Upload/      压缩（1600 px / JPEG 0.8）+ presign（POST 表单 / PUT 分支）+ 内网 host 改写
  Domain/      各模块映射与规则：todayMode、firstOutfit、purchaseDecision、visualPreview、avatar 状态机、提醒频控…
  Telemetry/   V3 事件规格校验 + 传输（32 队列 / 8 批 / 60 s TTL / 3 次重试）+ recommendations/events
  Localization 由 zh-CN.ts / en-US.ts 脚本转换的 String Catalog（约 804 key）
App/
  Features/    Onboarding、Today、Wardrobe、Import、Ask、Shopping(SenseCheck/ShouldIBuy)、Packing、Insights、Profile、Memory、Style、Avatar、OOTD
```

## 5. 分阶段计划

| 阶段 | 内容 | 交付验证 | 估算 |
|---|---|---|---|
| P0 基础 | 建仓、工程骨架、CI、Theme、API 门面 + 生成客户端、Keychain、单飞 refresh、上传管线、本地化转换脚本、Toast | 单测覆盖信封两种形态 / 401 刷新 / presign 改写；模拟器能 dev 登录拉到 Today 原始数据 | 3–4 天 |
| P1 引导 + 今日 | Welcome（Apple 登录 / dev 跳过）、权限、首导入、风格记忆、出发时间、FirstOutfit、Today V2（模式、覆盖条、刷新配额、收藏、曝光事件）、搭配详情（替换、穿过、反馈、分享图片）、FeedbackSheet、OOTD 海报 | 模拟器走通引导 → 今日 → 详情 → 反馈；截图对照 RN | 5–7 天 |
| P2 衣橱 + 导入 | 列表（分类、搜索、分页、cutout 轮询）、单品详情 / 编辑 / 合身 / 穿着历史 / 删除、拍照 / 相册批量 / 链接导入、识别确认（单件 / 多件）、失败页 | 批量导入部分失败降级、轮询超时 | 4–5 天 |
| P3 问答 + 购物 + 出行 + 洞察 | Ask（历史、单品范围、反馈）、SenseCheck、ShouldIBuy（V3 流程 id、候选轮询、决策卡）、打包清单三页、洞察（Swift Charts）、衣橱报告 | V3 版本偏差规则单测（未知状态降级、503 隐藏、轮询超时 = 仍在处理） | 5–6 天 |
| P4 我的 + V3 形象 / 试穿 | ProfileV2（出发时间、语言、城市 **+ 补上 GPS 定位入口**）、数据信任、记忆管理、风格灵感、形象照同意 / 准备 / 替换 / 删除、全局候选提示、静态试穿预览 + 一次性反馈、导出 / 注销 / 清数据 | 同意链路、删除 purge_derived、注销 401 行为 | 5–6 天 |
| P5 遥测 + 打磨 + 发布 | V3 遥测传输、文案禁词、无障碍（Dynamic Type、VoiceOver）、深浅色、性能、TestFlight | 真机冒烟清单（复用 RN `docs/qa` P0 smoke） | 3–4 天 |

合计约 25–32 个工作日。每个阶段一个或数个 PR，CI 绿后合并。

## 6. 契约同步

- `docs/openapi.json`、`docs/v3-p0-contract.md`、`docs/v3-analytics-events.json` 从后端逐字节复制，CI 校验哈希；生成客户端在构建时从该快照生成。
- 后端改接口时，三端（BE / RN / iOS）同一需求内同步更新快照。

## 7. 决策点

默认处理（无异议即按此执行）：
- **GPS 定位入口**：RN V2 下没有入口，新装用户永远不会开 GPS 天气。iOS 版在「我的 → 城市」补「使用当前位置」。
- **旧版 `track()` 埋点**：RN 里实际已全部被丢弃，不移植；只做 V3 事件 + `recommendations/events`。
- **注销账号后的 401**：RN 清 token 但不重置引导标记，用户卡在主界面反复报错。iOS 版统一回到欢迎页。

已拍板（2026-11-13）：
- 视觉：原生控件 + 暖色品牌 token（背景、强调色、文字色）。
- 深色模式：支持，补一套深色 token。
- 仓库：`U2SG/aidrobe-iOS`，公开。
- 本地后端：OrbStack + `docker compose`。

待定：Apple 开发者 Team / 签名与 Sign in with Apple 能力（P1 做 Apple 登录前需要；P0 用 dev 跳过登录），后端 `APPLE_CLIENT_ID` 配成 `app.aidrobe.ios`。

## 8. 本地验证环境

- RN / 后端仓的「测试只在 CI 跑」源于 Windows + testcontainers；iOS 仓需要本机模拟器验证界面，建议本仓允许本地 build / 单测 / 模拟器运行，CI 作为合并门禁。
- P0 出口要连真实后端：本机目前**没有 Docker**，Tailscale 上的开发后端也不可达。需要装 Docker（或 OrbStack）在本机起 `docker compose`，或恢复 Tailscale 后端。

## 9. 风险

- **OpenAPI 质量**：部分 V3 错误响应在规格里没有 schema（如 400/404/503 为空），门面需手工补 `data.reason` 解析。
- **视觉还原**：Skia 光球、天气背景等自绘动效需要用 SwiftUI Canvas / shader 重做，P1 先用静态降级，P5 打磨。
- **双端行为漂移**：同一功能在 RN（Android）和 iOS 各实现一次，以后需求要两边都改；靠共享契约文档 + 把 RN 纯逻辑测试翻译成 Swift 用例来约束。
