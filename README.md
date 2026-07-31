# 无线麦

[English](README.en.md)

![无线麦——为 Vibe Coding 而生的语音遥控器](Screenshots/Remote-Mic-Introduce-1.png)

无线麦是一款 macOS 应用，可以把小米蓝牙遥控器 2 Pro（RC003）变成 Mac 的无线语音遥控器。它同时提供常规 Dock 入口和常驻菜单栏入口。

按住遥控器的语音键即可说话；遥控器上的方向、确定、返回、主页、菜单、TV 和音量键也可以用来控制 Mac，或设置为打开常用应用。

![连接与语音设置页](Screenshots/connection-and-voice.png)

## 与上游原仓库的主要区别

本项目 fork 自 [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge)（原仓库要求 macOS 26+，面向海外市场），针对**本机软硬件环境**做了深度适配与改造。以下是与原版的核心差异：

### 🍎 本机运行环境

| 项目 | 本机环境 |
|------|----------|
| 机型 | Mac mini（Mac14,3）|
| 芯片 | Apple M2（8 核，4 性能 + 4 能效）|
| 内存 | 16 GB |
| 系统版本 | macOS 13.2.1（Ventura）|

原仓库要求 macOS 26（Tahoe）及以上，本 fork 向下兼容适配至 macOS 13，大幅扩展了可用机型范围。

### 🇨🇳 豆包输入法深度适配

原版仅支持 Apple 自带听写和少数海外输入法。本 fork 针对**豆包输入法**做了专项兼容：

- **HID 按键映射重构**：将遥控器语音键的 HID usage 映射从 `Fn/Globe（0xff, 0x03）` 改为**右 Control（0x0007, 0xe4）**，与豆包输入法的语音触发键位对齐，不再依赖软件层 `postRightControlTap()` 模拟
- **MiRemoteV 2ch 专属虚拟音频设备**：独立派生自 BlackHole 源码构建的回环音频驱动，设备命名和 USB transport 方案针对豆包做了兼容处理，可与 BlackHole 2ch 并存且不互相覆盖
- **详尽的中文兼容文档**：提供[豆包输入法兼容说明](Resources/豆包输入法兼容说明.md)，覆盖安装、验证、卸载全流程

### 🎙️ Vibe Coding 专项优化

针对 AI 编程工具（Claude、Codex、cmux 等）做了自动聚焦输入框的适配：

- 打开 Claude / cmux 后自动聚焦其输入区域
- 解决了 cmux 的 `GhosttyNSView` 终端输入框聚焦问题
- 针对 Codex（ProseMirror 编辑器，`role="textbox"`、`aria-multiline`）的 Accessibility 识别做了专项调试记录（见 `DEBUG.md`）

### 🌐 完整中文化

- 全量简体中文 UI（菜单、设置、状态、内置帮助）
- 应用语言支持"跟随系统 / 简体中文 / English"切换
- 中文文档覆盖安装、排障、首次使用等全场景

### 🔧 其他关键改动

- **配置导入导出**：支持版本化 JSON 格式迁移全部个性化设置
- **本地使用统计**：不上传、不追踪，仅本机记录
- **Pre-release 发布机制**：避免未实测功能被自动更新检测到
- **Apple 遥控器（Siri Remote）兼容性调研**：已完成 SiriRemoteForge、Wand 等候选方案的可行性评估，按键 → 触摸/滚动 → 麦克风高级组件的分阶段集成路线已明确
- **构建与签名修复**：解决 Sparkle 组件签名、公证产物权限、安装器开发者工具依赖等问题

---

## 使用要求

- Apple Silicon Mac（已验证 M2）；
- macOS 13 或更高版本（原版要求 macOS 26+）；
- 小米蓝牙遥控器 2 Pro / RC003；
- 使用语音输入时，需要安装随安装包提供的 `MiRemoteV 2ch` 兼容麦克风，或在 Mac 上已有 BlackHole 2ch 等回环音频设备。

## 下载与安装

发布的安装包会在 [GitHub Releases](https://github.com/gpboyer2/remote-mic-app/releases/latest) 提供，文件名为 `Remote-Mic-<版本>.dmg`。

打开 DMG 后有两种安装方式：

1. 推荐：双击 Install Remote Mic.pkg。它会同时安装 Remote Mic 和 `MiRemoteV 2ch` 兼容麦克风，适合豆包输入法及其他语音输入应用。
2. 仅安装应用：把 Remote Mic.app 拖到 Applications。如果使用这种方式，请确保 Mac 上已经有可用的回环音频设备。

自 v1.3.0 起，正式发布包使用 Apple Developer ID 签名并已完成 Apple 公证。请只从本项目 GitHub Releases 下载，并使用同一 Release 中的 `.sha256` 文件核对 DMG。

## 首次使用

1. 在"系统设置 → 蓝牙"中打开蓝牙。
2. 同时长按遥控器的"主页"和"菜单"键，使遥控器进入配对状态。
3. 在 Mac 上连接名称为 `MI RC`、`Xiaomi Bluetooth Remote 2 Pro` 或"小米蓝牙语音遥控器"的设备。
4. 启动 Remote Mic，按提示允许蓝牙权限。
5. 如果需要自定义普通按键，再允许"输入监控"和"辅助功能"。授权后请完全退出并重新打开应用。

应用启动后会显示 Dock 图标并常驻菜单栏：

- 单击 Dock 图标：打开设置面板；
- 左键单击图标：打开设置面板；
- 右键单击图标：显示连接状态、重新连接、日志、关于、版本号、检查更新、GitHub 和退出菜单。

设置面板左侧栏底部的"关于"页面提供版本、检查更新、GitHub、语言、退出和 Dock 显示选项。关闭"在 Dock 中显示应用图标"后，应用仍会保留菜单栏入口，可随时重新打开设置。

"应用语言"可选择"跟随系统""简体中文"或"English"。设置窗口、状态、菜单和内置帮助会立即刷新，无需重启应用；系统权限提示和第三方界面仍会在下次打开时按 macOS 自身的语言显示。

应用每天自动检查一次更新，发现新版本后由用户确认是否安装；不会静默下载或自动安装。"关于"页面和右键菜单中的"检查更新…"均可随时手动检查。Sparkle 仅更新应用本体，兼容麦克风驱动仍由 DMG 中的安装包管理。

## 使用语音输入

1. 打开"连接与语音"页面。
2. 点击"刷新音频设备"。
3. 选择 `MiRemoteV 2ch`，或选择你已经安装的其他回环音频设备。
4. 在需要听写或语音输入的应用中选择同一个设备作为麦克风。
5. 单击目标输入框，按住遥控器语音键说话，松开后结束。

如果想先确认音频链路是否正常，可以点击"发送 1 秒测试音"，或在 QuickTime Player 的"新建音频录制"中观察输入电平。

豆包输入法找不到普通虚拟麦克风时，请使用 DMG 中的 Install Remote Mic.pkg，然后在 Remote Mic 中选择 `MiRemoteV 2ch`。详细步骤见[豆包输入法兼容说明](Resources/豆包输入法兼容说明.md)。

## 自定义遥控器按键

![按键映射设置页](Screenshots/key-mapping.png)

打开"按键映射"页面并启用自定义映射后，可以修改方向、确定、返回、主页、菜单、TV、电源和音量键的功能。

每个普通按键都可以设置单击动作，并可额外设置双击和长按动作。动作支持键盘操作、系统音量、播放控制、打开当前 Mac 已安装的常用应用，以及录入任意自定义键盘快捷键。

- 没有设置双击或长按时，单击保持原有的即时响应和按住重复；
- 设置双击后，应用会等待约 0.3 秒区分单击和双击；
- 设置长按后，按住约 0.55 秒执行长按动作，并抑制单击；
- 设置了双击或长按的实体键不会再按住重复，避免多个动作同时触发。

语音键始终用于语音输入，不参与普通按键映射。

## 权限与隐私

- 蓝牙：连接遥控器并接收语音；
- 输入监控：识别遥控器普通按键；
- 辅助功能：把按键动作发送给当前应用。

无线麦不会上传或保存语音，不会自动修改系统默认输入、输出设备，也不会在日志中记录语音内容、蓝牙地址或外设标识。

## 卸载

1. 退出无线麦。
2. 双击 DMG 中的 Uninstall Remote Mic.pkg，移除 `MiRemoteV 2ch` 兼容麦克风。
3. 删除"应用程序"中的 Remote Mic.app。

卸载兼容麦克风不会修改或删除已有的 BlackHole。

## 遇到问题

请先查看[排障指南](TROUBLESHOOTING.md)。首次安装的完整步骤见[首次安装说明](Resources/首次安装说明.md)。

开发、构建、协议、测试和发布信息见[技术文档](TECHNICAL.md)。

后续开发计划见 [TODO](TODO.md)。

## 许可与来源

本项目软件代码采用 `GPL-3.0-only` 许可。App Logo 是需要单独授权的专有品牌资产，详情见 [LOGO-LICENSE.md](LOGO-LICENSE.md)。完整版权和第三方信息见 [COPYRIGHT.md](COPYRIGHT.md) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

项目最初 fork 自 [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge)（原仓库面向 macOS 26+），后由本仓库独立维护，针对 macOS 13 和豆包输入法做了深度适配。

`MiRemoteV 2ch` 的设备命名及让豆包枚举设备的 USB transport 兼容方案参考自 [VincentKingHsu/MiRemoteVoice](https://github.com/VincentKingHsu/MiRemoteVoice) `v1.0.0-beta.1`（MIT）；该项目的兼容驱动同样基于 BlackHole。本项目不复用 MiRemoteVoice 的二进制替换脚本，而是从 [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole) `v0.7.1`（固定提交 `e2b22aaaba4e507a097131704bf96dabc004d9cf`）源码独立派生构建 `MiRemoteV2ch.driver`，适用 `GPL-3.0`。它使用独立标识，可与已安装的 BlackHole 并存，不覆盖或删除其文件。
