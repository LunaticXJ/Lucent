# NAS 影视服务器接入

新增飞牛私有云、极空间影视、绿联云影视，使用其对第三方播放器开放的 Emby 兼容媒体接口。

| 类型 | 默认协议 | 默认端口 |
| --- | --- | --- |
| 飞牛私有云 | HTTP | 8005 |
| 极空间影视 | HTTP | 8021 |
| 绿联云影视 | HTTPS | 9443 |

端口和路径可修改，粘贴完整地址时以地址中的协议、端口、路径为准。需要在 NAS 端开启第三方媒体服务并使用该服务允许的账户；旧版 NAS 未开放兼容服务时无法连接。保持现有 HTTPS 证书校验。

## 接入路径

- EmbyServerKind 保存品牌；旧的 EmbySource 没有 serverKind 时按 Emby 处理。
- ServerKind 负责入口/表单，NAS 默认账户密码登录，保留兼容服务的令牌登录。
- LibraryStore.addEmby 调用 Users/AuthenticateByName，验证用户后保存 Keychain 令牌及独立 source ID。同地址不同账户可同时添加。
- 复用 EmbyClient 的媒体库、搜索、详情、播放信息、直连、字幕和观看进度路径。首页目录键仍为 emby:sourceID，品牌不参与传输和索引。
- 修改账户创建新 source 时保留品牌，防止编辑后变回 Emby。

## 参考

借鉴协议设计与初始化顺序，未复制第三方代码：

- PT-depiler（MIT）：[fnos.ts](https://github.com/pt-plugins/PT-depiler/blob/master/src/packages/mediaServer/entity/fnos.ts)。核对 /emby/ 基址、Users/AuthenticateByName 的 Username/Pw、X-Emby-Authorization 和 X-Emby-Token，以及 Views/Items 字段模型。Lucent 保持自身 Keychain 与 source 生命周期，未照搬其浏览器密码存储和自动重登录机制。
- [MoviePilot 极影视兼容接口讨论](https://github.com/jxxghp/MoviePilot/issues/5584)。
- [绿联官方社区第三方播放器接入](https://club.ugnas.com/forum.php?mod=viewthread&tid=6256)。
- [Emby 官方认证文档](https://github.com/MediaBrowser/Emby/wiki/User-Authentication)。

品牌图标直接来自官方网站 favicon：fnnas.com/favicon.ico、www.zspace.cn/favicon.ico、www.ugnas.com/file/upload/2024-10/18/202410181636007801.png。极空间官方 favicon 为 32px。品牌标识归各厂商所有。

## 验证范围

编译及本地模型兼容检查不代表三种 NAS 固件的在线接入已验证。没有这些 NAS 的测试地址或账户；需手动验证登录、媒体库显示、起播/续播和观看记录回写。服务器未实现的兼容 API 会按现有错误处理反馈，不虚构结果。
