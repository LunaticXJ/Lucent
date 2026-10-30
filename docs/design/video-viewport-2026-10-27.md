# 横屏视频边界与画面缩放

## 问题与证据

用户提供的两张横屏截图中，Lucent 的视频左右有对称缩进，上下的留白也随视频缩小而增加。原实现只在整个 `playerContent` 上使用 `.ignoresSafeArea(edges: .vertical)`，视频和控制层共用横屏的安全区域宽度。

截图上 Lucent 的视频宽度约 1114px，另一个播放器约 1278px，画面比例都约 2.35:1。安全区使视频先缩窄，再按影片比例缩小高度，形成四周留白。片源比例与屏幕比例不同仍可能带来正常的上下或左右留白，不能通过拉伸人物来消除。

## 改动

- 视频层和全画面轻触层使用 `.ignoresSafeArea(.container)`，视频渲染区域使用完整屏幕。播放按钮、标题和设置抽屉仍保留横向安全区域。
- 所有视频层继续保留原有父子结构与内核对象身份，缩放不创建新的播放实例，不触发 seek 或重新拉流。
- 增加统一的 `VideoScaleMode`，默认 `fit`（等比适应），可选择 `fill`（铺满屏幕）。选择保存在 `lucent.player.videoScaleMode`。
- 播放页左上角、播放设置的“画面”分组、应用设置的“播放 → 画面”都可调整同一个值。
- AVKit 使用真正显示画面的 `AVPlayerViewController.videoGravity`；原生播放器重绑定后检查并重新应用，避免重新加载或切换内核后丢失铺满模式。
- Aether 的绑定显示层同步设置 `engine.videoGravity`；MPV 使用 `keepaspect=yes`、`video-unscaled=no` 与 `panscan=0/1`。初始化新内核和双向预加载时保持相同的模式。
- macOS 的直接系统播放显示层使用支持 `videoGravity` 的 `AVPlayerView`；iOS/tvOS 使用 `AVPlayerViewController`。
- Debug 日志新增 `[Lucent] video viewport=宽x高`，只在显示尺寸变化时记录，供后续手动运行时确认真实渲染区域。

等比适应保留完整画面；铺满屏幕按原比例放大并裁掉超出边缘的部分。MPV 原有的手动画面比例覆盖仍是独立功能。

## 参考

- Sodalite `31799bd`：`PlayerHostController.applyVideoGravity` 和重新绑定原生播放器后的恢复逻辑；`PlayerOverlayView.controlsOverlay` 中将视频与按钮安全边界分别处理的设计。仅借鉴设计，没有复制其 AVKit 内部负安全区域的 UIKit 修正方案，Lucent 的浮层挂载结构与其不同。
- 固定版本 Aether `61250c9`：`AetherPlayerView.applyLayerFrame` 使用 view bounds，`AetherEngine.videoGravity` 设置原生和软件显示层；该属性不能代替外部 AVKit 控制器自己的显示设置。
- [Apple AVPlayerViewController.videoGravity](https://developer.apple.com/documentation/avkit/avplayerviewcontroller/videogravity)。
- [Apple ignoresSafeArea](https://developer.apple.com/documentation/swiftui/view/ignoressafearea(_:edges:))。
- [mpv panscan 与 aspect override](https://mpv.io/manual/stable/#options-panscan)：铺满使用等比裁切，不将设备宽高比作为影片的 aspect override。

## 验证

最终 iOS 构建通过，日志为 `/tmp/lucent-fullbleed-final-build.log`；已安装到「jiangyi的 iPhone」，CoreDevice 安装序号 5984。项目原有 iCloud entitlement 未修改，真机构建使用临时空 entitlement 覆盖。

按照用户偏好，不自动启动或进行模拟器/真机播放测试。新布局的实际边界、切换内核后的裁切状态与字幕位置仍需用户手动验证。没有把 iOS 编译通过当作其它平台的运行验证。

建议重新打开《光阴之外》同一集：先使用等比适应检查额外的左右缩进；再点左上角缩放按钮检查铺满。宽银幕影片在等比适应下可能仍有窄的上下黑边，这是保留完整画面的比例差异。
