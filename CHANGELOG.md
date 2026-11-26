# Changelog

All notable changes to WordWand will be documented in this file.

## [0.1.1] - 2026-11-26

### Fixed
- **主面板鼠标点击选中失效**：在点击模式行时先更新选中索引 `sel` 并重绘再执行，避免非激活浮层下未触发 `mouseenter` 时始终默认执行第一项。
- **主面板与模型面板鼠标悬停高亮**：通过 `hs.eventtap` 监听 `mouseMoved` 同步指针所在行的高亮状态（模型面板带 20ms 节流并支持列表滚动后的坐标命中），并移除主面板显示后 50ms 延迟重置 `setSel(0)` 的竞争。
- **卡片点击边界上下写反**：修正 `POP`、`MPICK`、`SET` 三个面板在 Hammerspoon 顶部向下坐标系下的 `pad_top` / `pad_bottom` 判定，避免点击第一行上边缘附近误关闭面板，并抽取共享函数 `panelFrame` 与 `isInsideCard`。

### Changed
- 在 `init.lua` 与 `VERSION` 中加入版本号 `0.1.1`，并在 Hammerspoon 启动日志中输出当前版本。

## [0.1.0] - 2026-11-10

### Added
- 基于 Hammerspoon 的 macOS 划词改写核心流程（`⌃⌥R` 弹出模式面板、`⌃⌥X` 暂停/启用、支持任意 OpenAI 兼容接口）。
- macOS 27 (Golden Gate) 风格自绘 Liquid Glass 浮层：主模式面板、可搜索模型选择面板与单页集成设置面板（支持快捷键录制与连接/网络诊断）。
- 一键部署脚本 `install.sh` 与远端单命令安装脚本 `setup.sh`（默认对接 DeepSeek 接口，支持环境变量 / 文件 / 系统钥匙串三源 Key 读取）。
