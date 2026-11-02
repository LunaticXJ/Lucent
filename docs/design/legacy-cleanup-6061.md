# 遗留代码清理（6061）

以调用关系和编译条件为依据，不以名称包含 legacy 或源码只出现一次就自动删除。

## 已清理

- 移除四个仅委托公共玻璃组件的页面包装：MobileDockGlass、EpisodeGlassShape、LibraryGlass、PlayerGlassSurface。调用点改为 LucentGlass 或公共 lucentVideoGlass，保留原 Circle / Capsule / RoundedRectangle、圆角和视频覆盖层角色。
- 删除电影详情未使用的 audio/subtitles、剧集详情未使用的 activeAudio/activeSubtitles。媒体信息仍从 streams/activeStreams 提供。
- 删除已无入口的全局文件源重命名弹窗、renamingFileID/fileNameDraft、beginFileRename；保留 AggregateLibraryOverview 当前有效的重命名流程。
- 删除未调用的 fileSourceStatus、appearanceTitle，以及旧同步互斥标志 flushingDeferredServerStates。
- 停止写入旧的“仅受限网络才延迟提交”队列，统一由 ServerStateOutbox 接收。旧 UserDefaults 待同步记录保留一次性迁移，全部持久化成功后才删除旧恢复键；迁移失败不清空。
- 删除交接状态枚举中没有实际转换路径的 seeking 项，避免误示该协调器管理了完整 seek 生命周期。
- 清理编译器确认的无用局部变量、不可达 catch，以及隐式强引用/内部弱引用的含糊捕获声明；保持原有生命周期语义。
- AVKit 就绪观察改为读取 KVO 通知值，再向主线程发送回调，移除 Sendable 回调直接读取界面属性的线程隔离警告。
- 使用公共 pageInset 常量替换同值页面间距；同步更新 UI 组件文档。

- 删除全模块无调用的旧 DLNA 批量导入、文件源离线摘要、媒体直接重命名方法，以及 assetHasDolbyVision、currentUserID、firstPlayableURL 三个查询包装；保留当前存储扫描、详情编辑、格式检测和播放列表解析实现。

## 明确保留

- UIApplicationDelegateAdaptor 的 orientationDelegate 由框架驱动，虽然没有显式读取，但不能作为无用属性删除。
- macOS / tvOS 仍在使用的旧表单、服务器浏览和平台分支。
- 旧 JSON / 数据库迁移、播放状态恢复，以及仍被使用的媒体模型兼容边界。
- 正在使用的图片缓存、播放诊断与失败回滚路径。

## 验证范围

- 重新扫描私有声明的本文件引用，再人工核对框架入口和条件编译分支。
- 生产 Repository/Outbox/交接状态测试与移动网络策略检查。
- iOS Debug 编译，构建成功后安装；默认不启动应用或进行模拟器运行验证。
