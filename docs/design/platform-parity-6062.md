# 三端能力对齐（6062）

## 实施范围

iOS、macOS、tvOS 使用同一个 LibraryStore、目录扫描、Repository、Outbox、元数据、播放 Session 和内核交接状态机。macOS/tvOS 新增 NativeAppShell，分别以原生侧栏和 TV TabView 进入首页、片源、搜索、设置。旧 MacHomeView / TVHomeView 已删除。

本次是源代码与构建层面的补齐。未启动任何应用、操作界面或播放影片；不能据此宣称焦点体验、画面色彩、无缝切换、帧率已通过运行验证。

## 能力清单

| 能力 | 实现与平台覆盖 |
| --- | --- |
| 主题、语言、地区、日期 | 三端 AppAppearance、LocalizationEnvironment 和共用设置；macOS/tvOS 不再被旧首页强制设为深色 |
| 首页来源 | 三端支持聚合媒体库及各账户的 Emby/兼容 NAS、Jellyfin、Plex；原生 Picker 显示官方品牌图标及当前选择 |
| 首页内容与缓存 | macOS/tvOS 共用 NativeHomeModel；Emby 最近入库、继续观看、服务器媒体库栏目；Jellyfin/Plex 分页目录。按服务器账户及观看资料隔离一天快照，最多 8 份，失败可重试，刷新同步已删除记录 |
| 轮播 | macOS/tvOS 8 个候选、自动播放开关、上一部/下一部、简洁指示器、标题图片；SceneStorage 保留当前位置，侧栏切换时首页模型、本地栏目快照缓存由根视图持有；目录分类在后台构建，切换观看资料不展示上一资料的快照 |
| 聚合媒体库 | 三端统一“连接存储→浏览/多选目录→命名文件源→扫描”；不再在另外两端自动导入整个存储 |
| 文件源管理 | 共用 AggregateLibraryOverview / StorageManagementView / StorageDirectoryBrowser / 导入审核：禁用、移除、重命名、重新扫描、目录重叠检查、失败重试；本地源只能由系统支持文件选择的设备添加 |
| 服务器配置 | macOS/tvOS 覆盖 Emby、Jellyfin、Plex、飞牛、极空间、绿联；名称、地址、HTTPS、端口、路径、用户名密码/令牌；复用 updateServerAddress，换用户重建身份，保留同地址不同账号支持 |
| 服务器列表 | 官方图标、电影/剧集数、地址/用户名；编辑、移除；服务器和聚合媒体库原生分段切换 |
| 网络存储与网盘 | SMB/WebDAV 新增与编辑共用 StorageConnectionEditor，支持共享发现、域、用户名、密码显隐；网盘授权及 DLNA 继续复用现有提供方逻辑 |
| 海报墙与更多 | LocalCatalogCollectionView 三端共用，分类、题材、排序、观看筛选；服务器“查看全部”分页加载，Plex 保留剧/季层级而不是 allLeaves 单集扫描结果 |
| 搜索 | macOS/tvOS 共用 NativeSearchView：提交才查询、历史搜索、清空、海报推荐与换一批、聚合/服务器切换不重新请求、服务器分组、不显示单集、部分服务器失败不丢失其他结果 |
| 电影/剧集详情 | MovieDetailView / SeriesDetailView 三端共用：高清海报、标题图、分路加载、骨架、续播、选集后再次点击播放、简介展开、季选择、全部剧集、多选批量观看/收藏/下载、演员和媒体信息 |
| 播放控制与交接 | 共用 PlaybackView / PlaybackSession、内核切换、加载圈、画面比例、音轨字幕选中状态、控制栏自动隐藏；tvOS/macOS 原生 Aether 视频使用 AVKit/AVPlayerLayer 而非无条件走软件画面；就绪状态纳入切换等待 |
| 播放中选集 | 三端使用同一个海报选集覆盖层和完整集数据；删除旧的文字式平台列表及其独立图片缓存 |
| 字幕与弹幕 | 共用 PlaybackServicesView / SubtitleSearchView / DanmakuModel / Overlay / Settings；凭据与登录、在线查询下载、语言、字号/底色、屏蔽词、偏移、弹幕布局 |
| 进度预览与跳过 | 共用预览调度、进度阈值记忆、完成与下一集提示、手动片头片尾和自动跳过；tvOS 进度条可聚焦，左右预览，确认/播放键提交，返回取消 |
| 缓存与下载 | 共用缓存设置、后台磁盘缓存、容量与到期淘汰；ArtworkImageDecoder 扩展三端，详情解码后台执行。下载/暂停/恢复/取消入口也在 tvOS 开放；Apple TV 的本机数据会受系统存储回收影响 |
| 账户与同步 | 共用观看资料、儿童资料解锁、CloudKit、Trakt、Outbox 和同步设置；不绕开现有权限及移动网络策略 |
| 生命周期 | 前后台重新核对实际播放状态、取消进度预览；macOS 活跃播放时持有防显示器休眠活动，tvOS 防屏保，离开播放释放；后台释放可重建图片内存缓存 |
| 转场与公共 UI | 光盘转场扩展三端；表单、设置、海报、状态反馈、玻璃、播放按钮、简介等共用 LucentUI，tvOS 采用更大控件和系统焦点 |

## 合理的平台差异

- 触摸亮度/音量/长按倍速等手势保留 iOS；macOS 使用空格、方向键和 Esc，tvOS 使用遥控器与焦点，设置显示对应控制说明。
- tvOS 没有系统本地文件/文件夹选择器，因此不展示本地字幕、弹幕文件导入及本地文件夹添加按钮；在线服务和网络存储功能可用，不伪造本地导入入口。
- 三端显式画中画共用 AVPictureInPictureController、原生播放器伴随图层与状态回调；macOS 使用 NSView，另外两端使用 UIView。仅在系统和当前原生画面支持时启用，MPV 画面仍无系统画中画（与 iOS 相同）。音频输出选择器也通过对应平台的 AVRoutePickerView 提供。
- macOS 播放以大尺寸窗口 sheet 呈现，tvOS 为全屏；季选择在 macOS 为锚定 popover，在 tvOS 为可返回的选择页；不是手机像素布局的等比例放大。
- macOS MPV 保留现有 OpenGL render API，tvOS 真机保留 Metal/MoltenVK，模拟器保留软件渲染。未在此 UI/功能迁移中冒险改写已使用的底层渲染后端。
- 外部服务器能力仍由服务器与协议决定，例如未开放转码不会凭空获得转码；Plex 不虚构收藏接口。Personal Team 真机包仍不支持 iCloud entitlement。

## 参考与许可边界

借鉴结构与交互原则，没有复制上游代码：

- [Swiftfin Shared/Views/AppSettingsView.swift](https://github.com/jellyfin/Swiftfin/blob/main/Shared/Views/AppSettingsView.swift)：共享设置状态与控件，使用平台分支处理输入与系统外观能力。
- [Swiftfin 季选择器](https://github.com/jellyfin/Swiftfin/blob/main/Shared/Objects/ContentGroup/SeriesEpisodeContentGroup/SeriesEpisodeContentGroup%2BSeasonSelector.swift)：季选择与剧集页面分开、tvOS 焦点与导航入口；Lucent 继续使用自己的服务模型、凭据及 EpisodeClient，不引入 Swiftfin 的 Defaults/Router/JellyfinAPI 依赖。上游为 MPL-2.0，本次不复制其实现。
- 原生 SwiftUI NavigationSplitView / TabView / Picker；同一功能的配置键、错误处理、导入事务和播放 Session 不复制成平台专属后端。

## 验证与手动检查

- 构建：iOS Simulator arm64、macOS arm64、tvOS Simulator arm64、tvOS 真机 arm64。Intel tvOS 模拟器的上游对象音频二进制缺少符号，未将该架构作为通过项，也未以禁用杜比功能掩盖问题。
- 离线检查：Repository/Outbox/状态交接、文件源导入回滚/分页、目录分类、进度记忆、网络策略、字幕/弹幕及预览调度。
- 手动重点：两端新增/编辑每类服务器与存储；多目录导入/禁用/移除；主题与本地化；大库滚动；连续内核切换；字幕/弹幕；TV 焦点返回、进度预览；macOS 休眠与键盘；进入/退出转场。
