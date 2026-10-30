# AetherEngine 集成

Lucent 通过 Swift Package 引入 [AetherEngine](https://github.com/superuser404notfound/AetherEngine)，固定修订版 `61250c9f9fe1624d4ac4b2d069fb0bdaca2cc213`。Lucent 未复制或修改其源码；Xcode 在构建时下载原项目及其传递依赖。

AetherEngine 按 LGPL-3.0 及其项目声明的 App Store 例外发布。可选的 DualLayerDolbyVision、TrueHDObjectAudio、DTSXObjectAudio 组件有各自的传递依赖及可能涉及专利授权。发行包发布前须逐项核对上游许可证、署名、可替换性和适用专利。具体技术限制以对应固定版本的源码和文档为准。

Lucent 使用 AetherEngine 的 P7→P8.1 转换、可选 FEL 合成、APAC 对象音频和位图字幕 API。构建成功只能证明依赖接入及类型检查，不证明设备已经输出杜比视界或 Atmos。
