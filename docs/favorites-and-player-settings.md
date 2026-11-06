# 收藏与播放器设置（2026-11-06）

- 首页右侧使用原生导航栏的图标 NavigationLink，收藏页使用原生导航栈、返回和三列内容卡片，按聚合媒体库及各个服务器分组，来源 ID 不合并。
- 收藏只读写 Lucent 持久化数据；不查询服务器收藏、不用服务器 IsFavorite 覆盖本地收藏、不将本地收藏写入服务器。保留以前本地已有的收藏。
- 收藏拥有独立 favoriteUpdatedAt，切换收藏不修改观看进度的更新时间。聚合媒体库进度仍本地保存；Emby/Jellyfin/Plex 观看进度沿用服务器读取及回传路径，iCloud 不覆盖服务器内容的播放进度。
- 原 iCloud 开关统一为“iCloud 数据同步”；既有收藏、播放记录、片源与集合同步共用该开关。配置通过显式 allowlist 接入同一 CloudKit 配置记录，覆盖外观、首页、语言地区、字幕、弹幕、播放控制、手势和移动网络选项。密码令牌、缓存、调试状态及开关自身不纳入配置同步。使用既有配置记录整体更新时间进行冲突选择。
- iCloud 状态仍按已存在的相同媒体身份合并；本地文件访问权限和媒体文件本身不由此跨设备传送。现有非默认观看资料仍仅保存在本机。
- 此 Personal Team 真机调试包临时移除了 iCloud entitlement，不支持实际 iCloud 同步，不能用其安装/编译结果确认 CloudKit 运行效果。
- 弹幕面板继续复用播放器侧栏玻璃容器，清除其 NavigationStack 默认背景和 TextEditor 内容背景，行底色取自 PlayerControlStyle，不改尺寸；去掉服务配置入口。
- 字幕、音轨分开面板，保留字幕搜索、同步和外观等功能。内核每次默认 automatic，移除用户选项和偏好持久化，播放信息保留实际内核及路线信息。
- CD 转场期间将隐藏状态传给详情子视图，隐藏更多菜单和原生返回按钮，保持导航栏布局；播放器退出及竖屏恢复期间继续隐藏，完整结束后恢复。

## 字幕语言参考

- IINA develop `iina/MPVTrack.swift`： https://github.com/iina/iina/blob/develop/iina/MPVTrack.swift （GPLv3，仅参考设计，没有复制代码）。其 `readableLanguage` 使用语言标签加 Foundation Locale 本地化，`readableString` 保留原标题和格式信息。
- Apple Foundation `Locale.localizedString`： https://developer.apple.com/documentation/foundation/locale/localizedstring(forlanguagecode:)
- Apple 导航容器背景： https://developer.apple.com/documentation/swiftui/containerbackgroundplacement/navigation

Lucent 同时有 MPV、AVPlayer、AetherEngine，所以在各内核输出的字幕标签进入显示层时统一格式化，不改轨道 ID、顺序、自动选择或解码行为。有效语言标签优先，通用中文标签可由明确名称细化简繁；缺失时从标题的分隔词识别代码、英文名及常见中文标记。格式扩展名和 SDH 等标记不作为语言。无法识别保留原标题，避免猜测内容文本。常见双语标记保留两种语言。结果有界缓存。

## 检查与边界

离线检查：`verify-user-data-contracts.py`、`verify-subtitle-language.swift`、`verify-local-catalog.py`、`verify-localization.py`、`git diff --check`。构建/安装单独报告；未自动启动应用、点击界面、验证真实服务器同步或 CloudKit 多设备冲突。

## 更多设置与画面大小

播放器“更多设置”仅保留片头片尾（跳过时间及自动跳过）、画面大小、播放信息。弹幕设置正文统一 14pt，保留已有分组标题、辅助说明的小字号，不调整点击区域和间距。

画面模式保留既有持久化 `fill` 作为裁切全屏，新增加 `stretch`；原生 AVPlayer 和 AetherEngine 的原生/软件显示层分别使用 resizeAspect、resize、resizeAspectFill。MPV 使用 keepaspect=no 实现拉伸、keepaspect=yes/panscan=1 实现裁切，其余模式复位 panscan=0，video-unscaled=no；不改视频源、解码器或媒体比例元数据。移除了旧的固定比例菜单与其状态。

参考官方能力并按 Lucent 的嵌入式输出接入（未复制开源代码）：
- https://developer.apple.com/documentation/avfoundation/avlayervideogravity/resize
- https://mpv.io/manual/master/#options-keepaspect
- https://mpv.io/manual/master/#options-panscan

`verify-video-scale.py` 离线验证实际枚举映射、MPV 三种模式往返的属性复位、旧 fill 值兼容；不代表已经播放验证各输出路径。
