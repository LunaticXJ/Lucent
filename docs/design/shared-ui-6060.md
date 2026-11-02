# 公共 UI / UX 组件迁移（6060）

## 六项清单

| 分类 | 公共实现 | 已迁移的实际调用 |
| --- | --- | --- |
| 主题与尺寸规范 | LucentUI：页面/分组底色、灰色选中、绿色开关、黄色评分星、44pt 工具按钮、52pt 表单 | 首页、服务器/存储表单、设置、海报和详情 |
| 玻璃与按钮 | LucentGlass：普通与视频覆盖层两类角色；LucentToolbarButton、LucentPlayButton | Dock/剧集/媒体库/播放器旧 modifier 委托公共实现；电影/剧集共用播放按钮和返回按钮 |
| 海报与角标 | LucentArtworkPlaceholder、LucentRemoteArtwork、LucentRatingBadge、LucentCountBadge、LucentPosterCaption、LucentSkeleton | 首页、搜索、聚合媒体库、Emby 浏览、Jellyfin/Plex 海报、剧集全部列表、播放列表占位、详情骨架 |
| 表单与设置 | LucentFormField、LucentPasswordInput、LucentSettingsRow、LucentSettingsPageStyle | SMB/WebDAV 新增编辑、六种媒体服务器表单、设置主列表、手势/进度/跳过/缓存/本地化子页 |
| 页面反馈 | LucentLoadingView、LucentStateView | 播放加载/拖动加载、目录读取、服务器连接与列表、目录重试、媒体库空状态、影片已删除 |
| 导航与弹层 | LucentEditorToolbar、LucentSheetToolbar、LucentSynopsisSheet、LucentSheetStyle | 存储与服务器编辑工具栏、电影与剧集简介（关闭/复制/可选文字/原生 detents） |

## 复用边界

- 后续清理已删除 MobileDockGlass / EpisodeGlassShape / LibraryGlass / PlayerGlassSurface 薄封装；页面直接使用 LucentGlass，视频控件通过共享 lucentVideoGlass 方法设置角色与形状。材质参数、系统版本分支和“降低透明度”仍只有一份实现。
- 视频覆盖层保留原来的深色染色；普通页面跟随主题。不会将所有文字、背景和材质强制设为同一个颜色。
- 海报加载策略按来源保留：Emby 和详情的多源回退、海报拉伸与底部模糊不被通用图片控件替代。搜索、本地媒体库和服务器海报共用加载视图，复用已有磁盘缓存、后台缩略图解码与请求取消保护。
- 控件以系统 Form、Picker、Toggle、Toolbar 和 sheet 为基础；不创建自定义分段切换动画。
- 底部原生 TabView、search role、tabBarMinimizeBehavior 及原有切换实现未重写。
- 绿色用于开关和连接状态；选择文本为灰色；海报上的文字/角标维持白色对比，元数据评分星统一黄色。
- 已有工作流不适合统一成弹窗：详情/媒体浏览仍为页面跳转，剧集“查看全部”保留全屏编辑，播放中的轨道与设置抽屉保留覆盖层。

## 参考及验证

使用现有 SwiftUI 原生控件，不引入额外 UI 库。材质角色和形状设计核对 [Apple Liquid Glass 文档](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)；可交互圆形工具按钮通过官方 interactive 修饰支持触控反馈。较旧系统保留 regularMaterial 回退，“降低透明度”使用实色容器。

- iOS Debug 编译检查公共组件与所有迁移页面。
- 静态核对：glassEffect/regularMaterial 仅存在于公共材质实现；设置样式不再重复定义；旧服务器字段组件已移除。
- 默认不启动模拟器，不截图、不操作界面。构建通过不代表视觉质量已完成实机确认。
- 手动重点：深浅主题占位、超大字体、降低透明度、表单键盘与密码显隐、简介关闭/复制、播放和跳转加载圈，以及原生 TAB 切换/搜索收缩。
