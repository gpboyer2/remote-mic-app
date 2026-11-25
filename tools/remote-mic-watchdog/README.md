# remote-mic-watchdog

Remote Mic 的运维小工具集：检测虚拟声卡是否被静音、环回是否还通、豆包流式 ASR 通道是否还在，并在出问题时分级恢复。

## 为什么单独放在这里

应用本身的职责是「蓝牙收语音、写进虚拟声卡」。但实际故障常常出在它之外：

- 虚拟声卡被静音后，写进去的语音读不出来，豆包弹出浮窗却一个字不出；
- macOS 会把设备静音状态持久化，**重启正好把静音装回去**；
- 驱动宿主跑久了会泄漏 Mach port，被内核杀掉后环回永久失效。

这些都得在应用之外兜，且必须能开机自愈，不能每次靠人现场救火。

## 目录

```
CoreAudioDevice.swift   公共模块：设备枚举、UID 查找、静音读写
probe.swift             只做一件事：往虚拟声卡写一段 1kHz
unmute.swift            只做一件事：查看并解除静音
level.swift             只做一件事：从虚拟声卡录音并报峰值
lib-lock.sh             公共 shell 库：单实例锁
build.sh                唯一编译入口，产物落 bin/
mute-guard.sh           每 60 秒巡检，虚拟声卡被静音就解除
watchdog.sh             每 10 分钟探测环回，失败则分级恢复
install.sh              用户级安装（不需要 root）
install-helper.sh       root 级 helper（可选，供 watchdog 做 L2/L3 恢复）
launchd/                LaunchAgent 模板，__BASE__ 由 install.sh 替换
```

新增工具时复用 `CoreAudioDevice.swift`，不要在各自的 `main` 里再复制一份设备查找——
`probe.swift` 和 `unmute.swift` 之前就是这么分叉的。

## 安装

```bash
bash tools/remote-mic-watchdog/install.sh
```

会编译工具、部署到 `~/Library/Application Support/RemoteMicWatchdog`，
并加载两个 LaunchAgent（`com.peng.miremote-mute-guard`、`com.peng.miremote-watchdog`）。

需要 `watchdog` 真的能重启驱动宿主/coreaudiod 时，再跑一次：

```bash
sudo bash tools/remote-mic-watchdog/install-helper.sh
```

## 环回判定的两个坑（都是实测踩过的）

**一、不能用 ffmpeg 测。** 它的 avfoundation 输入对这几个虚拟设备一律报 `-91dB`，
环回健康时也是假阴性。按它恢复，等于在好设备上杀驱动。`level.swift` 改走 AVAudioEngine，
与豆包读设备是同一条路径：正常 `-17.3dB`，真被静音 `-180dB`，两者可区分。

**二、单实例锁。** launchd 的 `RunAtLoad` 会与手动执行撞车，两个实例同时开 AVAudioEngine
会互相抢设备，录音方拿不到数据——又一次制造假阴性。所以有 `lib-lock.sh`，
拿不到锁就等，等不到就跳过本轮并记 `SKIP`。

`-170dB` 以下判为 **unknown**，只记日志、不触发恢复：那是「没有样本」，
不是「环回坏了」。宁可不动，也不要在测不准的时候做不可逆动作。

## 为什么后台项里显示中文名

macOS 的「登录项 — 允许在后台」显示的是**可执行文件名**，不是 plist 的 Label。
直接跑 `/bin/bash` 就会显示成 `bash`，用户看到一堆 bash/sh/ssh 会当成病毒关掉。

所以安装时会在运行时目录生成两个中文名外壳（`虚拟声卡静音守卫`、`无线麦环回检测`），
plist 的 `ProgramArguments` 指向外壳，外壳再 `exec` 真正的脚本。
重装不会退回 bash 名——外壳与 plist 都由 `install.sh` 生成。

注意：改名只能解决「看不懂」，消不掉「身份不明的开发者」提示；那需要 Developer ID 签名。

## 排查「豆包弹出浮窗但不出字」

顺序固定，不要反过来：

1. `bin/miremote-unmute MiRemoteV2ch_UID` —— 看 `before=1`，是就说明被静音了；
2. `mute-guard.log` —— 看是不是反复被静音（累计 3 次会写 `REPEAT`）；
3. 再往下才是环回：`bin/miremote-level` 录音 + `bin/miremote-probe` 写 1kHz；
4. 最后才是驱动 ABI、ffmpeg、AUHAL 这些底层。

2026-11-19 那次绕了两个小时，就是跳过了第 1 步。

## 豆包流式通道自愈（2026-11-25）

现象：豆包进「识别中」却一个字不出。遥控器、BLE、虚拟声卡、环回探针全绿，
豆包也确实在 MiRemoteV 上开了麦——问题不在前三层。

根因：豆包连跑约两天后，流式 ASR 的 `audio-ime-ws` WebSocket 掉了，只剩批量通道；
重启豆包重建这条 ws 即恢复。判据在 Clash 连接表：正常时能看到
`frontier5-audio-ime-ws-lf.doubao.com`，故障时只剩 `frontier-ime` 与 `ark`。

`watchdog.sh` 每轮先查一次：

- Clash 不在或查不到 → 记 `DOUBAO skipped reason=clash_unavailable`，不动；
- 豆包启动不足 1 小时 → 记 `startup_grace`，不动（冷启动期 ws 本来就还没建）；
- `audio-ime-ws` 在 → 记 `DOUBAO stream=ok`；
- 连续两轮缺失 → 若 HID 空闲 ≥ 60 秒才 `kill` 豆包（launchd 自动拉起），
  否则记 `DOUBAO RECOVER deferred reason=user_active`，下一轮再试。

Clash 的 unix socket 默认 `/tmp/verge/verge-mihomo.sock`，可用
`MIREMOTE_CLASH_SOCK` 覆盖。

## 边界

- `mute-guard` 只解除静音，不碰音量、不碰物理设备、不改默认设备；
- `watchdog` 的恢复分级有爆炸半径：先驱动宿主、再 coreaudiod、最后提示重启；
- 两个脚本都不接受任意命令参数，用途写死；
- helper 未安装时，`watchdog` 只记 `RECOVER skipped`，不会半途动手。
