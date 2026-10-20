# Lucent

## 杜比视界播放

MP4、M4V、MOV 和 HLS 默认经系统 AVPlayer 播放，保留兼容流的杜比视界元数据；详情页识别 Emby/Jellyfin 报告的 Dolby Vision 视频流与版本容器，播放页进一步检查 AVFoundation 的视频流描述。选择服务器的不同版本时，会使用该版本的实际容器决定播放内核。杜比视界 MP4 搭配 ASS/SSA 外挂字幕时，字幕改为应用内文本叠加，以保留系统播放路径。MKV 等扩展格式默认使用 MPVKit；完整光盘结构暂由 VLCKit 播放。MPV 和 VLC 路径尚不能保证杜比视界动态元数据输出；实际激活仍取决于视频 Profile、设备及显示链路。音频直通尚未实现。

影片详情展示服务器提供的播放版本、分辨率、编码、动态范围与容器；播放页的“播放信息”面板显示实际播放器内核、直连或转码、选路原因和缓冲状态。播放设置可手动选用 AVPlayer 或 MPV。系统播放器路径在拖动进度时生成画面预览；MPV 路径暂无进度缩略图。

Lucent 是面向 iPhone、iPad、Apple TV 和 Mac 的个人媒体库播放器。产品目标是让用户连接自己的视频文件与家庭媒体服务器，快速整理、查找并稳定播放影片。

当前阶段：P0/P1 尚未达到完成标准，P2 的 Emby 直连目录浏览已加入。工程已写入本地文件、SMB、WebDAV、Jellyfin、Emby、Plex 片源，范围读取桥接、AVPlayer/MPV 播放路径、续播、SRT/VTT/ASS/SSA 文本字幕与音轨、Jellyfin/Emby 登录、Plex PIN 授权、在线资料匹配、海报、SQLite 媒体库、CloudKit 状态及合集成员同步、下载与合集等代码。Emby 连接后只保存服务器，浏览目录时按页获取内容，不再自动扫描全库。iPhone 模拟器已通过本机 H.264 MKV 的 MPV Metal 画面和范围拖动测试；Emby 的 115 CDN 长时间播放、Apple TV 与 Mac 的实际画面仍待验证。

工程文件由 XcodeGen 生成。克隆仓库后先运行 `./scripts/setup-vlckit.sh` 下载并校验 VLCKit，再运行 `xcodegen generate`；MPVKit 由 SwiftPM 拉取锁定的版本。VLCKit 二进制超过 GitHub 的文件大小限制，因此不纳入 Git。本机 iOS、tvOS 和 macOS Debug 构建已通过，iPhone 17 Pro Max 模拟器已验证 MPV 的本机样本播放。发行前仍须核查 MPVKit 与 VLCKit 的许可证义务和设备端解码表现。

- [产品与功能规划](docs/product-plan.md)
- [对标 Infuse 的差距与路线图](docs/infuse-gap-roadmap.md)
- [技术方案与验证计划](docs/technical-plan.md)
- [播放验证操作](docs/probe-guide.md)
