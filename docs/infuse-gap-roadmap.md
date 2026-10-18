# Lucent 对标 Infuse：功能差距与路线图

2026-10-18 构建与烟雾测试：Xcode 27.1 重新生成工程后，iOS、tvOS 模拟器及 macOS Debug 构建均通过；iPhone 和 Apple TV 模拟器安装启动并显示媒体库首屏，macOS 应用进程启动。独立逻辑测试通过 M3U 多条目、STRM、HLS 清单识别及前情/片头/片尾具名章节解析。当前 iOS 27.1 模拟器运行时与本机列出的 iPad 设备类型不兼容，未能创建 iPad 模拟器。工程当前没有 XCTest target；Plex/Emby/Jellyfin、云盘、光盘与实际音视频输出仍需要服务器、账号、片源和设备验收。下文历史状态保留为当时记录。

2026-10-18 播放增强代码：Plex 多版本转码索引、服务端选轨及转码期间重新开流；Jellyfin/Emby 转码期间重新开流；本地和 HTTP M3U 多条目选择与连续播放、M3U8 及 STRM 入口；Jellyfin Media Segments、Plex Marker、Emby 和本地具名章节的片头/前情/片尾识别与自动跳过；VLCKit 光盘标题与方向菜单控制、画面比例；AVPlayer 峰值码率和 iOS 系统音频输出选择。以上均未按用户要求构建或用真实设备、服务器验证。自动片段识别依赖服务器或章节标记，不等同于对无标记视频进行画面/音频分析；光盘菜单的实际可用性仍依赖 VLCKit 和光盘内容。

2026-10-18 补充：用户提供的第三方 [guangyaclient](https://github.com/DDSRem-Dev/guangyaclient) 给出了光鸭文件列表与下载地址请求形状。Lucent 已加入手动访问令牌连接、文件扫描和下载地址适配代码。下方旧状态描述仍代表此前基线；这次新增代码未构建或用真实账号验证。第三方项目并非光鸭官方开放接口承诺，短信登录与令牌刷新仍待可靠授权方案。

更新：2026-10-17。对标范围：iPhone、iPad、Apple TV、Mac；仅比较用户可见能力，不以营销页列出的格式等同于 Lucent 的兼容性承诺。本轮新增代码尚未按用户要求运行构建或功能验证。

## 当前基线

Lucent 已写入 SMB、WebDAV、Jellyfin、Plex 的扫描与范围播放链路，本地文件/文件夹、媒体详情、字幕与音轨选择、TMDB 匹配、SQLite 媒体库、CloudKit 状态同步、下载、合集和连续播放等代码。**带 VLCKit 的三套 Xcode Debug 构建于 2026-10-17 通过，但真实服务器和四端设备尚未完成验证。**本机样本确认 AVFoundation 无法打开 MKV，而 VLCKit 可以完成同一 MKV 样本的播放；P0/P1 仍不能标记为完成。

## 功能差距

| 领域 | Infuse 公开能力 | Lucent 当前 | 规划优先级 |
| --- | --- | --- | --- |
| NAS 与网络片源 | SMB、NFS、FTP/SFTP、WebDAV、UPnP/DLNA 等，可浏览和播放 [来源](https://firecore.com/infuse) | SMB/WebDAV 扫描与范围播放；FTP/FTPS/SFTP/NFS 的 VLC 目录保存、凭据管理、导入和刷新；DLNA 手动连接、SSDP 发现、保存和刷新代码已写入，均待设备验收 | **P0：四端 SMB 验收**；P1：WebDAV 验收；P2：其余协议 |
| 自建媒体服务器 | Plex、Emby、Jellyfin；媒体库与播放状态可同步，并有按需直连模式 [来源](https://support.firecore.com/hc/en-us/articles/360006462093-Streaming-from-Plex-Emby-and-Jellyfin) | Jellyfin、Emby 用户名/密码或令牌连接，Plex PIN 或手动令牌连接；三者有扫描、直连播放及基本状态回写代码；详情页可查询和直连选择多版本；新增 2/5/10/20 Mbps HLS 服务端转码入口，Plex 关闭播放时尝试结束转码会话。真实服务器尚未验收，所选版本与转码组合、音轨/字幕转码切换和按需浏览仍未完成 | **P1：真实服务器与认证流程验收**；P2：多版本/转码/按需浏览 |
| 云盘 | Dropbox、Google Drive、OneDrive、Box 等直接串流 [来源](https://support.firecore.com/hc/en-us/articles/360058061093-Streaming-From-Cloud-Services) | Dropbox、Google Drive 扫描、分段读取与下载代码；Dropbox PKCE 授权码交换入口；两者可手动输入访问令牌或应用 ID 与刷新令牌，扫描、播放和分段读取前自动续期；Google Drive 应用内授权尚未接入。123 云盘可走 WebDAV，另有开放平台直连的文件枚举、临时下载地址和 clientID/clientSecret 取令牌代码。115、百度网盘有基于开放接口的手动令牌扫描、临时下载地址、范围读取和下载代码。光鸭因接口未公开仅有明确的不可用错误，未开放连接入口。以上本轮代码均未构建、未用真实账号验收 | P2：完善 115/百度授权与续期；取得光鸭接口文档及应用授权后接入；四端验收 |
| 视频格式 | MKV、ISO/光盘目录、AV1、VVC 等广泛格式 [来源](https://firecore.com/infuse) | AVPlayer + 官方 VLCKit 双路径；ISO 路径与本地 VIDEO_TS/BDMV 目录识别及 VLC 打开代码；本机旧样本 MP4/MKV 播放过，尚未做完整格式矩阵或光盘设备验收 | **P0：四端 MP4/MKV/主流编码验证**；P2：光盘目录验收 |
| 音频与画质 | 多音轨、4K/HDR、Dolby Vision、Atmos 等随设备/内容组合支持 [来源](https://firecore.com/infuse) | 内嵌音轨选择代码；HDR 和输出组合未验证 | **P0：音轨与能力矩阵**；P1：HDR、音频输出优化 |
| 字幕 | 多种内嵌/外挂字幕、在线字幕下载 [来源](https://firecore.com/infuse) | 内嵌轨道选择；SRT/VTT 文本叠加，ASS/SSA/PGS 接入 VLC 原生外挂字幕路径；OpenSubtitles 搜索与下载代码，需用户提供 API key；尚未验证 | **P0：SRT/内嵌轨道四端验收**；P1：高级与在线字幕验收 |
| 影片整理 | 自动元数据、海报、演员、评分、预告片、筛选、收藏、合集、播放列表 [来源](https://firecore.com/infuse) | TMDB 手动/批量匹配、详情、海报、演员、预告片外链、筛选、收藏、合集、智能播放列表和资料修正代码 | **P0：匹配准确性与海报缓存验收**；P1：合集验收；P2：智能播放列表待验证 |
| 扫描与大库 | 自动扫描更新；服务端可按需浏览以减少本机索引 [来源](https://support.firecore.com/hc/en-us/articles/360006462093-Streaming-from-Plex-Emby-and-Jellyfin) | 增量扫描、同名移动推断、删除检测、离线保留和 SQLite 增量写入代码；未压测 | **P0：文件变化验收**；P1：大库压测与按需模式 |
| 跨设备同步 | iCloud 同步片源、收藏、手动匹配、进度与已看状态等 [来源](https://support.firecore.com/hc/en-us/articles/115000070773-iCloud-Sync) | CloudKit 进度、收藏、合集和智能播放列表；网络片源非凭据配置同步代码已写入，新设备需重新授权；本地文件与非默认观看资料仍仅在本机 | **P1：签名、两设备冲突与离线恢复验收** |
| 播放控制 | 章节、速度、手势、键盘/遥控器快捷操作、连续播放 [来源](https://support.firecore.com/hc/en-us/articles/215090987-Playback-Controls) | 快进快退、倍速、章节、下一集和自动连播代码；VLC 在 iPhone/iPad/Mac 有时间轴，tvOS 有进度条、跳转按钮和百分比跳转菜单；专用触摸手势未实现 | **P0：四端基础控制验收**；P1：快捷操作与手势 |
| 离线与传输 | 下载到设备、浏览器上传、AirDrop 等 [来源](https://support.firecore.com/hc/en-us/categories/202279357-Infuse) | 片源下载、进度、取消、离线优先播放与删除；HTTP/SMB 暂停与续传、SMB 下载前空间检查、中断任务自动恢复代码；iPhone/iPad/Mac 会话式浏览器上传代码已写入，未验证 | **P1：下载管理与断网验收**；P2：浏览器上传待验证 |
| 投屏 | AirPlay、Google Cast [来源](https://firecore.com/infuse) | 系统外部播放与 iOS PiP 控件；VLC 播放页新增 Chromecast 发现和渲染器切换代码，均未进行设备验证 | **P1：AirPlay/PiP 真机验收**；P2：Cast 设备验收 |
| 个性化与家庭 | 收藏、合集、多用户配置、家长控制 [来源](https://support.firecore.com/hc/en-us/categories/202279357-Infuse) | 收藏、合集、独立观看资料、本机进度与收藏隔离、儿童资料逐片可见性和家长 PIN 代码 | **P1：合集与同步验收**；P2：多资料和家长控制待验证 |
| 第三方同步 | Trakt 双向观看状态/进度与评分同步 [来源](https://support.firecore.com/hc/en-us/articles/4405098078743-Trakt-Sync) | 设备码授权、观看状态、进度和个人评分同步代码已写入，未做账户验收 | P2：Trakt 授权与同步验收 |
| 网络诊断 | 片源速度测试、连接故障排查 [来源](https://support.firecore.com/hc/en-us/articles/7551452226967-Testing-Streaming-Speeds) | 单文件范围读取测速，AVPlayer/VLC 缓冲与中断次数展示代码 | **P1：测速与缓冲诊断验收** |
| 新增高级能力 | 片头/片尾跳过、附加片段、AI 放大等在近期版本中出现 [来源](https://firecore.com/releases) | 用户手动设置片头/片尾时间并跳过；本地附加片段关联与播放代码；AI 放大未实现 | P2/探索，不作为首版验收条件 |

## 发布顺序与验收门槛

### 里程碑 1：可用的 NAS 播放器（P0）

1. **工程与播放能力**：四端可编译、真机播放；建立容器×编码×字幕×设备矩阵。对于常见 MKV 和字幕缺口决定并集成合适内核；不能只靠文件扩展名宣称兼容。
2. **SMB 片源**：发现/手动添加、Keychain 凭据、列目录、范围读取、随机拖动、断线重连与明确错误；四端均可仅凭自身完成添加到播放。
3. **媒体库**：电影/剧集/季/集解析，稳定文件标识，增量扫描与离线保留，元数据与海报缓存，手动匹配覆盖自动识别，最近添加、搜索和详情页。
4. **播放体验**：音轨/字幕选择、同目录外挂 SRT、速度、续播/已看状态，Siri Remote、触摸和键盘可完成主流程。

完成标准：从一份包含 100 部电影、10 部剧集及常见字幕的 SMB 测试库，在四端完成添加、扫描、纠错、播放和续播；网络短断后媒体库仍可浏览，重连后可继续播放。指标阈值由阶段 A 真机基线确定。

### 里程碑 2：跨设备与媒体服务器（P1）

- CloudKit 同步进度、已看、手动匹配与收藏；冲突与重复文件策略可解释、可恢复。
- Jellyfin 与 Plex 连接器；先支持列表、详情、直连播放和状态回写，再优化大库按需模式。
- WebDAV、外挂高级字幕、AirPlay/PiP、下载管理、收藏与合集、网络诊断。

完成标准：同一影片在两台设备间接续；服务器新增/删除影片后列表正确更新；离线操作恢复联网后不会丢失观看记录。

### 里程碑 3：生态与高级格式（P2）

Emby 基础连接器已写入。更多网络协议和云盘、Trakt、Google Cast、多用户与家长控制、光盘目录/复杂格式、预告片和智能播放列表按实际用户需求和各服务 API/许可证条件逐项立项。

用户指定新增四家网盘：**115、123 云盘、光鸭云盘、百度网盘**。123 云盘可走其官方 WebDAV，也已写入开放平台直连代码；115 与百度网盘已写入直连数据链路，但仍需官方应用授权和令牌续期接入。优先使用公开、正式授权的接口，不以网页 Cookie 或未公开接口冒充稳定支持。115 开放平台需要开发者入驻审核。用户提供的[光鸭云盘入口](https://app.guangyapan.com/pan)在未登录状态下仅显示产品介绍，确认“三方应用授权，直连云盘文件”，未展示授权或文件 API 文档；正式接入需取得其开放能力文档与应用凭据。完成条件是四端登录/授权、增量扫描、随机拖动、断线续播、离线下载、令牌续期与错误恢复的真实账号验收。

本轮补充的智能播放列表、资料与儿童资料、手动片头片尾标记、预告片/演员、ISO 与本地光盘目录路径、Cast 发现、浏览器上传、Trakt、云盘、OpenSubtitles、FTP/SFTP/NFS 目录和 DLNA 均仅为代码阶段，尚未按用户要求执行构建和设备验收。仍缺 Google Drive 应用内 OAuth、光盘完整菜单兼容性和 AI 放大；不能据此宣称 P0–P2 全部完成。浏览器上传为局域网 HTTP 临时会话地址，需保持接收设备在前台并处于可信网络。

## 技术决策补充

- **优先完成播放兼容性测试**。Infuse 的格式表是竞品能力范围，不是 AVPlayer 的能力表；第二内核的引入要同时评估 tvOS、包体、功耗、字幕渲染及 LGPL/GPL 义务。
- **网络片源统一接口**：`list(path)`、`stat(path)`、`openRange(path, offset, length)`、`authenticate`、`healthCheck`。SMB、WebDAV 和媒体服务器适配器复用扫描与播放层。
- **数据库替代 JSON**：文件、作品、剧集、版本、片源、用户修正和播放状态分表；文件 ID 不依赖海报标题，重命名与重新扫描能保持进度。
- **同步不上传本地路径或明文密码**。跨设备片源需重新授权或使用受保护的凭据同步；先定义隐私和冲突规则，再引入 CloudKit。
- **Google Drive 的 tvOS 授权**：Google 设备码流程目前仅允许 `drive.appdata` 和 `drive.file`，不满足扫描用户整个现有云盘的只读需求；tvOS 暂保留手动令牌入口，iPhone/iPad/Mac 的原生授权需另接 Google 支持的 SDK。[官方说明](https://developers.google.com/identity/protocols/oauth2/limited-input-device)
- **不追求逐项复制**。优先把家庭 NAS 播放、电影剧集整理、字幕和四端续播做稳定，再扩展云盘和高级能力。

## 来源

- [Infuse 产品功能与格式表](https://firecore.com/infuse)
- [Infuse 官方帮助中心](https://support.firecore.com/hc/en-us/categories/202279357-Infuse)
- [Infuse 版本记录](https://firecore.com/releases)
