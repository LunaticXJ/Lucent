# 6038：弹窗打开后自动返回

## 代码证据

`LibraryView.mobileSettingsShell` 与 `navigationBody` 同时对 `showWebDAV`、`showSMB`、`showEmby` 等共用状态注册 `.sheet`。原生 TabView 会保留不在前台的页面，因此两个不同 presenter 可能同时响应一次状态变化；旧 presenter 的撤销可把绑定写回 false。

## 修改

- iOS 使用 `mobilePresentedShell` 作为唯一展示宿主，放在所有 Tab 的外层。
- 移除设置子树的弹窗注册，导航子树的原注册仅在 macOS/tvOS 生效。
- 添加选择、存储管理、服务添加/编辑、资料、认证弹窗均由同一稳定层展示。
- 保留 `onDismiss: performSourceAddition` 与 `finishStorageManagement` 的串行跳转，不使用固定延迟猜测关闭动画时间。
- 文件选择器已按平台隔离：iOS 保留 mobileShell 的唯一注册，macOS 保留原导航注册。

## 验证范围

`scripts/verify-modal-ownership.py` 处理 iOS 编译分支，验证 14 个共用布尔绑定均仅注册一次且位于稳定宿主，同时检查文件选择器及 onDismiss 链路。iOS 构建通过。未运行界面测试；需手动反复打开/取消 WebDAV、SMB、网盘和服务器表单，并检查“存储→添加/编辑”的往返。

官方 API 参考：https://developer.apple.com/documentation/swiftui/view/sheet(ispresented:ondismiss:content:)
