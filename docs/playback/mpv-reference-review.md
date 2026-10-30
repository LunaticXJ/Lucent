# MPV 接入对照与回归记录

日期：2026-10-23

## 参考

- Yattee，commit `55b6c63da1ce4780bd82426014edd70584619e93`：
  https://github.com/yattee/yattee
  - `Yattee/Services/Player/MPV/MPVSoftwareRenderView.swift`
  - `Yattee/Services/Player/MPV/MPVClient.swift`
  - 参考设计：模拟器使用软件渲染、渲染与播放器调用分线程、异步 seek。
  - 本次为 Lucent 独立实现，没有引入 Yattee 源文件或依赖。
- MPVKit 的 iOS Metal 示例作为真机接入基准。
- 随 MPVKit 分发的 `mpv/render.h`：渲染调用串行化，避免与普通 libmpv API 同线程阻塞。

## 本次实现

- iOS/tvOS 模拟器：`vo=libmpv` + 软件渲染；真机仍使用 Metal/MoltenVK。
- 独立串行渲染队列；同时最多一帧在途，避免任务堆积。
- CGImage 持有自己的像素数据，避免下一帧复用内存造成画面破坏。
- 退出时先停止计时与回调，再释放渲染上下文；丢弃退出前已排队的画面更新。
- seek 使用异步命令，避免网络/解复用阻塞主线程。
- 暂未替换 Emby Range 桥接。需独立核对重定向鉴权和签名 UA 后再考虑直交 MPV。

## 已观察结果

- 修复前，同一 Emby《希望》在模拟器显示紫色画面。
- 软件渲染后显示正常影片画面。
- 渲染线程分离后，02:38 断点续播、向前拖至 35:02 并推进至 35:16、向后拖至 10:13 并推进至 10:23 正常。
- 暂停停留在 10:23，恢复后推进到 10:24；退出保存 10:28，重新进入从该断点正常出画并推进到 10:29。
- iOS、tvOS 模拟器和 macOS 目标构建成功；macOS 保留已有 OpenGL 弃用警告。

## 验证边界

这些结果不代表真机 Metal/HDR/杜比视界或所有 CDN 片源均已通过。

## 2026-10-24：字幕位置与切换

- 对照 Yattee `MPVClient.swift` 的 `addSubtitleAsync` / `setSubtitleTrack`：外挂字幕异步添加，原位选择轨道，不重新加载影片。本次只参考设计，未复制代码。
- 对照 MPV 官方 `DOCS/man/options.rst`：`sub-ass-override=yes` 不会清除 ASS 内联定位，`force` 也会保留部分定位。因此默认使用 `strip` 和底部对齐。代价是文字字幕的原始特效/排版不再保留；位图字幕及硬字幕不保证可移动。
- SwiftUI 外挂字幕固定底部边距，不再随主控件显隐跳动。
- 关闭 MPV 字幕仅隐藏，保持已选轨道；恢复同一轨道和重复选择不再修改 sid。外挂字幕添加改为异步。
- MPV 官方 `player/loadfile.c:reselect_demux_stream` 与 `demux/demux.c:initiate_refresh_seek` 表明：不同内嵌轨道切换可触发共享解复用器回读并清空包队列。异步命令只解决调用线程阻塞，不能保证音视频不中断。此剩余限制需要独立字幕数据源或内核层处理，尚未解决，不能宣称无缝切换。
- 参考：https://mpv.io/manual/stable/#options-sub-ass-override 、https://github.com/mpv-player/mpv/blob/master/demux/demux.c 。对照的是上游 master，项目仍使用 project.yml 中固定的 MPVKit revision。
- 按用户约定仅构建、安装，不运行模拟器播放验证。

## 2026-10-24：Emby 独立字幕交付

参考 Jellyfin MPV Shim，commit `34bdfec6dc5b4fc707a2f9b9345c47c9153115f8`：
https://github.com/jellyfin/jellyfin-mpv-shim/tree/34bdfec6dc5b4fc707a2f9b9345c47c9153115f8

- `media.py:map_streams`：按服务端 DeliveryMethod / DeliveryUrl 区分 Embed、External、Encode，并保存服务端索引与播放器轨道的映射。
- `player.py:_add_external_sub/_external_sub_added`：异步交付，等待期间不锁住播放；以播放代次和当前选择判断结果是否过期。
- 该项目整体 GPLv3；本次仅参考设计、协议语义，用 Swift 独立实现，未复制其代码或加入依赖。平台不同，不能据此推断 iOS 运行验证通过。

Lucent 的实现：

1. Emby 直连启动后另行查询 PlaybackInfo，指定当前 MediaSourceId，允许直接播放且明确禁用视频转码，文字字幕请求 External 交付。视频请求与播放链路保持独立。
2. 只接受服务器实际返回的 External DeliveryUrl 和支持的文字格式；不拼造提取地址，不把字幕列表序号当服务器 stream index。内嵌轨道用 MPV ff-index 匹配；独立外挂轨道追加到字幕列表。
3. 字幕异步限量下载（8 MB），解码为现有 SubtitleCue 后交给 SwiftUI 随播放时钟显示。切换已下载的文字字幕只换 cues，隐藏原 MPV 字幕，不改 sid、不 seek、不重载视频。缓存最多四轨，退出清理。
4. 下载期间保留原字幕，失败也保留；每次选择/关闭/退出取消旧任务并更新代次，过期响应不能覆盖新选择。选中标记在成功装载后更新，加载期间显示等待状态。
5. 字幕请求仅向同源发送 Emby 令牌，跨源重定向去除鉴权头。日志和错误提示不输出 URL 或令牌。
6. 不支持独立交付的内嵌轨道仍由 MPV 切换，并提示可能缓冲。特别是 STRM 服务端未列出实际文件字幕、位图字幕、服务端无提取能力的情况，不能承诺无缝切换。没有把转码作为自动后备。

验证：iOS Simulator 目标构建成功；按约定安装最新版，不自动运行模拟器或请求真实服务器播放测试。独立交付是否由用户服务器提供、字幕同步和连续切换体验仍需手动验证。

## 2026-10-24：统一播放与跳转加载状态

- 参考上述 Yattee `MPVClient.swift` 对 `MPV_EVENT_SEEK`、`MPV_EVENT_PLAYBACK_RESTART` 与 `seeking` 属性的处理，独立实现 MPV 等待恢复状态。异步 seek 的命令失败会清理等待并显示错误。
- iOS 等横屏布局完成后开始解析片源。播放器框架先挂载，加载/缓冲/跳转只显示中央非交互式转圈，保留返回按钮和控制框架，移除整页加载遮罩与底部缓冲文本。
- MPV 跳转期间保留上一帧，等恢复事件和 seeking 状态结束后隐藏等待指示；AVPlayer 跳转使用 completion 和代次检查，防止旧请求清掉新跳转状态。
- AVPlayer 隐藏系统控制层，避免与 Lucent 自有控件、加载指示叠加。方向变化不重复启动已运行的 MPV 会话。
- 不进行模拟器 UI/播放测试；构建和安装不能替代手动验证。
