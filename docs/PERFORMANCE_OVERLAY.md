# 紧凑性能叠加信息

游戏中的性能信息统一显示为一行，例如 `FPS 60.0 · 16.7ms · RAM 2.3GB`。

- 默认字号 10 点，支持调整 8～24 点；使用等宽数字，窄屏最多缩小到 8 点，保持一行。
- 支持文字颜色、显示背景、背景颜色和背景透明度；背景为两端全圆角的胶囊形。
- 内边距为左右 6 点、上下 2 点，屏幕边距为 4 点，不再保留最小宽度或多行面板。
- FPS、帧时、FIFO 保留一位小数；RAM 启用时同时显示实际借用的扩展内存。
- 保留“全局默认”和“当前游戏”：总开关、帧时、内存、FIFO、电量、位置和外观都支持游戏覆盖；未覆盖项动态读取全局值。两处设置页共用同一个组件，只浏览预览不创建游戏覆盖。
- “性能叠加信息”内提供实时外观预览，使用明确标注的示例数据；预览与游戏共用 `PerformanceOverlayLine`，显示项目开关也同步影响预览。
- 横竖屏共用样式，保留位置选择和竖屏移到游戏画面下方的选项；总开关同时控制两处入口。
- 电量未知时隐藏该项，电量通知订阅随视图退出取消。

新增外观键为 `PerformanceOverlay.FontSize`、`PerformanceOverlay.TextColorRGB`、`PerformanceOverlay.BackgroundColorRGB`、`PerformanceOverlay.BackgroundEnabled`、`PerformanceOverlay.BackgroundOpacity`。使用 `NativeSettingsManager` 的现有作用域规则；颜色是 24 位 sRGB 整数，透明度界面显示为百分比，存储为不透明度。转换失败显示错误并保留原颜色。

本次为显示布局、外观设置及关联开关修正，没有更改性能采样、游戏渲染或帧率限制。Windows 下检查本地化与差异；iOS 编译和实际显示效果需 Codemagic 构建后在真机验收。检查字号和颜色即时预览、透明度 0%/100%、关闭背景、重启保存、游戏覆盖和全局继承、横竖屏、全部指标开启、总开关关闭，以及竖屏下方显示和位置切换。

2026-11-10 已通过 `python scripts/check_localization.py`、`git diff --check`，并完成设置作用域和调用接口的交叉审查；本机没有 Apple SDK，未执行 Swift 编译和真机 UI 验证。
