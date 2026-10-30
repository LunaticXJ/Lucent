# 《兰香如故》第一集播放失败：日志与修复

## 复现证据

用户在真机复现并停留报错页后读取 `AetherRouting.log` / `PlaybackAudit.log`，对应条目为第一集《沈家灭门，嘉兰入林府》，Emby ID `142808`，续播位置约 0.967 秒。

日志顺序：

```
[MPV] load start=0.9666555555555556 paused=false parkedReuse=false
[MPV] end file reason=4 error=-13 loading failed
[MPV] ffmpeg error: tls: Error in the pull function.
[MPV] ffmpeg error: tls: IO error: End of file
[MPV] stream error: Failed to open <media-url>
```

视频源在 MPV 的 HTTPS/TLS 打开阶段失败，未进入解码。影片默认音轨为 AAC；另有 E-AC-3、AV3A 和 AAC 音轨，不能仅因存在未知音轨就推断为解码错误。

独立读取服务器元数据确认：MP4、HEVC Main 10、`CodecTag=hev1`、3840×2160、PQ。第一、二集通过系统网络字节转发后，命令行 FFmpeg 均能识别视频、音轨与时长。该结果不能替代 iPhone 实际播放验证。

## 根因

1. `PlaybackRouteDecision` 将 `hev1` 直接分配给 MPV，跳过了 Aether 的原生兼容封装机会。
2. Emby 起播选择初始 URL 时只判断用户显式偏好。自动决策在之后才选到 MPV，`playWithMPV` 又直接使用传入 URL，因此自动路由漏过本机 Range 代理。MPV 实际通过自身 FFmpeg TLS 打开外部签名 CDN，触发上述错误。
3. `retryDirectMPV` 仅在 Range 代理报告读取错误后才生效。本例根本没有进入代理，因此不会触发该恢复条件。

不推断 CDN 服务端为何关闭 TLS，也不声称所有网络故障均由客户端造成。本轮修复的是已经确认的网络入口遗漏。

## 参考实现及差异

- Sodalite `31799bd` 使用 Aether 作为原生媒体会话入口；参考其原生优先及由 Aether 处理容器兼容的分工。
- 已固定的 AetherEngine `61250c9f` 中，`AetherEngine.swift` 的 HEVC 原生回环封装、播放标准选择使用 `hvc1`，因此 `hev1` 不应仅按容器标签一律排除原生路线。
- Lucent 已有经系统 URLSession 读取的 Range 代理，在本例命令行链路检查中可用。此处保留该传输层，不照搬参考项目的直接远端拉流方式，不关闭 TLS 验证，不切换到服务器转码。
- 本轮为设计借鉴，没有复制参考项目实现代码。

## 修改

- `PlaybackRouteDecision` 增加明确的 `useAether` 决策：自动模式下 `hev1` 优先原生重封装；明确选择 MPV、复杂字幕和其他不兼容编码仍遵守既有决策。
- `PlaybackTransportPolicy.mpvURL` 统一选择静态 Emby 文件的本机代理。没有代理的普通网络地址、本地下载、HLS 和服务器转码保持各自入口。
- MPV 冷起播、热切换目标、失败回滚、重新连接、片尾重播均经过同一 URL 选择函数，避免入口之间再次遗漏。
- 新增的 `hev1` Aether 路线同样使用系统网络代理，避免只是换了解复用内核、仍重复相同远程 TLS 失败。
- 播放信息与诊断日志记录实际使用 Range 代理，不记录服务器令牌或签名媒体 URL。

## 检查

- `python3 scripts/verify-playback-routing.py` 已通过：hev1 原生重封装、hvc1 原生直读、显式 MPV、复杂字幕路由，以及本地/HLS/转码/代理边界。
- iOS Debug 构建，成功后安装到 jiangyi 的 iPhone；不自动启动应用或进行播放回归。
- 待用户手动验证第一集起播、续播，以及明确切换 MPV 后的起播。不能将构建通过或命令行解复用成功描述为真机已修复。
