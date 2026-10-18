# 阶段 A：播放验证操作

当前工程已有 P0/P1 多个功能的源码。Xcode 27.1 已安装，三套 scheme 的 Debug 构建已通过，设备与服务器验收仍需按下表执行。

## 构建

1. 仓库根目录运行 `xcodegen generate` 可重新生成工程。
2. 打开生成的 `Lucent.xcodeproj`，选择 iOS、tvOS 或 macOS scheme；按设备配置签名并运行。
3. iPhone/iPad/Mac 验证本地文件、文件夹、HTTP(S)、SMB、WebDAV、Jellyfin、Plex；Apple TV 验证网络片源。逐项检查添加、扫描、进入详情和播放。
4. SMB 与 WebDAV 检查随机拖动、同名 SRT、短断线后的重试与续播；Jellyfin/Plex 检查分页、直连播放与状态回写。
5. 两台设备使用同一 iCloud 账户，验证 CloudKit 进度/已看/收藏同步和离线恢复；检查签名与容器配置。
6. iPhone/iPad 验证 AirPlay 与 PiP；四端验证音轨、字幕、倍速、下一集与遥控器/键鼠操作。

本机通用 macOS、iOS Simulator、tvOS Simulator Debug 构建于 2026-10-17 通过。最低系统版本 17/14 是验证工程的暂定值，并非最终产品承诺。

## 记录模板

每个样本记录：设备型号、系统版本、容器/视频/音频编码、分辨率、来源、能否起播、首帧时间、拖动、音轨、字幕、色彩/HDR、错误信息。分别覆盖规划文档中的格式矩阵。不要在仓库提交有版权的测试媒体或含凭据的地址。

AVPlayer 格式能力、CloudKit 签名、服务器 API 差异、下载恢复与四端交互都需要专项验证；不要从文件扩展名推断可播放性。
