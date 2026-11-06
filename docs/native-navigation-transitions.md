# Lucent 原生导航与控件过渡研究

## 已采用：继续观看进入列表

首页继续观看标题作为 matchedTransitionSource，列表使用 navigationTransition(.zoom)。聚合媒体库与 Emby 都使用同一套 HomeCollectionZoom，进入、返回和交互返回由系统协调。卡片尺寸与按钮间距不变，源视图保留在原导航栈中，不以播放进度截图作为列表转场源。iOS 18 起使用，旧平台保持原导航。

点击继续观看海报进入详情页也接入 Zoom，源限定为海报图片，不包含进度条与时间覆盖层。

## 用户描述的按钮连续感

可能是几种原生机制的组合，仅凭描述无法认定其他 App 的具体实现：

1. 原生 NavigationStack / UINavigationBar 的导航项转场。导航栏保持系统管理，左右 ToolbarItem 随页面切换，系统负责位置、材质、返回交互。优先采用这一层。
2. 页面 Zoom：matchedTransitionSource + navigationTransition(.zoom)。可从工具栏按钮打开页面，但这是按钮到页面的转场，不等于两个页面的任意按钮共享形态。
3. 玻璃形态过渡：同一 GlassEffectContainer 中，用命名空间、glassEffectID 和 glassEffectTransition(.matchedGeometry)关联条件切换的玻璃形状。适用于同一个工具栏中圆形按钮变成展开胶囊。不能保证独立导航目的地中的两个按钮仅凭相同 ID 就自动变形。
4. matchedGeometryEffect 适合同一视图层级内的元素几何匹配，不能作为跨 NavigationStack 或 sheet 的通用替代方案。

## Lucent 的差异与建议

目前 LucentCollectionChrome 用 VStack 自绘标题与左右按钮，详情页又单独 overlay topControls，多个页面隐藏系统 navigationBar。这些按钮分别属于不同页面的生命周期，导航时容易表现为各自消失、出现。

建议先选一个列表→详情入口，把标题、返回和右侧操作移入系统 toolbar，保留系统导航栏管理；明确保留原来的按钮尺寸与内容布局，检查系统内边距。自定义返回行为需用路径 pop 协调，不能用两个同时存活的返回按钮。先确认正常 push/pop、交互取消、Zoom 返回、底部 Tab 恢复、浅深主题和辅助功能，再推广。

只有原生 toolbar 无法满足明确的形态转换时，才考虑在导航容器上方保留一个共享控件区域，通过同一 GlassEffectContainer 切换状态；这涉及遮挡、安全区和交互返回的生命周期，不适合直接作为全局补丁。

本次只完成继续观看列表及海报进入详情的 Zoom 接入；跨页面共享按钮暂未实现，也未进行真机动画运行验证。不新增第三方依赖、不复制外部代码。

## Apple 参考

- https://developer.apple.com/documentation/swiftui/zoomnavigationtransition
- https://developer.apple.com/documentation/swiftui/toolbarcontent/matchedtransitionsource(id:in:)
- https://developer.apple.com/documentation/swiftui/glasseffecttransition
- https://developer.apple.com/documentation/swiftui/glasseffecttransition/matchedgeometry
- https://developer.apple.com/videos/play/wwdc2025/323/

## 2026-11-06 原生导航迁移

首页片源选择迁入 leading ToolbarItem；媒体库、分类、继续观看列表采用原生 inline navigationTitle 与 trailing ToolbarItem；详情页更多菜单、剧集查看全部的编辑操作迁入原生 toolbar。iOS 返回使用导航栈的系统返回按钮，保留原 navigationDestination 绑定、Zoom 源与二级页 Tab 隐藏逻辑。父页操作在子路由存在时隐藏，避免工具栏重复。共享 LucentCollectionChrome 通过显式 nativeNavigation 开关启用，未迁移的存储等页面不会被这次全局替换。

未新增跨页 matchedGeometry 的自定义共享按钮。原生工具栏的连续转场由系统协调，不能将构建成功描述为运行效果或全部导航功能已验证；尚需真机检查正常返回、取消返回手势、嵌套分类、菜单、选集编辑及 Home Tab 恢复。

## 2026-11-06 五项后续优化

1. lucentSecondaryPage 不再为所有页面安装返回手势代理；仅自绘标题栏兼容分支保留 lucentLegacyEdgeBack。
2. 存储管理与目录浏览启用原生标题/toolbar。iOS 目录使用导航目的地递归进入下一层，各层共享一个目录选择模型；面包屑通过祖先导航绑定返回指定层级，保留多目录选择与导入审核。
3. 共用玻璃按钮在系统支持时真正使用 buttonStyle(.glass)，无固定前景或强制主题；去除胶囊标签的重复 padding，圆按钮保留 44 点容器，播放按钮保留 330 点宽度上限和 54 点最小高度，不封死动态字体高度。旧系统使用材质回退。
4. 独立文件夹和已扫描文件源浏览入口从 sheet 迁入片源页导航栈；创建、授权、编辑及导入审核仍保留模态表单。
5. 搜索使用原生 navigationTitle、navigationBar 与既有 searchable，搜索范围、查询、推荐、结果及详情路由保留。

构建和离线逻辑检查不代替真机导航/视觉测试；需要手动验证目录多选跨层保留、面包屑返回、返回手势取消、搜索详情返回、按钮实际尺寸以及 Tab 恢复。

后续清理：所有集合页面已统一为原生导航，已删除自绘标题栏兼容分支、nativeNavigation 切换参数和返回手势代理，不再保留未使用的旧导航方案。
