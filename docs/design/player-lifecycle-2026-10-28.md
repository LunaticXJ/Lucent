# 播放器控件与前后台状态（2026-10-28）

## 参考与方案

- 参考 Sodalite `31799bd` 的 `Player/PlayerPiPController.swift` 与 `PlayerHostController.swift`：自定义控制界面用宿主持有的 `AVPictureInPictureController`，复用正在播放的 AVPlayer，源图层尺寸与视频一致；在 PiP 启动前通知 Aether `pictureInPictureActive`，避免后台生命周期错误回收内核。
- 借鉴架构，未复制 GPL 实现。Lucent 不随 PiP 关闭整个播放器页面，也不采用自动上滑开启 PiP。
- Apple 官方接口：[AVPictureInPictureController](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller)、[AVPlayerAudiovisualBackgroundPlaybackPolicy](https://developer.apple.com/documentation/avfoundation/avplayeraudiovisualbackgroundplaybackpolicy)。不使用私有 AVKit 方法模拟点击。

## 修改

- 两个 AVKit 宿主关闭自动画中画；原生路径增加独立小窗按钮，使用系统 `isPictureInPicturePossible` 控制可用性。
- PiP 复用同一 AVPlayer，不重复网络拉流、解复用或解码；启动时临时解绑 AVKit，避免 AVKit 与宿主 PiP 同时管理播放器。恢复后重新绑定。
- 原生播放器请求 `.continuesIfPossible` 后台策略。Aether 保留默认后台音频能力，PiP 活跃状态由宿主委托同步。
- PiP 播放/暂停回调同步 Lucent 的播放意图；关闭窗口明确暂停，恢复全屏保持当前播放状态。缓冲、拖动、初次加载、内核切换过程中不使用瞬时零速判断用户暂停。
- 前台恢复等待 350ms，让系统和内核生命周期回调完成，再读取稳定状态。取消过期任务，避免旧后台/前台回调覆盖新状态。
- 统一玻璃控件使用深色环境与黑色着色，改善亮画面上白色图标和背景对比。
- 顶部删除信息按钮；播放设置保留播放信息入口，与音轨、字幕、倍速共用侧边弹窗容器，无额外导航页面或嵌套滚动。

## 播放信息补齐

- 参考 Sodalite `UI/StatsOverlayView.swift` 的“运行内核信息优先、服务器信息补缺”方式。
- 复用服务器已返回的 MediaSource；Aether 读取实际流信息，MPV 读取 video-params / audio-codec-name 等属性；直接 AVPlayer 异步读取已打开资产的轨道及格式说明，不另开媒体 URL 探测。
- 不把片源 Dolby Vision / HDR 标记描述为设备已成功输出；无法识别的字段显示“暂不可用”，读取阶段显示“读取中”。

## 验证边界

- iOS Debug 编译与签名安装；不自动启动应用，不进行界面或播放回归。
- 当前新增的显式 PiP 适用于原生 AVPlayer 视频路径；MPV 和 Aether 软件视频路径没有伪造可用的小窗按钮。
- 仍需真机手动检查：明亮 HDR 片段控件对比；上滑后无自动小窗；手动打开小窗并暂停/恢复；关闭小窗再回应用；小窗恢复全屏；反复前后台；缓冲及内核切换时按钮状态；播放信息弹窗字段更新。
- 第三方字幕覆盖层不直接进入系统 PiP；Aether 使用自身的原生字幕渲染能力。具体片源和外置字幕的 PiP 效果需真机确认。
