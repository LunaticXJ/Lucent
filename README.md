# Lucent

Lucent 是面向 iPhone、iPad、Apple TV 和 Mac 的个人媒体库播放器。用户可以连接本地文件、NAS 和家庭媒体服务器，把影片整理成可浏览的媒体库并稳定播放，并在多台 Apple 设备间继续观看。Lucent 不提供影视内容或资源搜索服务。

> 当前状态：P0/P1 尚未达到验收标准，P2 能力仍在补齐。仓库中的多数功能处于“代码已写入、待真机与真实服务器验收”阶段，详见[当前进度](#当前进度)。最新 iOS 开发构建为 6065（2026-11-07），已安装到开发用 iPhone；最新一轮未自动启动应用或执行播放验收。macOS/tvOS 的历史构建记录见下文，不能视为与最新 iOS 版本同步验收。

## 平台

| 平台 | 最低系统版本 |
| --- | --- |
| iPhone、iPad | iOS 18 |
| Apple TV | tvOS 18 |
| Mac | macOS 15 |

工程使用 Swift 6 和 SwiftUI。最低版本为当前工程配置，不是最终产品承诺。

## 功能

以下能力均已写入代码，实际验收状态见“当前进度”和[验收矩阵](docs/acceptance-matrix.md)。

### 片源与聚合媒体库

- 三端片源页分为「影视服务器」和「聚合媒体库」，使用统一添加入口。
- **存储 → 文件源 → 聚合媒体库**：先连接本地文件夹、SMB、WebDAV、网盘或 DLNA，再浏览并多选目录、逐个命名导入。添加存储不会自动扫描整个存储。
- 文件源可浏览、重命名、禁用、重新扫描或移除；启用的目录共同组成设备上的一个聚合媒体库。移除文件源不删除原始文件。
- SMB 支持局域网发现、共享枚举、访客/账户登录与域名；WebDAV 支持协议、端口和根路径。新增与编辑共用表单，凭据保存在 Keychain。
- Emby、Jellyfin、Plex 直接使用服务器元数据，独立于本地聚合媒体库；同一地址的不同用户可分别添加，支持连接编辑与显示名称修改。
- 网盘适配包括 Dropbox、Google Drive、115、123、百度、光鸭；授权方式及可用性取决于各服务接口，不能视为全部已验收。
- HTTP(S)、播放列表、STRM 及部分其他协议的底层入口仍存在；iOS 添加存储菜单不再提供单文件上传、浏览器上传和网络视频地址入口。

### 资料整理、首页与详情

- SQLite 持久化、目录增量扫描、文件名解析和 TMDB 本地资料匹配；支持中文名称、年份、季集识别、手动匹配与失败重试。
- 「补全影片资料」获取缺失的影片/剧集资料；「重试获取未完成的资料」重新安排失败或未完成的任务。TMDB 需要用户配置令牌。
- 媒体信息探测默认关闭，可在设置开启；播放获得的编码、音轨等技术信息持久化，供后续起播与详情展示使用。
- 首页可切换聚合媒体库或影视服务器；聚合内容按电影、国产剧、综艺、国漫、日韩剧、欧美剧、纪录片组织，隐藏空分类。
- 首页海报支持手动切换、标题图片、主题取色和继续观看，不自动轮播；冷启动优先恢复本机首页快照与已缓存封面，服务器栏目按需加载。图片按显示区域、屏幕倍率和内存预算解码，图片与播放缓存可在设置管理。
- iOS 首页右上角提供收藏入口，按聚合媒体库及各影视服务器分组；收藏由 Lucent 本地保存，不读取或改写服务器收藏。收藏卡片复用「我的媒体」的布局，并显示来源图标。
- 剧集详情支持选集、续播、简介展开及全部剧集的多选操作；播放页选集补充评分、观看状态、单集简介与时长。
- 搜索历史、海报推荐、聚合媒体库/影视服务器结果切换；服务器结果按连接分组，不包含单集。
- 支持跟随系统、深色与浅色外观；iOS 26 使用系统玻璃控件，旧系统提供兼容样式。
- 聚合媒体库观看进度保存在本地；影视服务器观看进度从服务器读取并回传服务器，iCloud 不覆盖服务器播放进度。
- 「设置 → 同步与服务 → iCloud 数据同步」统一控制已接入的收藏、聚合媒体库观看记录、片源、集合及用户配置。配置包括外观、首页、语言地区、播放控制、字幕和弹幕；同步开关自身、缓存及 Keychain 服务凭据不随配置同步。
- 下载、独立观看资料、儿童资料、CloudKit 与 Trakt 等已有代码路径仍需按平台和服务验证。iCloud 按已有媒体身份合并状态，不传送媒体文件或本地文件访问权限；非默认观看资料仍仅保存在本机。Personal Team 真机调试包不包含 iCloud 能力。

### 播放

- 三条播放路径：系统 AVPlayer、AetherEngine 原生增强路径和 MPVKit；默认自动选择，不向用户提供手动内核配置，实际内核与选路原因在「播放信息」中展示。
- 自动选路综合服务器 MediaInfo 和有界本地探测；杜比视界及 TrueHD/DTS 优先走 AetherEngine，ASS/SSA 特效字幕和不兼容原生解码的格式走 MPVKit，普通兼容流走 AVPlayer。原生路径失败时在自动模式下交给 MPV 重试。
- 字幕与音轨使用独立面板。字幕支持 SRT/VTT 文本叠加、ASS/SSA/SUP 的 MPVKit 原生路径、同目录外挂字幕、内嵌字幕轨及 OpenSubtitles 搜索下载（需自备 API key）。
- 字幕语言优先读取轨道语言标签，缺失时从名称识别常见语言代码、简繁体和双语标记，再按应用语言展示；无法识别时保留原名，不改变轨道 ID 或选择顺序。
- 弹幕支持弹弹play在线匹配、自定义兼容 API、JSON/XML 文件导入，以及透明度、字号、区域、时长、偏移和屏蔽词设置；服务配置与字幕分开，播放器内不放置服务配置入口。
- 音轨切换、外挂音轨、倍速、章节、快进快退；AVPlayer 路径拖动时生成画面预览，并提供系统音频输出路由选择（AirPlay、蓝牙等）。
- 续播、已看状态、下一集与连续播放；片头、前情和片尾标记，支持自动跳过和手动设置。
- 三端原生 AVPlayer 画面支持显式系统画中画及音频输出选择；仅在系统与当前画面支持时启用，MPV 画面不启用系统画中画。
- 「更多设置」依次提供画面大小、片头片尾和播放信息。画面大小支持等比适应、拉伸全屏及裁切全屏；各内核共用显示模式，不因调整画面大小重载片源。
- 播放信息面板展示实际内核、直连或转码、选路原因、缓冲状态与中断次数。
- 服务端转码已有 Jellyfin/Emby/Plex 的接口与播放路径；回退能力受服务授权、片源和当前播放路径影响，仍需真实服务器验收。

### 自定义弹幕服务器

1. 打开「设置 → 弹幕 → 自定义弹幕 API」，点击「添加服务器」。
2. 填写名称和 API 地址，开启「启用」。地址可为服务器根地址、带鉴权路径的地址，或已经以 `/api/v2` 结尾的地址；不需要填写具体搜索或弹幕接口。
3. 点击「检测连接」，确认搜索接口兼容后保存。检测成功不等于每个影片都能匹配到弹幕。
4. 播放时打开弹幕面板，选择服务器、搜索影片或剧集，再选择对应集下载弹幕。

支持兼容弹弹play的 `/api/v2/search/episodes` 与 `/api/v2/comment/{episodeID}` 协议，例如自托管的 [danmu_api](https://github.com/huangxd-/danmu_api)。只需配置自己的服务地址，不内置公共第三方服务器，也不会把弹弹play官方 App ID/Secret 发给自定义服务器。不同服务器的弹幕缓存相互隔离，切换服务器后仍按搜索结果的原服务器下载。

公网地址优先使用 HTTPS；HTTP 连接沿用系统 ATS 与局域网策略。自定义服务器配置受统一 iCloud 开关控制，地址中携带的鉴权路径也属于配置；官方服务凭据仍保存在本机 Keychain。接口范围、开源参考与验证边界见[自定义弹幕服务器说明](docs/custom-danmaku-servers.md)。

## 播放内核与杜比视界

自动模式下，服务器声明的杜比视界与无损音轨优先接入 AetherEngine；无 MediaInfo 的本地文件与直链执行限时、限量的 FFmpeg 探测。AetherEngine 的 HLS-fMP4 管线提供 P7→P8.1 及可选 FEL 合成，并在受支持的 iOS/tvOS 26 设备上使用 APAC 对象音频路径。Lucent 已启用这些可选组件，并将位图字幕叠加到播放视图。切换至 MPV 时预加载新画面、对齐进度并淡入；MPV 提供 ASS/SSA 字幕及扩展编码兼容。实际杜比视界/Atmos 输出仍取决于文件、系统、设备和输出链路，尚待真机视听验收。

Dolby Vision Profile 5 只有 IPT-PQ 视频，没有 HDR10 基础层。Lucent 使用 AetherEngine 的正常加载路径，由内核负责探测、封装和显示条件；不再为 P5 开启诊断用的色彩条件选项或额外重载。若原生路径失败，P5 不会自动切换到无法正确呈现其颜色的软件解码路径，而会显示原生错误。此调整参考 Sodalite 的加载方式，仍需在真机上确认《后室》的实际画面。

实现参考并依赖 [AetherEngine](https://github.com/superuser404notfound/AetherEngine/blob/main/docs/architecture.md) 和 [MPVKit](https://github.com/mpvkit/MPVKit)。两个内核仍各自解复用；Lucent 没有单一共享 FFmpeg 解复用器，也没有公开 CoreAudio API 可供手工写入 Dolby MAT。已实现原生路径与 MPV 的双向预热切换、进度对齐、播放意图保留和失败回退；这些机制不等于所有素材均可无感切换，音频中断及偶发失败仍需真机验收。iOS/tvOS 的 MPV 真机路径为 gpu-next/Vulkan/MoltenVK 到 CAMetalLayer，macOS 继续使用现有 OpenGL render API，不承诺固定的能耗降幅。发行前须审查 AetherEngine 的 LGPL-3.0、App Store 例外和传递依赖及相关专利授权。

影片详情展示服务器提供的播放版本、分辨率、编码、动态范围与容器；播放页的“播放信息”面板显示实际播放器内核、直连或转码、选路原因和缓冲状态。系统播放器路径在拖动进度时生成画面预览；MPV 路径暂无进度缩略图。

## 构建

需要 Xcode、[XcodeGen](https://github.com/yonaskolb/XcodeGen) 和网络连接（SwiftPM 依赖）。最新 iOS 构建使用 Xcode 27.2；三端历史构建环境见验证记录。克隆仓库后，在仓库根目录执行：

```bash
# 1. 由 project.yml 生成 Xcode 工程
xcodegen generate

# 2. 打开工程，选择 Lucent-iOS、Lucent-tvOS 或 Lucent-macOS
open Lucent.xcodeproj
```

MPVKit 由 SwiftPM 拉取 `project.yml` 中锁定的 revision。三个 target 为 `Lucent-iOS`、`Lucent-tvOS` 和 `Lucent-macOS`。

## 当前进度

### 2026-11-07 tvOS 代码审查

- 补齐首页媒体库与跨来源收藏入口，Emby 分类浏览复用完整的电影/剧集/风格/工作室/文件夹及排序；修正 Jellyfin 父目录与分页，返回时保留列表。
- 首页根请求独立发布，局部失败不阻断其他内容；搜索限流并发并逐组展示；取消与缓存按请求代次、账户、地址和语言隔离。
- TV 详情采用原生工具栏与层级导航；调整电视卡片、信息区和播放器面板尺寸，补充原生焦点区、默认播放焦点及遥控器分层返回。
- tvOS、macOS arm64 编译通过，首页加载与目录请求离线检查通过。按要求未启动模拟器；遥控器操作、画面及播放仍待 Apple TV 验收。已知剩余项与参考实现见 [tvOS 审查记录](docs/tvos-code-review-2026-11-07.md)。

### 2026-11-07 更新（iOS 6065）

- 新增原生自定义弹幕服务器列表，支持添加、编辑、删除、启用及连接检测；播放器可选择已启用的服务进行匹配与下载，不固定堆放空配置。
- 保留自托管服务的鉴权路径和查询参数；官方凭据不外发，搜索结果绑定服务器，弹幕缓存按服务器隔离。配置接入已有 iCloud 用户配置同步开关。
- 自定义服务器配置聚焦名称、地址、启用状态与连接检测，保留现有弹幕显示设置。
- 已通过 iOS 真机构建并安装；客户端离线检查覆盖协议请求、错误响应、重定向、结果绑定和跨服务器缓存。未连接真实自定义服务器，未自动启动应用或进行真实弹幕播放/iCloud 多设备验收。
- 应用图标更新为白底、圆润且厚实的蓝色播放环，右下方以橙色点缀；旧设计稿保留。

### 2026-11-06 更新

- iOS 多级页面优先使用系统导航栏、工具栏和返回行为；继续观看与我的媒体入口取消 Hero 转场，二级页面隐藏底部 Tab。
- 优化首页快照恢复、继续观看封面缓存、栏目按需加载，以及海报的尺寸解码、取色和重复状态更新；这些代码优化不代表所有滑动卡顿或画面问题均已运行验收。
- 新增跨来源本地收藏列表，区分本地收藏、聚合媒体库进度与影音服务器进度；收藏采用独立更新时间，避免切换收藏影响进度同步。见[收藏与播放器设置](docs/favorites-and-player-settings.md)。
- 播放器字幕与音轨拆分；补充字幕语言本地化；内核固定自动选路并在播放信息展示。更多设置精简为三项，画面支持等比适应、拉伸全屏和裁切全屏；去除左上角缩放按钮及侧栏后方的暗色遮罩。

### 2026-11-02 更新（6062）

- macOS 原生侧栏与 tvOS 原生 TabView 补齐首页、片源、搜索、设置入口；使用同一个目录文件源模型、详情页、字幕/弹幕、进度/跳过、缓存及账户设置。
- 两端支持全部现有服务器类型的新增/编辑、官方图标与媒体数量、存储多目录导入和文件源管理；服务器分页浏览保留剧/季层级，搜索按服务器分组。
- 扩展后台图片解码、按账户/资料隔离的一天首页缓存、异步本地栏目索引、显式画中画及前后台状态核对；适配键鼠与遥控器焦点、进度预览和防休眠。
- 完成 iOS、macOS、tvOS arm64 的编译检查及 7 组离线逻辑检查；没有启动应用或执行视听/界面验收。平台文件选择器、输入方式、渲染后端等边界见[三端能力对齐清单](docs/design/platform-parity-6062.md)。

### 2026-11-01 更新

- 在线字幕接入播放器：OpenSubtitles 搜索/语言选择/分页、账户登录及下载额度错误提示、本地文件导入，安装后立即应用到播放会话。
- 新增弹幕搜索/选集、TMDB 资料匹配及 JSON/XML 导入；独立时间轴渲染、暂停/seek 同步、字号/透明度/区域/速度/偏移与屏蔽词。服务凭据由用户在设置填写。
- 服务器首页刷新重新请求并替换成功快照，同时核对本机已打开条目；同步失败不据此删除缓存条目，保留用户下载文件。
- 播放增加可关闭的光盘缩入/反向展开转场及详情背景渐隐/渐现，新图标采用白底简约科技风。
- 实现说明、开源参考与验证边界见[字幕、弹幕与刷新设计](docs/playback/subtitles-danmaku-and-refresh.md)。

### 2026-10-30 更新

- 完成聚合媒体库的存储/目录文件源拆分、TMDB 本地资料流程、可选媒体信息探测及 Emby 风格首页。
- 更新片源、设置、服务器与 SMB/WebDAV 表单；文件源使用圆角分组容器和行分隔线，设置子页面入口不再重复显示配置值。
- 补齐播放页选集内容，改进续播、内核切换、播放状态与加载提示；各类真实媒体仍需持续验证。
- 最新 6044 iOS Debug 构建通过；本地目录、分组、资料解析、旧配置解码、地址解析和弹窗归属等离线检查已执行。具体检查脚本见下文。
- 最近真机安装因 CoreDevice 4016 未完成；不将构建通过视为最新版本运行通过。默认不自动启动或执行界面/播放回归。

### 历史验证记录

- 2026-10-23 修复模拟器上 MPV 播放 Emby 影片出现紫色画面的问题：iOS/tvOS 模拟器改用 `vo=libmpv` 软件渲染，真机仍走 Metal/MoltenVK。渲染改为独立串行队列并分离渲染与播放线程，seek 改为异步命令；断点续播、前后拖动、暂停恢复均回归通过。设计参考 Yattee 的渲染实现（仅借鉴设计，未引入其源码），详见[MPV 接入对照与回归记录](docs/playback/mpv-reference-review.md)。
- 2026-10-21 移除 VLCKit 依赖和 VLC 播放内核，播放路径收敛为 AVPlayer + MPVKit；iOS 模拟器、tvOS 模拟器与 macOS Debug 构建重新验证通过。
- iPhone 17 Pro Max 模拟器已验证本机 H.264 MKV 的 MPV Metal 画面与 HTTP Range 拖动。
- 真实 Emby 的 10.14 GB STRM/MKV 样本可在 iPhone 模拟器经 MPV 解析并播放到约 20 秒，开头与尾部范围可读；后续 Range 在约 19.9 MB 处出现间歇性 `NSURLErrorDomain -1005`，重新请求同一偏移有时可恢复。范围桥接现复用 TLS 会话、按块读取、首块成功后再返回 206，并在读取失败时触发直连重连或转码回退；长时间播放仍需验收。
- 2026-10-21 真实 Emby 影片播放验证：iPhone 17 Pro Max 模拟器播放《希望》（MKV、H.264、EAC3、1920×800、2:37:01），MPV 直连起播并正常推进画面；播放信息显示“远程文件直连”、缓冲正常、0 次中断。同时修复了详情页用服务端 0 进度覆盖本地续播位置的问题，复查时从 00:56 续播到 01:09。
- 2026-10-21 详情页改为导航推入，不再使用弹窗；播放页起播时显示加载状态和取消入口。iOS 模拟器已通过详情进入、返回和加载提示的 UI 测试。
- Emby 已用真实服务器验证 9 个顶层目录的分页浏览；连接时不再扫描全库。
- 待验收：Emby 外部 CDN 长时间播放、Apple TV 与 Mac 的实际画面、iPad 运行、跨设备协议组合、HDR/杜比视界激活、CloudKit 签名与多设备冲突、字幕渲染与音频输出。历史 iPhone 调试结果不替代最新版本验收。
- 工程暂无 XCTest target；现有结论主要来自本机探针、模拟器和冒烟测试，不代表四端已通过验收。

## 检查与设备安装

离线检查不请求真实媒体服务器：

```bash
python3 scripts/verify-aggregate-library.py
python3 scripts/verify-local-catalog.py
python3 scripts/verify-tmdb-recognition.py
python3 scripts/verify-source-management.py
python3 scripts/verify-modal-ownership.py
python3 scripts/verify-playback-metadata.py
python3 scripts/verify-playback-routing.py
python3 scripts/verify-playback-services.py
python3 scripts/verify-custom-danmaku.py
python3 scripts/verify-user-data-contracts.py
python3 scripts/verify-video-scale.py
python3 scripts/verify-localization.py
python3 scripts/verify-network-usage.py
```

这些脚本验证数据与静态契约，不能代替画面、字幕、声音和切换体验验收。真实 Emby 检查使用 `scripts/verify_emby_direct.py`，通过环境变量指定地址与用户名，从系统钥匙串读取密码；请勿向仓库提交令牌、签名媒体地址或账号密码。

Personal Team 不支持工程的 iCloud entitlement。调试安装时可在命令行用临时空 entitlement 覆盖 `CODE_SIGN_ENTITLEMENTS`，保留仓库内的正式 entitlement；该包无法使用 iCloud 同步。安装与运行验证分开执行，默认安装后由用户手动验证。

## 已知限制

- 源码音频直通尚未实现；APAC 对象音频依赖 iOS/tvOS 26 与受支持的输出设备。HDR、杜比视界、Atmos 需按文件和设备逐项验证。
- MPV 路径不保证杜比视界动态元数据输出；ISO/VIDEO_TS/BDMV 交由 MPV 尝试播放，不再提供 VLC 式光盘菜单和完整导航。
- MPV 路径暂无进度缩略图；部分高级字幕样式和位图字幕仍需设备验证。
- 云盘和第三方同步依赖各服务开放接口与授权。光鸭接口依据第三方客户端，可能随服务端变化；Google Drive 尚未接入应用内 OAuth。
- 发行前仍须完成 MPVKit、SwiftSMB 等依赖的许可证合规审查。

## 仓库结构

```text
Sources/LucentApp/   SwiftUI 界面、播放内核、片源适配、媒体库与同步
docs/                产品规划、Infuse 差距、技术方案、验收记录与播放验证
scripts/             目录/资料/选路/配置离线检查、安装及 Emby 验证脚本
Generated/           XcodeGen 生成的 Info.plist 与 entitlements
project.yml          XcodeGen 工程定义
```

## 文档

- [产品与功能规划](docs/product-plan.md)
- [对标 Infuse 的差距与路线图](docs/infuse-gap-roadmap.md)
- [技术方案与验证计划](docs/technical-plan.md)
- [播放验证操作](docs/probe-guide.md)
- [自定义弹幕服务器：协议、配置与验证范围](docs/custom-danmaku-servers.md)
- [收藏、进度归属与播放器设置](docs/favorites-and-player-settings.md)
- [P0/P1 验收矩阵](docs/acceptance-matrix.md)
- [MPV 接入对照与回归记录](docs/playback/mpv-reference-review.md)

## 第三方组件

- [AetherEngine](https://github.com/superuser404notfound/AetherEngine)：通过本地动态包装包隔离与 MPVKit 的 FFmpeg 符号，见[接入与许可说明](docs/attribution/aetherengine.md)。
- [MPVKit](https://github.com/mpvkit/MPVKit)
- [SwiftSMB](https://github.com/RuiNelson/SwiftSMB)
