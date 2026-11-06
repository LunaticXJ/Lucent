# 2026-11-06 首页滚动与 Hero 返回诊断

## 结论边界

已读取用户复现记录，并对运行中的真机应用进行 Time Profiler 与 SwiftUI 专项附加采样。确认导航附近存在主线程回调长间隔，滚动过程中存在 SwiftUI 图更新和布局开销。尚未获得足以确定具体代码根因、或证明闪线来源的证据。本次不修改视觉实现，不将推测写成修复结论。

## 原始应用记录

路径：`.build/diagnostics/home-render-events.json`。941 项，覆盖约 41.70 秒。

- 834 项海报几何记录、83 项半秒 UI FPS、12 项超过阈值的回调间隔。
- 5 次进入导航、5 次返回。每次进入后约 82–98ms 均记录到长回调间隔；每次返回后约 11–142ms 也有长间隔。
- 最长回调间隔 113.03ms。这是 CADisplayLink 调度间隔，不是某一个函数的执行时间，也不是 GPU 呈现耗时。
- 海报宽 440pt、高约 726.666667pt；高度差异仅浮点舍入量级。窗口高度均为 956pt，记录的安全区不变。不能支持“返回时容器高度突变”的解释，但不排除内部图层或转场截图变化。
- 没有 hero-palette-change，没有超过 2ms 的 poster-palette-work 或 home-library-snapshot。仅对这段被保留的时间有效，不能外推其他运行过程。
- 开始约 0–10 秒、最后约 27–42 秒没有达到当前 50ms 阈值的回调间隔；不代表没有 16.7/8.3ms 预算超时或 GPU 卡顿。

## Time Profiler

路径：`.build/diagnostics/home-time-profiler.trace`，45.88 秒，附加到 Lucent PID 58802。设备 iOS 26.6.2，采样工具 Instruments 27.2。

解析文件：`home-time-samples.xml`、`profile-samples.json`（同目录）。共 8292 个样本，其中主线程 6422 个。下列数值为采样权重，不是精确连续执行时长；各项存在包含/重叠，不能相加。

- 主线程含 AG::Graph::UpdateStack::update 的样本权重约 2189ms。
- 含 _UIHostingView.layoutSubviews 约 1042ms。
- 含 ScrollViewCommitMutation 约 187ms；其中传播依赖失效的路径约 182ms。
- LibraryView.body 约 69ms，MobileHomeView 海报与栏目内容构建均出现在调用栈中。证明存在更新成本，不能单独证明根视图每帧被重建。
- 主线程 DebugFrameMonitor 路径约 41ms，HomeHeroGeometryProbe 约 11ms；诊断本身有开销，不能称零影响。
- 本轮有约 20ms 采样权重出现在首页取色路径，说明原始记录中“没有取色”的结果不能外推到之后的复现。
- 未采到名字包含 snapshot 的主线程栈；不意味着系统没有转场快照，不能反证。

后取的应用记录 `home-render-events-profiled.json` 仅保留约 22.41 秒，其中 1022 项为几何事件。现有 1200 项环形上限会被逐帧几何占满，因此不能声称已完整对齐 45.88 秒采样与全部导航事件。

## SwiftUI 专项采样限制

`home-swiftui-detail.trace` 已成功录制 30 秒；导出的 swiftui-updates、swiftui-causes、swiftui-layout-updates、hitches 表均为 0 行。不能作为“没有更新/没有掉帧”的证据，也没有具体状态属性的更新原因链。空表原因尚未确定。

## 当前候选路径与后续证据

1. 滚动：调查滚动位置依赖的图更新、布局传播范围，以及内容构建中同步执行的工作。需要有效 SwiftUI 更新原因链，或与具体长帧对齐的调用栈，才能决定拆分状态/视图的位置。
2. 闪线：外部容器尺寸/主题色变化未获支持；内部固定海报偏移、遮罩/裁切、系统 zoom 转场图层交接仍为候选。需要复现画面逐帧与转场/渲染轨迹对照，不能把某一个候选直接定为根因。
3. 下一轮需提高应用记录有效保留时间，并补充与系统采样共用的 signpost 时间标记；避免仅凭两份不同时间基准的记录建立精确对应关系。

参考 Apple 官方工作流：

- https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance
- https://developer.apple.com/videos/play/wwdc2025/306/

本次没有更改应用代码，没有构建或安装新版本，也未自动启动或操作应用。

## 授权后从 Instruments 启动的采样

已用 enableLayoutTracing=true 从 Instruments 重启应用。工具结束时明确报错 `Cannot enable layout tracing on an unsupported device`；导出的视图更新表仍为空。此前不能把布局空表只归因于开关未开启，当前设备/工具组合不支持此能力。trace 保存在 `.build/diagnostics/home-launch-layout.trace`。

电脑端 devicectl screen-record 返回 CoreDeviceError 1001，设备不支持 Screen Recording，未取得视频。需要用户提供手机系统录屏，或更换受支持的采集方式，才能逐帧定位闪线。上述失败不代表应用无掉帧，也不是闪线根因。

## 用户提供的对照与代码路径复核

用户确认仅 Hero 返回闪线，普通导航返回（我的媒体更多后的详情页）不闪。该现象支持以 zoom 为条件的转场路径调查，不能证明是系统 bug。

复核 MobileHomeView：海报源使用带 themeColor 背景、零圆角、无阴影配置的 HomeMatchedSource；我的媒体源使用默认 HomeMatchedSource，并未使用海报的揭幕 mask。因此“源视图的海报 mask 是所有入口共同原因”不成立；不能只修改这个 mask 宣称修复。

两类入口共享同一首页目标画面、同一 NavigationStack，以及 LibraryView 中由 mobileDetailPresented/mobileLibraryCollectionPresented 反馈驱动的根工具栏和 tab 可见性。目标页另有 lucentSecondaryPage 隐藏 tab，存在根和目标同时管理可见性的代码事实；尚未实验证明这会产生闪线，不能直接删除后称已找到根因。

滚动调用栈中额外确认 CatalogYearLabel.text 的未使用 present 默认参数会调用 lucentLocalized，进而构造 LocalizationPreferences 并读取 UserDefaults/Locale/Bundle。该路径有约 30ms 累计采样权重（与其他项重叠），是确定的多余工作，但并非完整掉帧原因证明。

下一步应对共同首页路径做单变量对照：先仅关闭海报固定偏移，再仅关闭 tab 自动收缩，再隔离根状态反馈。每次保留 zoom 与相同源/目标，记录是否仍闪，禁止同时改变遮罩、背景、尺寸与导航。
