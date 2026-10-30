# Lucent 技术方案与验证计划

更新：2026-10-21。以下为已写入代码的方案与验证计划；构建状态与待验收项见各节及 README。

## 决策摘要

| 层 | 选择 | 原因与边界 |
| --- | --- | --- |
| 语言与 UI | Swift 6、SwiftUI，按平台拆分导航和播放控件 | Apple 四端共用代码，同时保留遥控器、触控、键鼠的原生交互。 |
| 播放 | `PlayerEngine` 协议；AVPlayer/AVFoundation 为首个实现 | 系统集成度高，可先验证主流 MP4/HLS。MKV、复杂字幕和特殊音轨不可先假定支持。 |
| 扩展播放 | 锁定版本的 MPVKit | 负责 MKV 等扩展容器、FTP/SFTP/NFS 直链和光盘结构；引入前完成性能、包体、平台支持及许可证审查。VLCKit 已移除。 |
| 持久化 | SQLite 增量写入，旧 JSON 导入；Keychain 存凭据 | 避免播放进度更新时重写完整媒体库；需在 Xcode 中验证数据库迁移。 |
| 网络片源 | SwiftSMB 3.3.1、WebDAV、Jellyfin、Emby、Plex、DLNA、云盘；本机 HTTP 范围代理连接播放内核 | 代码已接入但尚未完成真机验证。SwiftSMB 依赖动态 libsmb2，发行前须完成 LGPL 合规审查。 |
| 元数据 | 可替换的 `MetadataProvider`，默认不阻断本地使用 | 避免把媒体库与外部服务或 API 配额绑定。选用服务前核对授权、条款及图片缓存规则。 |
| 同步 | CloudKit 私有数据库同步网络片源的状态与收藏 | 凭据不上传；本地文件和片源配置尚未跨设备同步。 |

## 模块边界

```text
LucentApp（平台 UI）
  ├─ Library（列表、搜索、详情、识别纠错）
  ├─ Playback（状态、控制、进度记录、PlayerEngine）
  ├─ Sources（本地文件、SMB、WebDAV、Jellyfin、Plex）
  ├─ Metadata（本地解析、TMDB 在线匹配）
  └─ Persistence（SQLite、CloudKit、Keychain）
```

数据模型最少包含 `Source`、`MediaFile`、`Title`、`Episode`、`PlaybackProgress`、`MetadataOverride`。以片源 ID + 规范化相对路径作为稳定文件键；文件大小和修改时间辅助判断增量变更。扫描工作在后台执行，支持取消，并避免因片源暂时离线而删除索引。

网络视频通过仅监听本机回环地址的范围 HTTP 服务转给播放内核，认证仍由片源连接器完成。当前 SMB 分段读取每次建立连接；需实测高码率、随机拖动、断网重试、内存与系统限制。第二播放内核已确定为 MPVKit。

2026-10 更新：播放设置已提供 AVPlayer、MPV 和自动选择。自动选择对系统容器使用 AVPlayer，对 MKV 等扩展容器使用锁定版本的 MPVKit；iOS/tvOS 采用其 MoltenVK/Metal 输出，macOS 暂用 libmpv OpenGL 输出。MPV 必须等渲染视图就绪后再加载文件，否则视频轨会因缺少渲染上下文被禁用。2026-10-21 已移除 VLCKit 依赖和 VLC 播放内核，ISO/VIDEO_TS/BDMV 交由 MPV 尝试播放，不再提供光盘菜单。iPhone 模拟器已验证本机 H.264 MKV 的画面与 HTTP Range 拖动；Emby 115 CDN 长时间播放、tvOS/macOS 实际画面和真机 HDR 仍待验证。

2026-10-21 直连排障：真实 Emby 的一部 STRM 电影在 iPhone 模拟器中可经 MPV 解析 10.14 GB MKV、读到开头与尾部，并推进到约 20 秒；后续 Range 在约 19.9 MB 处遇到 `NSURLErrorDomain -1005`。Mac 上独立使用同一账号、同一 Emby 流接口读取该偏移时也曾遇到 TLS EOF，而重新请求该偏移及附近位置又返回 206，说明故障具有间歇性，不能归因于固定损坏区间或单一播放器内核。桥接服务现等待首块成功才回 206、以较小数据块读取，并在播放已开始后保留直连服务供 MPV 按进度重连；这些恢复措施仍需实际长时间播放验收。排障日志只记偏移、字节数和错误域/代码，不记录令牌与签名链接。

2026-10-21 播放验收：真实 Emby 影片《希望》（MKV、H.264、EAC3、1920×800、2:37:01）在 iPhone 17 Pro Max 模拟器中经 MPV 直连起播，画面推进正常，播放信息显示远程直连、缓冲正常、0 次中断。验收中发现详情页在服务端进度为 0 时会覆盖本地续播位置；已改为取本地与服务端进度的较大值，复查从 00:56 续播到 01:09。

## 阶段 A 必测矩阵

在各平台至少选一台真实设备，使用已获授权的样本文件，记录「可打开、首帧时间、拖动、字幕、音轨、HDR/色彩、功耗/发热、崩溃」。样本至少包含：MP4/H.264/AAC、MP4/HEVC、MKV/H.264、MKV/HEVC、内嵌 SRT/ASS、外挂 SRT、双音轨，以及高码率 4K 文件。网络条件包括本地、稳定 SMB、断线重连和慢速 Wi-Fi。兼容性以测试报告为准，不根据扩展名承诺。

决策门槛：若 AVPlayer 在目标用户常见样本中不能完成 MKV/字幕/音轨等关键场景，先评估替代内核的跨平台构建与许可证；只有通过四端真机回归后才纳入首版。FFmpeg 的许可会随构建选项变化，不能直接把任意预编译包用于商业发行。

## 工程约定

- 建议使用 Xcode 多平台工程；共享纯 Swift 模型与服务，平台特有 UI 和权限配置分开。
- 数据库 schema 从第一版起做迁移；扫描、播放进度写入需幂等。
- 凭据只存 Keychain；日志不记录密码、完整访问令牌或包含凭据的 URL。
- 本地文件访问遵守系统安全作用域；请求局域网权限时说明用途。
- 首版测试优先覆盖扫描幂等、文件名解析、进度恢复、离线重连，以及四端真机播放回归。

## 待实测后定案

1. AVPlayer 对目标格式的实际覆盖，以及是否需要第二播放内核。
2. SMB 库的四端可编译性、范围读取性能、重连行为与维护情况。
3. 元数据服务的授权、地区覆盖、请求限制及隐私文案。
4. 最低系统版本和设备范围，以目标市场与性能测量决定。
5. SwiftSMB 的四端构建、动态 libsmb2 打包、随机读取性能和 App Store 发行义务。

## 依据

- [Apple SwiftUI 多平台开发](https://developer.apple.com/documentation/technologyoverviews/swiftui)
- [Apple AVFoundation 概览](https://developer.apple.com/av-foundation/)
- [Apple 多平台 App 配置](https://developer.apple.com/documentation/Xcode/configuring-a-multiplatform-app-target)
- [Apple 文件夹访问与安全作用域](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
- [FFmpeg 许可证说明](https://www.ffmpeg.org/legal.html)
- [VideoLAN iOS/VLCKit 项目](https://github.com/videolan/vlc-ios)（已移除，保留为历史参考）
- [MPVKit 项目](https://github.com/mpvkit/MPVKit)
- [SwiftSMB 项目与许可说明](https://github.com/RuiNelson/SwiftSMB)
