# 海报管线审查（2026-11-06）

## 本次改动

- 首页大海报使用页面主题纯色占位，卡片原有占位不变；有图片时不再创建被图片完全覆盖的占位层。
- EmbyArtwork 每次 body 只解析一次显示图片；同一图片已完成柔化时不重复启动处理，安装柔化结果禁用隐式动画。
- 相同图片键及目标像素尺寸的并发解码共享 Task；完成后再次读取缓存，保持 UIImage 对象身份一致，避免重复取色与柔化。缓存清理有 generation 隔离，旧任务不会重填已清理缓存。
- 柔化结果按原图对象弱键缓存，不额外持有原始大图；复用 CIContext，图像处理仍在后台。内存警告时清理图像、柔化和 Core Image 缓存。
- 详情 SeriesArtwork（电影也复用）命中首选海报的解码缓存时直接显示，不再先将 preferredImage 清空、显示骨架、再从数据缓存重新走一遍加载。

这些是代码确认的重复工作及加载态变化优化，不代表 Hero 闪线根因已经查明。

## 参考

Apple CIContext 官方说明及性能指南：
https://developer.apple.com/documentation/coreimage/cicontext
https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_performance/ci_performance.html

官方建议复用上下文，CIContext 可跨线程渲染；本次未共享可变 CIFilter 实例。

开源示例 InstagramImageGallery：
https://github.com/maitrungduc1410/InstagramImageGallery
已实际读取 master/InstagramImageGallery/ContentView.swift。其网格每格在 NavigationLink/matchedTransitionSource 背后额外放一层 CachedAsyncImage，并在 path.count 减少时恢复该层可见性，用于覆盖快速交互返回导致源格暂时空白的现象。作者明确指出普通按钮返回时会提前显示该图，属于视觉取舍。

差异：Lucent 报告的是大海报底边闪线，普通库卡片 Hero 返回也触发；不是已经证实的源格整体空白。示例仅少量提交、无发布版本，README 的 License 仅写教育展示用途，未发现可据此直接复用的标准许可证。仅研究设计，未复制代码、未引入依赖；目前不把“双图回退层”直接移植为修复。

另阅作者经验：
https://blog.pengyuc.com/posts/indie/fixing-black-flashes-in-swiftui-zoom-transitions/
该文涉及透明整行源、玻璃卡片及全屏 cover 的底色；Lucent 首页源已配置不透明主题色且使用 push，不能等同于本问题。

## 验证边界

iOS 真机构建通过并安装；首页高度与请求范围检查通过。未自动启动应用或进行运行/播放验证，性能收益和闪线表现仍需真实运行证据。

## 切换 Tab 时顶部白色渐变

用户补充发生在从片源切回首页。首页原有 toolbarBackground(.hidden) 仅控制导航栏背景，未显式关闭 iOS26 的 Scroll Edge Effect；海报顶部自绘遮罩是黑色到透明，不是白色。按 Apple ScrollEdgeEffectStyle 的说明，系统默认在滚动视图与固定控件交界添加渐变模糊，这与白色顶层现象吻合，但未捕获实际画面不能写成已证实根因。

在实际首页 ScrollView 上使用 scrollEdgeEffectHidden(true, for: .top)，限定 iOS26+，不改变导航按钮前景与玻璃样式。用户仍需确认 Tab 切回时是否消失。该处理不等同于 Hero 返回底边闪线已修复。

https://developer.apple.com/documentation/swiftui/scrolledgeeffectstyle

## 首页清晰度策略更新

首页将实际海报宽高乘 Environment displayScale，像素对齐后传给解码器。扣除下拉拉伸产生的 pull，避免手势逐帧更换请求规格。读取 ImageIO 原图宽高及 EXIF 方向后，计算 aspect-fill 所需缩放，同时受原图尺寸、4096px 长边和像素预算约束，不做无意义的原图放大。

当前页预算8百万像素（RGBA像素数据约32MB，不含对齐、纹理和其他对象）；相邻预加载页2百万（约8MB）。共享解码缓存仍为64MiB成本目标；NSCache为可回收目标，不能将其称为整个进程的硬内存上限。视图持有图片和GPU纹理另占内存。

Emby不增加元数据请求：取图宽度按显示像素与常见16:9回退图估算并限制4096，拿到图片后再按真实比例解码。极宽原图受请求/像素预算限制时仍可能不足原生像素。聚合库本地TMDB路径的大海报不再固定w780，改用original数据、本地受预算下采样。普通内容卡片取图策略不变。

缓存与并发解码键包含目标像素、长边上限及像素预算，避免当前页误复用相邻页低清缓存；任务ID包含尺寸规格，支持尺寸改变后重新加载。

实际解码检查：scripts/verify-artwork-sizing.swift 与 ArtworkImageDecoder.swift 一同用 macOS SDK 编译运行，覆盖竖图、横图、小图、细长图及两种预算，检查不超过原图、不超过4096长边、像素预算和并发解码UIImage/NSImage身份复用。8项通过。不等于真机图像观感或峰值内存已验证。

## 详情页同步与加载指示

电影及剧集详情的大海报同步按 Environment displayScale 和实际显示区域传递 targetPixelSize，扣除下拉拉伸；最长边4096、预算8百万像素，普通剧集/关联影片卡片保持原规格。远程fallback也经数据缓存及受限解码，不再通过AsyncImage直接解码原始大图。首选海报、服务器fallback、本地/远程fallback各自维护加载结束状态，加载失败不持续转圈。

首页大海报与详情大海报无可显示图片且任务正在加载时使用原生ProgressView。已有缓存图片时不覆盖加载圈；图片尚未解析的详情阶段也显示圆圈。弹幕入口图标改为bubble.left.and.bubble.right（启用态fill），与字幕captions.bubble区分。

## 冷启动首页首屏与圆圈位置

冷启动内存HomeSnapshotCache为空。旧loadHome在发布任何首页内容前等待基础列表、所有媒体库featured列表、批量缺失元数据补全，造成首屏被非必要步骤阻塞。

改为：latest返回即可发布海报并允许页面显示；views/resume返回后补栏目入口和继续观看；featured任务各自完成后按原views顺序发布已完成栏目；enrichment在后续补充，保留当前hero选择与已加载海报/取色。仍保留请求批次隔离、取消检查、原排序与去重/批量请求策略，未增加每条目详情请求。未新增磁盘首页快照，冷启动仍需服务器响应；网络与TMDB图片请求可能仍决定真实耗时，不能凭构建认定性能提升幅度。

首页ProgressView本就在EmbyArtwork图片变换内部；详情页解析海报前的骨架ProgressView原本绕过固定偏移。现将解析前、解析后的两条详情图片分支包在同一Group后统一frame/scale/visualEffect，加载圈保持海报中央并随海报移动。

## Vidhub 录屏体验目标与首页跨启动恢复

已实际读取用户录屏（10.83秒）并提取画面：重进时先见到原海报及继续观看，随后推荐文本变化、新海报区域转为加载状态。视频只能支持这种呈现顺序，不能证明对方实现或精确冷启动耗时；系统应用启动快照也可能参与早期画面。

新增HomeStartupCache：缓存展示数据、栏目、首选海报/标题图地址及选中海报ID，按source UUID、服务器地址、服务器用户、内容语言计算SHA256上下文隔离，不存令牌。缓存目录每片源一个原子JSON、单文件最多4MiB、最多6个文件、内容最多7天；损坏、版本错误、上下文不符、过期自动回退网络路径。Codable覆盖MediaCard及其原始Jellyfin条目，保留CollectionType等来源语义。

冷启动首次内存缓存为空时异步读取展示快照，先发布页面，再执行现有网络刷新；推荐仍有效时保留上次顺序与当前选择，避免随机换页。海报地址后到或用户切换轮播时更新持久化快照。页面首次成功加载后才能建立缓存；缓存不是离线服务承诺，旧数据会被后台刷新替换，失败时保留旧内容并显示错误。当前不增加启动阶段的每条目详情请求。

scripts/verify-home-startup-cache.swift 使用实际缓存actor、隔离临时目录和最小DTO替身验证读写、上下文隔离、海报/选择更新、过期与损坏回退；iOS完整构建验证真实Codable数据模型可编译。未自动启动真机或测量启动时长，不能宣称已达到视频里的秒数。

## 继续观看首屏封面

首页与查看全部统一600px取图规格。启动展示快照/内存快照发布前，仅对首屏数量（最多6张）的继续观看封面读取已有磁盘数据并后台解码到内存，卡片初次body可同步命中已解码图片；没有缓存则跳过，不发请求、不访问钥匙串。兼容旧500px磁盘条目。磁盘读取由ArtworkDiskStore actor处理、解码由既有detached任务处理，主线程不执行文件IO或解码。

EmbyArtwork的钥匙串读取移入网络fetch闭包，磁盘缓存命中不再读取签名凭据。受源缓存有效期、系统缓存清理和内存回收约束，无法保证任何卡片在任何情况下都已有图。

标题层海报加载圈由top偏移-28pt改为-52pt（上移24pt），不改标题布局、按钮尺寸和滚动层级。

## 手动轮播后的清晰度升级闪变窗口

相邻页预加载预算2百万像素，变为当前页后升级8百万。此前EmbyArtwork.install仅替换image；body因softenedIdentity与新UIImage不一致立即移除柔化叠层，另一个task生成新柔化图后重新加入。代码存在可确定的两阶段视觉状态，不等于已经捕获用户所说闪烁的全部来源。

将install改为异步：后台准备对应柔化图后，再在同一禁用隐式动画的transaction中替换image、imageIdentity、softenedImage、softenedIdentity。等待期间保留旧完整画面；取消时不安装。原有缓存预显示的柔化任务保留，同一图片已准备时直接跳过。未更改轮播动画和主题色切换。

iOS构建通过并安装，未进行运行验证；不能据此称Hero返回底边闪线已修复。

## 加载圈中点定位与播放器边距

首页、电影/剧集标题层的加载圈改为LucentPosterLoadingIndicator：圆圈中心Y=(当前窗口safeAreaInsets.top + 标题区域global minY)/2。由挂载视图所属window读取安全区，不遍历全局window；通过原生visualEffect跟踪标题位置，不逐帧写入页面状态。尚未取得窗口安全区时不显示圈，避免先用0再跳位。标题内容不增加高度、不移动按钮。

播放器header/footer由固定12pt额外水平padding改为SwiftUI系统默认水平padding，继续保留横屏安全区。未声称与UINavigationBar在所有设备上像素级相等，尚需实际视觉确认。

加载圈定位补充：用户明确只需要初始中点。移除逐帧visualEffect中点计算；组件首次挂载记录标题global顶部，取得所属window安全区后仅计算一次相对标题的offset。之后保持offset随标题内容正常滚动，不再追踪屏幕中点。

## 首页栏目与封面两层懒加载

不再在loadHome内为每个媒体库创建featured任务组。基础首页只请求views/latest/resume及其缺失资料批次。按views原顺序保留固定高度栏目占位；由LazyVStack实际挂载/预取的栏目.task按需请求数据，当前栏目完成后只额外预取下一栏。原生懒栈允许系统自己的近屏预取窗口，不宣称只在精确可见时触发。

栏目加载去重、成功空结果与未加载分别记录；加载成功后保留数据，滚回不清空。失败显示独立错误及重试，不影响其他栏目。刷新创建新epoch，取消旧结果；source marker防止切换片源后拿旧媒体库ID请求新服务器。先发布featured列表再补元数据，补取失败保留列表；继续按原DateLastContentAdded等规则排序，无每条目完整详情请求。

栏目完成后更新内存与跨启动展示缓存。数据同步局部失败不把成功列表改成失败状态。栏目最多2个并发；同一图片共享请求，磁盘命中不进入下载队列；网络图片最多4个并发；实际下采样最多2个并发。队列支持取消等待者，不以sleep轮询许可。图片仍由LazyHStack卡片生命周期进行近屏加载，不新加逐帧滚动状态或强制清空离屏已加载图。

验证：实际ArtworkWorkGate通过24任务并发上限及取消等待者释放检查；实际解码器的8组图片尺寸/预算/身份检查；跨启动缓存恢复/隔离/过期检查；首页无逐条详情请求的范围检查。iOS真机构建并安装；未自动运行或测量滚动FPS，不将其写为卡顿已验证解决。
