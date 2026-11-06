# tvOS 代码审查与修复（2026-11-07）

本轮按用户要求直接审查代码，不启动模拟器、不截图、不运行播放。以下“已修改”表示实现已写入，不代表 Apple TV 遥控器和实际画面已验收。

## 已修改

| 范围 | 代码中确认的问题 | 处理 |
| --- | --- | --- |
| Jellyfin 目录 | 子页面仍获取全库最新内容，丢失父目录；分页固定增加 60 | `directoryRequest` 保留 ParentId、用户数据、实际页偏移；子目录非递归，根目录筛选电影/剧集；按返回条数推进 |
| 浏览返回 | 页面重新出现时重置列表和分页 | `NativeServerBrowser` 首次加载与返回分开，保留已有列表 |
| Emby 分类 | 原生首页没有完整媒体库入口；通用浏览器不提供完整分类/排序 | 添加“我的媒体”，媒体库与文件夹入口接回共享 `EmbyBrowserView`，保留电影/剧集/风格/工作室/文件夹及已有排序逻辑 |
| 首页请求 | 等待全部根请求和栏目，单个根请求失败会阻断其他内容 | 根请求并发、各自发布；栏目分批发布；分别保留根请求和栏目错误；搜索推荐只请求根内容 |
| 首页状态 | 取消可能遗留 loading，缓存未充分区分连接和用户 | 按代次结束 loading；取消不当作错误；快照区分地址、账户、资料和内容语言，失败快照会重试 |
| 搜索 | 多服务器串行等待；无结果时筛选入口消失 | 限制并发并逐组发布；保留来源顺序；局部失败不抹除其他结果；本地独立库默认选择本地范围 |
| 收藏 | 新版跨来源收藏入口主要在 iOS | 提取共享收藏页面，原生首页增加入口，保留来源分组、本地收藏语义和服务器图标 |
| 详情导航 | tvOS 复用手机覆盖标题按钮，全部剧集使用整屏模态 | tvOS 使用原生工具栏、导航栈；“查看全部”推入层级页面 |
| 详情布局 | 手机宽度限制、剧集卡片和媒体信息卡偏小且固定高度 | TV 独立内容宽度和卡片尺寸；媒体信息自然高度；可阅读横向信息获得原生焦点 |
| 播放器 | 300–400pt 手机侧栏、44pt 按钮；隐藏控件缺少可靠遥控器焦点入口 | TV 620–760pt 面板、72pt 控件、原生按钮与焦点区；指定默认播放焦点；隐藏状态可用原生按钮重新显示 |
| 播放返回 | 返回操作未区分正在拖动、侧栏、选集和主控制层 | 按顺序取消 seek、关闭面板、关闭选集、隐藏控件、退出；遥控器播放键提交 seek 或切换播放 |
| 存储层级 | TV 使用模态展示多级存储浏览 | 目录与导入确认改为原生层级导航；新增/编辑仍可使用任务表单 |
| 设置 | 复用手机胶囊字段及不适用的流量选项 | TV 表单用原生 LabeledContent；移动网络设置只在 iOS 展示；弹幕面板移除不必要的嵌套导航容器 |

关键路径：`NativeExperience.swift`、`NativeServerBrowser.swift`、`NativeSearchView.swift`、`NativeSourcesView.swift`、`EmbyBrowserView.swift`、`JellyfinClient.swift`、`MovieDetailView.swift`、`SeriesDetailView.swift`、`PlaybackView.swift`、`PlatformUI.swift`、`LucentUI.swift`。

## 参考与差异

- [Apple focusSection](https://developer.apple.com/documentation/swiftui/view/focussection())：沿用系统焦点搜索，按栏目和控制区组织焦点，不额外接管每一帧手势。
- [Apple onExitCommand](https://developer.apple.com/documentation/swiftui/view/onexitcommand(perform:))：用平台返回事件管理播放器内部层级。
- [Swiftfin tvOS PlaybackControls](https://github.com/jellyfin/Swiftfin/blob/main/Swiftfin%20tvOS/Views/VideoPlayer/PlaybackControls/PlaybackControls.swift)：研究其分离播放控件显示、启用状态及焦点区域的结构。Lucent 保留自身 PlaybackSession 和 SwiftUI 原生焦点，没有引入其 FocusCoordinator 或复制源码。Swiftfin 为 MPL-2.0；本轮仅参考设计，无新增第三方依赖。

## 验证和边界

- tvOS arm64 Debug 未签名构建通过。
- `scripts/verify-native-home.py`：从生产代码提取首页模型，验证根请求独立失败、分阶段发布、栏目失败、取消恢复、推荐根请求模式、账户/地址/语言缓存隔离。
- `scripts/verify-browser-pagination.py`：验证实际 Emby/Jellyfin 请求，覆盖父目录、季层级、根媒体库与内容路由、分页偏移及用户数据。
- macOS arm64 与 iOS 真机 Debug 构建通过；最新 iOS 包已安装到“jiangyi的 iPhone”，未自动启动。Personal Team 包临时移除 iCloud entitlement，构建后已恢复源文件，此包不支持 iCloud 同步。
- 本地媒体库、收藏/进度归属、播放选路和自定义弹幕离线检查通过。未向 Apple TV 安装，也没有进行遥控器操作或视听验收。

仍需后续处理或运行验收：

1. 首页栏目目前是分批加载，不是完整的逐行可见性懒加载；TV 首页快照仍为进程内缓存，冷启动磁盘恢复没有与 iOS 完全对齐。
2. Jellyfin/Plex 首页栏目丰富度与 Emby 尚未完全一致；不能据共用页面宣称三种协议功能等价。
3. TV 首页大图仍使用既有固定分辨率策略，尚未完成实际 4K 显示区域与内存实测。
4. 真实遥控器焦点恢复、长列表连续滚动、文本输入、侧栏关闭和系统返回仍需 Apple TV 验收。
5. HDR、杜比视界、Atmos、音轨/字幕切换和长时间播放未在本轮运行验证；未调整内核底层兼容策略。
