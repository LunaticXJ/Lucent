# Lucent

Lucent 是面向 iPhone、iPad、Apple TV 和 Mac 的个人媒体库播放器。产品目标是让用户连接自己的视频文件与家庭媒体服务器，快速整理、查找并稳定播放影片。

当前阶段：P0/P1 尚未达到完成标准，P2 的 Emby 直连目录浏览已加入。工程已写入本地文件、SMB、WebDAV、Jellyfin、Emby、Plex 片源，范围读取桥接、AVPlayer/VLCKit 双播放路径、续播、SRT/VTT/ASS/SSA 文本字幕与音轨、Jellyfin/Emby 登录、Plex PIN 授权、在线资料匹配、海报、SQLite 媒体库、CloudKit 状态及合集成员同步、下载与合集等代码。Emby 连接后只保存服务器，浏览目录时按页获取内容，不再自动扫描全库。官方 VLCKit 二进制已校验并放入 `Vendor/VLCKit`；本机 MKV 样本通过 VLCKit 实际播放。ASS 样式/PGS 位图字幕、CloudKit 签名与冲突恢复、各服务器协议兼容性和四端交互仍待完成或验证。

工程文件由 XcodeGen 生成。克隆仓库后先运行 `./scripts/setup-vlckit.sh` 下载并校验 VLCKit，再运行 `xcodegen generate`。VLCKit 二进制超过 GitHub 的文件大小限制，因此不纳入 Git。本机已安装 Xcode 27.1，带 VLCKit 的 macOS、iOS 模拟器和 tvOS 模拟器 Debug 构建已通过；iPhone Duo 与 Apple TV 4K 模拟器已安装并启动应用。当前 iOS 27.1 运行时只提供 iPhone Duo 设备类型，iPad 启动、四端界面操作与真实服务器验收仍待完成。

- [产品与功能规划](docs/product-plan.md)
- [对标 Infuse 的差距与路线图](docs/infuse-gap-roadmap.md)
- [技术方案与验证计划](docs/technical-plan.md)
- [播放验证操作](docs/probe-guide.md)
