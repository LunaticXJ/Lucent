# 架构与性能优化清单（6059）

对应本轮审查的八项问题；这是现有架构的增量改造，没有变更播放内核、服务器凭据或用户操作语义。

| 审查项 | 落地实现 | 验证 |
| --- | --- | --- |
| 1 图片缓存主线程 I/O | ArtworkDiskStore actor 负责读写/淘汰；imageData 合并并发同 key 请求；ArtworkImageDecoder 后台缩略图解码，NSCache 64MB / 100 项 | iOS 编译；缓存代码边界检查；实际滚动待手动验证 |
| 2 进度保存全库比较 | LibraryRepository 串行后台写入；enqueueItem 单条写入；独立 playback_states 表按资料保存，v1→v2 自动迁移；后台切换 flush | 生产 SQL 测试：单条更新、资料恢复、快照写入顺序、删除 |
| 3 服务器状态乱序/丢失 | ServerStateOutbox actor 持久化最新状态、串行交付、版本确认、失败重试；失败条目不阻塞其他条目；移除服务器后丢弃无主记录 | 延迟交付时插入新状态、超时重试、磁盘恢复 |
| 4 核心类职责过多 | 存储归 Repository；同步归 Outbox；扫描任务/并发槽归 LibraryScanCoordinator；刮削 drain 生命周期归 MetadataCoordinator；目录遍历/并发槽归 LibraryScanCoordinator；目录分组归 LocalCatalogIndex；PlaybackSession 与 UI 分离 | iOS 编译；保留原 LibraryStore 页面接口 |
| 5 播放切换状态组合 | PlaybackTransitionCoordinator 唯一持有交接 generation、阶段、落点及播放意图；拒绝重复/关闭后的交接，旧回调不能结束新事务 | 双向交接重复 10 轮、暂停意图、取消旧回调、关闭拒绝 |
| 6 本地展示耦合传输 JSON | MediaCard 本地/服务器适配；首页布局与缓存改为消费 MediaCard，本地数据和分类不再序列化再解码；JellyfinItem 提供类型安全构造，legacyPresentation 是兼容边界 | iOS 编译；不删除详情页需要的完整 MediaSource/演员转换 |
| 7 首页无关更新触发重建 | catalogStructureRevision 驱动完整分类；进度只刷新继续观看；LocalCatalogIndex 的分组排序在 detached 任务内；去掉主线程 cards 排序 | iOS 编译；进度逻辑检查 |
| 8 内存缓存无淘汰 | 首页快照到期清理、数量上限、服务器移除清理；内存警告释放快照/解码缓存；轻量轮播位置独立保存 | iOS 编译；生命周期代码检查 |

## 保持的边界

- 底层内核、画面/音频交接操作仍由 PlaybackSession 驱动，状态事务由 Coordinator 管理。未在本次更换为共享解复用器。
- 原始技术信息、详情页完整演员/媒体流仍保留原模型转换；首页布局和快照直接消费独立 MediaCard；只在服务器操作和现有 TMDB 适配器边界转换，完整详情媒体流不丢失。
- LibraryStore 仍是页面兼容 façade；扫描对账与元数据匹配规则留在其中，目录遍历已移至 Coordinator 子任务，任务所有权与新增存储/同步/索引实现已分离，不通过一次性重写改变所有既有功能。
- SQLite 启动加载和旧 JSON 迁移仍为同步初始化。常规运行期间保存、进度写入、文件源导入的数据库写入已异步；启动全异步加载需要单独设计加载状态与错误恢复，不在此次审查的“进度保存”改动内。
- 已保存的同步队列不包含 Keychain 凭据；发送时读取对应 source 的当前凭据，始终遵守移动网络同步开关。
- 队列重试间隔 15 秒；无效账户需要用户编辑服务器恢复。Plex 继续使用现有观看与进度接口，不虚构不存在的收藏 API。

## 参考来源

借鉴设计，不复制上游代码或增加数据库依赖：

- [GRDB DatabaseWriter](https://github.com/groue/GRDB.swift/blob/master/GRDB/Core/DatabaseWriter.swift)：单所有者串行写入与异步提交边界。
- [SQLite 线程模型](https://www.sqlite.org/threadsafe.html)：保持 FULLMUTEX，额外用独立队列保护事务及内存索引。
- [Apple NSCache totalCostLimit](https://developer.apple.com/documentation/foundation/nscache/totalcostlimit)：以解码像素成本约束可丢弃缓存。

## 验证命令

- `python3 scripts/verify-architecture-optimization.py`：执行生产 Repository / Outbox / TransitionCoordinator，使用最小模型与延迟交付夹具，无模拟器、无真实网络。覆盖旧库迁移、缓存到期和容量淘汰。
- `python3 scripts/verify-progress-policy.py`：生产进度写入规则及续播时钟。
- `python3 scripts/verify-seek-preview.py`：生产预览调度、最新缓存优先及取消。
- `xcodebuild`：iOS Debug 编译。构建通过不等于实机播放、音频无缝或滚动帧率已验证。

补充检查：`verify-local-catalog.py`（展示模型/分类）、`verify-aggregate-library.py`（目录重复与循环去重、导入回滚）、`verify-network-usage.py`（移动网络策略）。
