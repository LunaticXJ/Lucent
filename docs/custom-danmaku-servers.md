# 自定义弹幕服务器（2026-11-07）

## 实现

设置 → 弹幕 → 自定义弹幕 API，使用原生 Form、导航栈和列表行为，按需添加/编辑/删除，不固定堆放空槽。每台只提供名称、地址、启用状态和检测连接；不引入截图中的字体、简繁转换等额外设置。检测明确只验证搜索接口。

播放器弹幕面板只增加服务器选择，仍不提供服务配置入口。保存服务器后设为当前选择；禁用/删除或配置同步后处理失效选择。请求开始时捕获端点，返回结果绑定端点，下载使用结果原来的服务器；过期搜索结果不覆盖新服务器的列表。

- 地址接受根地址、鉴权路径或已经以 `/api/v2` 结尾的地址；保留编码路径及查询鉴权，避免重复 `/api/v2`。拒绝非 HTTP(S)、嵌入用户名密码及 fragment。
- 搜索 `/api/v2/search/episodes`，按名称发送 `anime`、`v2=true` 及可选集号。自定义端点不使用官方独有的 TMDB-only 参数；返回结构要求有效 `animes`，管理页 HTML/错误 JSON 不会被当成连接成功。
- 下载 `/api/v2/comment/{episodeID}?withRelated=true&format=json`，复用现有 JSON/XML 校验、模式、去重和数量限制。
- 官方服务继续使用原签名路径与 Keychain App ID/Secret，自定义服务不读取这些凭据。跨 origin 重定向剥离签名、Authorization 和 Cookie；拒绝 HTTPS 降级。
- 24 小时弹幕缓存改为完整端点摘要 + episodeID，服务器相同编号不会串缓存；摘要文件名不暴露鉴权地址。仍有 100 MiB / 24 小时清理上限。
- 配置和选择接入已有 iCloud 用户配置 allowlist，共用用户的同步开关。自定义 URL 内的鉴权路径也属于此配置；官方 App Secret 仍只在 Keychain。本次 Personal Team 包无 iCloud entitlement，不支持实际云同步验证。
- 沿用现有 ATS/局域网访问策略，不对所有域名关闭 ATS、不忽略证书校验。公网优先 HTTPS，HTTP 受系统策略约束；遇到 ATS 拒绝会明确提示使用 HTTPS。局域网用途说明补充了弹幕服务器。

## 参考与差异

研究了 `huangxd-/danmu_api` 当前 main（package.json 标记 1.0.0）的完整请求路线和模型：
- `danmu_api/worker.js`：鉴权前缀、`/api/v2/search/episodes` 和 comment 路由。
- `danmu_api/apis/dandan-api.js`：`searchEpisodes` 的名称检索及返回。
- `danmu_api/models/dandan-model.js`：`Episodes`、数值 `episodeId`、`episodeTitle`。
- https://github.com/huangxd-/danmu_api

该库 LICENSE 为 AGPL-3.0（package.json 的 ISC 字段与之不一致），这里只研究 HTTP 协议和调用顺序，没有复制服务端实现、导入依赖或复用代码。Lucent 自行实现原生 Swift 配置和客户端，不接入其管理接口、分片弹幕或任意站点解析扩展。

官方签名文档：https://doc.dandanplay.com/open/ 。官方签名只对原官方路径生效，不把官方认证套到自托管服务器。

## 验证

`verify-custom-danmaku.py` 编译实际客户端，只注入 URLProtocol 和临时缓存目录；不访问用户服务器、不读取真实凭据。覆盖根地址/完整路径、转义鉴权路径、查询参数、启用过滤、官方签名隔离、重定向、搜索去重/空列表/非法返回/401、结果端点绑定，以及两台服务器同 episodeID 的下载缓存隔离。

另运行现有 `verify-playback-services.py`、`verify-user-data-contracts.py`、`verify-localization.py` 和 `git diff --check`。构建/安装与运行验证分开报告；没有自动启动 App、访问截图中的服务器、复现真实弹幕播放或测试 iCloud 多设备同步。
