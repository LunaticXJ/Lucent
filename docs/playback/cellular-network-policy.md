# 移动网络策略（6048）

入口：设置 → 移动网络。

- 移动网络同步、移动网络下载默认关闭，独立配置。
- 同步覆盖 iCloud、Trakt 及服务器观看记录/收藏回写。限制期间观看状态保留在本地；服务器状态用持久化 ID 队列合并，恢复允许的网络时补传最新版本，不覆盖期间较新的本机修改。普通浏览、手动搜索和资料获取不是播放状态同步。
- HTTP 下载（包括断点续传）使用配置了 `allowsCellularAccess` 的 URLSession。SMB 每个分块检查策略；网络切换时暂停在途任务并保留可续传资料。启动时不会在限制网络批量恢复下载。
- 远程播放在解析/拉流前询问，仅当前影片有效；本地文件与已下载版本免提示，强制使用远程版本的播放仍要确认。
- Wi-Fi → 移动网络切换后停止读取并保留续播位置，确认后重新协商地址并从原位置恢复，保留原来的播放/暂停意图。拒绝则退出播放，不在后台继续缓冲。
- 初始网络状态未知时先等待路径监测；远程播放仍无法确认时保守询问，下载暂缓，避免“未初始化的 Wi-Fi 状态”导致流量消耗。

## 官方参考

- [URLSessionConfiguration.allowsCellularAccess](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/allowscellularaccess)：新任务与续传会话都设置系统网络约束，不能仅在按钮点下时检查一次网络。
- [CKOperation.Configuration.allowsCellularAccess](https://developer.apple.com/documentation/cloudkit/ckoperation/configuration-swift.class/allowscellularaccess)：用 `CKDatabase.configuredWith(configuration:body:)` 约束整个异步数据库操作及分页。
- 网络类型由 Network.framework 的 NWPathMonitor 观察；监测是状态提示，不能替代 HTTP/CloudKit 的传输限制。

## 验证边界

`python3 scripts/verify-network-usage.py` 离线验证网络/许可矩阵、每次播放确认、本地与下载豁免，以及下载/续传/SMB 分块/CloudKit/Trakt/播放器时序接线。

未自动操作模拟器或真机。真实蜂窝切换、服务端断点续传与 Personal Team 不支持的 iCloud 场景不能由构建或离线检查证明；安装后需用户手动验证。
