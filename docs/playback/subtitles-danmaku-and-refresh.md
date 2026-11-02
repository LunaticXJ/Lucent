# 在线字幕、弹幕与服务器首页同步（2026-11-01）

## 参考与边界

- [IINA OpenSubClient.swift](https://github.com/iina/iina/blob/develop/iina/OpenSubClient.swift)：研究 REST API 的 search/login/download 分层、账户 token 过期、账户专用 base_url、多文件结果及额度错误处理。IINA 为 GPL-3.0，本次仅借鉴协议分层与流程，未复制代码或其应用 API Key。
- [OpenSubtitles 官方 API 说明](https://opensubtitles.tawk.help/article/about-the-api)：使用 opensubtitles.com REST API，不使用已退役的 .org XML-RPC。
- [弹弹play 开放网络](https://doc.dandanplay.com/open/)和 [Swagger](https://api.dandanplay.net/swagger/v2/swagger.json)：使用 `search/episodes`、`comment/{episodeId}`、`withRelated=true` 和 SHA-256 签名头。按文档采用 AppId + Timestamp + Path + AppSecret 的签名形式，响应跳转 CDN 时剥离凭据。
- [uosc_danmaku/apis/dandanplay.lua](https://github.com/dyphire/uosc_danmaku/blob/main/apis/dandanplay.lua)：研究搜索后选集、弹幕下载/缓存、时间与模式的处理流程；未复制代码或其服务凭据。
- [IINA+](https://github.com/xjbeta/iina-plus) 为 macOS 弹幕集成参考，未引入其 GPL-3.0/Web 渲染组件；Lucent 使用独立 SwiftUI Canvas 时间轴，避免依赖 MPV 特定字幕轨道。
- Infuse/SenPlayer 作为入口组织和交互参考，不声称使用其私有实现。播放转场按用户参考视频重新实现，不将视频或原应用素材打包进应用。

## 使用

1. 设置 → 字幕与弹幕服务：填写自己的 OpenSubtitles API Key，可选登录账户；填写自行申请的弹弹play App ID / Secret。密钥和账户 token 存钥匙串，不进入媒体库/CloudKit。
2. 播放器 → 字幕 → 搜索或添加字幕：可改片名、选择语言、分页搜索或从文件导入。每个字幕文件单独显示，下载保存后即刻交给当前播放会话。
3. 播放器 → 弹幕：片名搜索/按 TMDB 资料匹配当前集、人工确认正确的版本后加载；支持弹弹play JSON 与 Bilibili XML 本地导入。选集后不自动假定不同季度的集号等价，用户确认用于避免错配。
4. 弹幕支持开关、字号、透明度、显示区域、速度、时间偏移和屏蔽词；当前影片选择持久化，回看无需重新选择。网络原始缓存复用 24 小时，总量限制 100 MB；用户已选的弹幕作为本机影片资料保留，可在弹幕面板移除。
5. 播放光盘转场默认开启，设置 → 播放可关闭；尊重系统减少动态效果。光盘从详情页中央缩入右上方，原页面渐隐；退出后等待竖屏恢复，反向展开光盘并渐现详情。连续播放下一集不重播转场。HDR/杜比视界视频层不做截图、遮罩或变形。

## 生命周期与同步

- 外挂文本字幕走现有叠加层，不重新加载影片。ASS/SSA/SUP 在 MPV 中使用字幕轨；原生明确锁定时 ASS/SSA 仅提供文本降级，SUP 提示需 MPV。自动模式的特效字幕允许切到 MPV。
- 弹幕独立于字幕轨道。用当前内核时间锚点绘制、暂停/缓冲/后台停止推进、seek 后二分定位当前窗口；不维护会积压或重复注入的逐条任务队列。轨道预分配在后台运行，满轨道丢弃拥挤条目，保持非重叠。
- Emby 首页刷新替换成功获取的目录、推荐、续播和分类栏目；失败保留旧快照。成功空结果也覆盖旧缓存，不会切回页面后复活已删除内容。
- 服务器读取绕开 URLCache，图片继续使用独立缓存。Emby/Jellyfin 按已打开条目 ID 分批分页核对；Plex 对已打开条目限并发查询。只在全部核对成功后更新本地缓存，新增内容由正常首页分页带回，不扫描/导入服务器全库。
- 401/403、超时、取消、异常分页不等于“已删除”。核对已删除条目不删除用户已下载影片。服务器账户/连接分别隔离。

## 验证

`python3 scripts/verify-playback-services.py` 离线运行真实解析/传输/布局代码，以 URLProtocol fixture 覆盖多文件字幕、季集/语言/页码参数、登录 token/额度、下载不转发凭据、弹幕模式/去重/XML/密集轨道防碰撞、seek 窗口，以及服务器 ID 分页/空库/删除/越界返回。

构建和离线检查不能证明真机画面与音频连续，也不能证明具体服务的账户额度或授权已生效。默认不自动运行应用，由用户在安装后验证在线搜索、字幕切换、弹幕同步及进出播放动效。
