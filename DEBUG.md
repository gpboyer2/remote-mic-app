# Automatic Application Focus Investigation

## Observations

- Environment: macOS 26.5.2 (25F84), Swift 6.3, Remote Mic 1.4.7 build 31, cmux 0.64.20.
- User reproduction: Claude focuses correctly; cmux focuses after switching from another app but not when cmux is already frontmost; Codex fails in both states.
- Remote Mic schedules cmux focus after 100 ms and requires the target PID to be frontmost before and during the two RPC calls.
- Remote Mic calls `surface.current` followed by `surface.focus` for cmux.
- cmux `surface.focus` calls `Workspace.focusPanel`, whose normal focus path preserves a foreign first responder such as the right sidebar.
- cmux's own explicit terminal-focus path additionally calls `ensureFocus(... respectForeignFirstResponder: false)`.
- The Codex/Claude Accessibility path currently searches only `AXTextArea` and `AXTextField` descendants of the focused/main window, stops after 1,500 elements, and requires a score of at least 80.
- The Mac returned to `loginwindow` before the live Accessibility probe, so the final investigation used the installed application bundles and the user's reproducible foreground/background boundary instead of claiming a live AX snapshot.
- Codex's installed web bundle shows that the main ProseMirror composer is rendered after the conversation surface, with `role="textbox"`, `aria-multiline="true"`, and an aria label/placeholder of `Message ChatGPT`.
- `Message ChatGPT` already satisfies the existing supporting semantic term `message` even without geometry, which rejects the theory that the Codex composer is excluded by the scorer.
- cmux's `GhosttyNSView` explicitly exposes the terminal as an editable `AXTextArea` with Accessibility help `Terminal content area`, so Remote Mic can request the actual AppKit first responder without using a state-dependent shortcut.

## Hypotheses

### H1: cmux preserves an in-app non-terminal first responder (ROOT HYPOTHESIS: cmux)

- Supports: the failure occurs only when cmux is already frontmost; cmux source explicitly distinguishes ordinary surface selection from forced terminal first-responder focus.
- Conflicts: `surface.focus` reports success even in the failing state, so RPC success alone cannot prove keyboard focus.
- Test: focus a cmux sidebar control, call `surface.focus`, and inspect whether the Accessibility focused element remains outside the terminal.

### H2: Codex exposes the composer under a role not collected by Remote Mic

- Supports: Claude works through the same scheduler and permission gate, while Codex is an independently implemented desktop UI.
- Conflicts: the installed Codex bundle explicitly renders the composer as an ARIA multiline textbox, which Chromium maps to an editable Accessibility text area.
- Test: enumerate the focused Codex window's Accessibility roles and attributes without changing production code.

### H3: Codex exposes an eligible text element but its semantics or geometry score stays below 80

- Supports: the scorer rejects `AXTextField` without recognized prompt/message terms and can reject small or upper-positioned candidates.
- Conflicts: the installed composer label is `Message ChatGPT`; the existing `message` term gives an `AXTextArea` a score of at least 120, above the threshold without geometry.
- Test: feed snapshots from the live Codex tree into the existing scorer and print candidate scores.

### H4: Codex focus runs before its window or composer is ready

- Supports: application activation and Electron/SwiftUI view updates can be asynchronous.
- Conflicts: the implementation retries for about 1.4 seconds and fails even when Codex was already frontmost.
- Test: invoke the existing composer focus synchronously against an already-stable Codex process; success would reject this hypothesis.

### H5: Codex's composer is eligible but is starved by the breadth-first 1,500-node traversal cap (ROOT HYPOTHESIS: Codex)

- Supports: the installed UI places the composer after the conversation surface; the current implementation enqueues the full transcript branch first and stops after 1,500 elements; long Codex tasks contain substantially more Accessibility descendants than Claude's compact composer surface.
- Conflicts: a live AX node count could not be collected after the machine locked, so the fix must also verify the actual focused element instead of trusting an AX setter return code.
- Test: model a long transcript ahead of a valid lower composer and compare the current breadth-first cap with a visible/lower-first traversal; the former omits the composer while the latter reaches it before transcript descendants.

## Experiments

1. **cmux source-path comparison — confirmed H1.** `surface.focus` ends at ordinary `Workspace.focusPanel`, while cmux's explicit terminal-focus controller immediately follows that selection with `ensureFocus(... respectForeignFirstResponder: false)`. This exactly explains why switching into cmux works through window activation but repeating the action while a sidebar owns first responder does not.
2. **Codex bundle semantics — rejected H2 and H3.** The production bundle renders the primary ProseMirror editor as a multiline ARIA textbox and passes `Message ChatGPT` as both aria label and placeholder. Feeding that semantic value through the current scorer is sufficient to pass the 80-point threshold without frame data.
3. **Timing boundary — rejected H4 as the primary cause.** The user reproduces the failure while Codex is already frontmost and stable, after the existing eight retries spanning roughly 1.4 seconds. Activation timing cannot explain that state.
4. **Traversal boundary — confirmed H5 at the code boundary.** The current breadth-first algorithm consumes transcript descendants in DOM/AX order and has an unconditional 1,500-element stop before the bottom composer branch. A lower/visible-first traversal reaches the composer branch before descending through the transcript, removing the failure condition without weakening field filtering.

## Root Cause

- cmux selects the correct terminal surface but deliberately preserves an in-app foreign first responder, so a successful RPC does not mean the terminal accepts keyboard input.
- Codex's valid composer sits behind a large conversation Accessibility subtree, while Remote Mic searches only ordinary `AXChildren` breadth-first with a hard 1,500-element cap and treats an AX setter return code as proof of focus.

## Fix

- After cmux selects its current terminal surface, focus the terminal's explicit `AXTextArea` and verify that it became the focused Accessibility element.
- Discover composers through navigation-order, visible, content, and ordinary child relationships; prioritize editable and lower visible elements; search all application windows; and only report success after the focused element is verified.

# cmux Frontmost Refocus Follow-up

## Observations

- User verification of 1.4.8: Claude and Codex focus correctly; cmux focuses when activated from another app but still fails when cmux is already frontmost.
- The current regression test only proves that `surface.current`, `surface.focus`, and a mocked terminal-focus callback are invoked. It does not verify the final application-level focused Accessibility element.
- In cmux 0.64.20, the live Accessibility tree exposes the terminal as an `AXTextArea` with help `Terminal content area`; focusing the Help popover moves the application-level focused element to a sidebar button while the terminal remains present in the same window.
- A live `surface.current` call identifies the expected terminal surface and `surface.focus` returns success, so surface discovery and RPC transport are not sufficient evidence of keyboard focus.
- `accessibilityElementIsFocused` currently returns true immediately when the candidate's own `AXFocused` attribute is true, before checking the application's `AXFocusedUIElement`.

## Hypotheses

### H6: cmux's terminal reports stale/local `AXFocused` while another control owns the application focus (ROOT HYPOTHESIS)

- Supports: the failure only occurs when cmux is already frontmost and an in-app control can retain first responder; the verifier trusts element-local focus before application-level focus.
- Conflicts: the Computer Use tree does not expose the raw terminal `AXFocused` attribute, only the final application-level focused element.
- Test: focus a sidebar control, run the existing terminal focus path, and require application-level `AXFocusedUIElement` equality instead of accepting element-local focus alone.

### H7: Remote Mic chooses a terminal from the wrong cmux window or pane

- Supports: the search examines every application window and ranks candidates by selected context and geometry rather than by the RPC surface identifier.
- Conflicts: the live reproduction currently has one cmux window and one terminal candidate, and `surface.current` returns that window's terminal.
- Test: inspect the live Accessibility candidates and compare their window/pane geometry with `surface.current`.

### H8: cmux asynchronously restores sidebar focus after Remote Mic focuses the terminal

- Supports: cmux mixes AppKit terminal views with SwiftUI sidebar/popover controls, so responder changes may be deferred.
- Conflicts: the current implementation does not sample the final focused element after a delay, so no evidence yet shows a post-focus reversal.
- Test: sample the application-level focused element immediately and again after 100-300 ms following the focus request.

### H9: `NSWorkspace.openApplication` does not provide a usable PID/completion when cmux is already active

- Supports: this path is only entered through the application-open completion.
- Conflicts: macOS normally returns the existing `NSRunningApplication`, and the background activation case uses the same opener successfully.
- Test: record the returned PID and compare it with the running cmux process in both foreground states.

## Experiments

1. **Live cmux focus boundary — confirmed the RPC/model mismatch.** With the workspace sidebar table as the application-level focused element, `surface.current` returned the expected terminal, pane, workspace, and window. Both `surface.focus` and `pane.focus` returned success, but those APIs only establish cmux's selected surface/pane model and are not a reliable contract for AppKit first responder ownership.
2. **cmux 0.64.20 source comparison — confirmed the foreign-responder behavior.** `surface.focus` calls `Workspace.focusPanel`, which reaches `TerminalPanel.focus()` and `focusTerminalSurface(respectForeignFirstResponder: true)`. cmux's own explicit `MainWindowFocusController.focusTerminal()` instead calls `ensureFocus(... respectForeignFirstResponder: false)` and verifies `isSurfaceViewFirstResponder()`; that force-focus operation is not exposed as a socket method.
3. **Candidate targeting — rejected H7 for the reproduction.** The live tree contains one cmux window and one `Terminal content area` candidate, and the RPC response resolves that same window/pane/surface.
4. **Verification-policy inspection — confirmed H6 at the Remote Mic boundary.** `accessibilityElementIsFocused` accepts the terminal element's local `AXFocused` value before consulting the application's `AXFocusedUIElement`. cmux can keep the terminal surface selected/focused in its model while a legitimate foreign responder owns keyboard focus, so the fallback can report success without attempting the force-focus setters or `AXPress`.

## Root Cause

The cmux fallback mistakes the terminal element's local surface-focus state for application keyboard focus, allowing a sidebar/TextBox first responder to remain active while Remote Mic reports success.

## Fix

- Require application-level `AXFocusedUIElement` equality when verifying cmux terminal focus, while preserving the existing local-or-application verification policy for Codex and Claude.
- Add a regression test for stale local focus with an application-level mismatch.

# cmux Frontmost Refocus Follow-up 2

## Observations

- User verification of 1.4.9: the cmux-already-frontmost case still fails.
- The exact user reproduction is clicking cmux's left workspace sidebar, then triggering the Remote Mic open-cmux action.
- 1.4.9 only tightened focus verification; after verification fails it still uses generic AX setters and performs no delayed retry.
- On cmux 0.64.20, a live `surface.focus` moved focus from the ordinary workspace table to `Terminal content area`, so the RPC is capable of focusing the terminal in that state.
- cmux deliberately preserves exactly two legitimate foreign first-responder categories during ordinary `surface.focus`: an `NSText` editor and a right-sidebar owner.
- cmux's default `Cmd+Shift+A` path toggles an active TextBox back to the terminal with `respectForeignFirstResponder: false`; its default `Cmd+Shift+E` path moves right-sidebar focus back through `MainWindowFocusController.focusTerminal()`.
- The current cmux configuration does not override either default shortcut.
- `NSWorkspace.openApplication` returned the existing cmux PID, rejecting the missing-process hypothesis. The graphical session locked before a delayed post-activation sample could be collected.

## Hypotheses

### H10: Tightened verification was mistaken for a force-focus fix (ROOT HYPOTHESIS)

- Supports: 1.4.9 changes only the success predicate; it never invokes cmux's two explicit foreign-responder escape paths.
- Conflicts: generic AX focus can work for some controls, but the user reproduces the state where it does not.
- Test: trace the failing TextBox/right-sidebar paths from `surface.focus` to their `respectForeignFirstResponder: true` early returns, then trace the official shortcuts to the force-focus calls.

### H11: The single 100 ms attempt loses an activation/focus reconciliation race

- Supports: cmux restores focus intent during AppKit window lifecycle callbacks, and Remote Mic performs no final delayed verification.
- Conflicts: the failure also has a deterministic source-level explanation for legitimate foreign responders.
- Test: retry after the official recovery shortcut and require terminal verification before reporting success.

### H12: `openApplication` returns no running process when cmux is already active

- Supports: that would skip all focus work.
- Conflicts: a live call returned PID 94253 with no error.
- Test: completed by printing the completion result while the existing cmux process was running.

## Experiments

1. **Ordinary sidebar focus — rejected a blanket RPC failure.** `surface.focus` changed the live application-level focused element from the workspace table to `Terminal content area`.
2. **Foreign-responder policy trace — confirmed H10.** `surface.focus` preserves `NSText` and right-sidebar responders, while `Cmd+Shift+A` and `Cmd+Shift+E` reach cmux-owned methods that pass `respectForeignFirstResponder: false`.
3. **Process completion — rejected H12.** `NSWorkspace.openApplication` returned the existing cmux process identifier without error.
4. **Exact left-sidebar production path — confirmed the retry fix.** With the live application-level focus on the left workspace `AXTable`, an opt-in integration test called `KeyboardInjector.send(.openCmux)` and verified that the final focus became the terminal `AXTextArea` with help `Terminal content area`.
5. **Neighboring live states — passed.** The same complete production action restored focus from cmux TextBox and right-sidebar states and remained focused when the terminal already owned focus.

## Root Cause

1.4.9 corrected a false-positive focus check but did not add a force-focus mechanism for the two responder classes that cmux intentionally preserves, so the original frontmost failure remained.

## Fix

- When terminal verification fails, use geometry plus AX role to select cmux's official recovery shortcut: main-panel TextBox fields use `Cmd+Shift+A`, confirmed right-sidebar controls use `Cmd+Shift+E`, and left-sidebar controls do not detour through the right sidebar.
- Retry the complete `surface.current` / `surface.focus` / terminal-verification sequence after a short delay and report success only after the terminal owns application focus.
- Keep an opt-in live integration test that calls the production open action and verifies the final application-level terminal focus; require it for cmux-focus releases.

# 语音链路失效排查 SOP（2026-11-01 实战复盘，可复用）

> 适用现象：遥控器按键/语音"突然不管用"。
> 本机环境：macOS 13.2.1（Ventura）/ Mac mini M2 / Remote Mic 1.4.11 / 豆包输入法 1.0.3。
> 本次全程只用日志 + 网络连接表 + 程序化探针定位，**没有截图、没有让用户点 GUI**。40 分钟才恢复，其中约一半时间浪费在"让用户看电平/开 QuickTime"这类无效验证上——下次按本文 SOP 走，目标是 5 分钟内分层定位。

## 0. 30 秒速查表（现象 → 直奔哪里）

| 现象 | 大概率所在层 | 先看什么 |
| --- | --- | --- |
| 按麦克风键，豆包毫无反应 | 豆包全局热键监听 / HID 映射 | `hidutil --get UserKeyMapping` + 豆包进程 etime 是否 > 1 天 |
| **别的键都好，只有麦克风键不管用** | HID 映射层（唯一只依赖映射的键） | "改回车验证法"（见 2.2） |
| 进了"识别中"但一个字都不出 | 豆包音频采集 / 流式通道 | DoubaoIme 日志的 `CMIO` + `FindAvailableStream`（见 2.4） |
| 说完一大段才出字、波浪动画不动 | 豆包流式通道退化成批量识别 | mihomo 连接表有无 `audio-ime-ws`（见 2.5） |
| 无线麦显示"已连接 / 语音中" | 说明 BLE + ATVV 正常，别再从遥控器查 | `runtime.log` 有 `ATVV STREAM START` 即可判正常 |

## 1. 依赖分层（必须按层排，跳层就会猜）

```
遥控器(RC003) --BLE/ATVV--> 无线麦(本 App) --写--> MiRemoteV 2ch(虚拟声卡) --读--> 豆包输入法 --流式/批量--> 文字
       ①按键/语音键映射(F5→右Control)  ②音频引擎绑定  ③设备 IO 状态          ④ASR 服务通道
```

四条边界各自独立失败，且**症状不同**：

- ① 挂了 → 豆包根本不知道你在说话（无界面反应）。
- ② 挂了 → 豆包能进"识别中"，但听到静音。
- ③ 挂了 → 同样是静音，但 App 日志一切正常（最难查，见第 3 节的坑 6）。
- ④ 挂了 → 能进"识别中"、能出字，但只在说完后一次性出字、波浪不动。

## 2. 可复制诊断命令

### 2.1 无线麦自身（先确认 App 层不是病根）

```bash
ps -o pid,lstart,etime,comm -p "$(pgrep -x RemoteMic)"
tail -40 ~/Library/Logs/RemoteMic/runtime.log
```

健康基线（一条正确连接的日志应该长这样）：

```
HID PERMISSIONS input=true accessibility=true
VOICE FN MAPPING applied=true matched=1
HID CONNECTED mode=monitored seize_error=-536870207   # 本机 seize 一直失败 → 兼容模式，正常
AUDIO READY target={name=MiRemoteV 2ch ...} bound_to_selected=true
BLE READY name=小米蓝牙语音遥控器
VOICE RIGHT_CTRL HARDWARE DOWN mapping=true
ATVV STREAM START session=N
```

- ⚠️ `runtime.log` 的**时间戳是 UTC**（`2026-11-01T07:19:01Z` = 本地 15:19）。按本地时间去 grep 会一无所获，这是本次踩过的第一大坑。
- ⚠️ 日志目录 `~/Library/Logs/RemoteMic/` 被清理工具删掉后，**老进程永远不会再写日志**（`AppLogger` 只在 init 时建目录，父目录没了 atomic write 静默失败）→ "查不到历史日志"本身就是线索，重启 App 才会重建。
- ⚠️ `log show --predicate 'process == "RemoteMic"'` 里每秒一条 `TCCAccessRequest() IPC` 是**权限轮询，正常**，不是故障。

### 2.2 麦克风键映射：先看在不在，再证明生不生效（本机最常用）

```bash
# 在不在（src 0x70000003E = F5，dst 0x7000000E4 = 右 Control）
hidutil property --matching '{"VendorID":0x2717,"ProductID":0x32B8}' --get UserKeyMapping
```

**"改成回车"验证法（秒级、无需任何权限、不碰 App 代码）**：把 dst 临时改成 Return `0x700000028`，在任意输入框按一下遥控器麦克风键——出现换行 = 映射链路是活的，问题不在这一层；什么都没出现 = 映射失效或遥控器没发键。

```bash
# 改成回车（测试用）
hidutil property --matching '{"VendorID":0x2717,"ProductID":0x32B8}' \
  --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x70000003E,"HIDKeyboardModifierMappingDst":0x700000028}]}'
# 测完必须改回右 Control
hidutil property --matching '{"VendorID":0x2717,"ProductID":0x32B8}' \
  --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x70000003E,"HIDKeyboardModifierMappingDst":0x7000000E4}]}'
```

关键事实（本次定位时确认）：**麦克风键不在 `RemoteButton` 里**，App 对它不做任何软件处理，只靠 HID `UserKeyMapping` 把 F5 改写成右 Control；其他按键走"抑制原生 + 软件重发"的路径。所以"别的键都好、只有麦克风键不行"= 映射层问题的特征指纹。

### 2.3 音频设备层（有没有设备 / 格式对不对 / 默认输入是谁）

```bash
system_profiler SPAudioDataType | grep -A6 "MiRemoteV"
# 健康值：Input Channels 2 / Output Channels 2 / Current SampleRate 48000
```

程序化切换默认输入设备（用户不接受 GUI 操作时的替代，见附录 A）。

### 2.4 豆包侧（识别为什么不出字 / 为什么退化）

```bash
# 每次开口的两类报错（关键）
log show --last 10m --predicate 'process == "DoubaoIme" AND (composedMessage CONTAINS "FindAvailableStream" OR composedMessage CONTAINS "CMIO")' --style compact
# 今天有没有真的开会话（计数看使用时段）
log show --start "$(date +%Y-%m-%d) 00:00:00" --predicate 'process == "DoubaoIme" AND composedMessage CONTAINS "kAudioDevicePropertyDeviceIsRunning is currently 1"' --style compact | awk '{print $2}' | cut -d: -f1 | sort | uniq -c
```

两条报错的含义：

- `CMIO_Unit_Converter_Audio ... AudioConverterSetProperty failed (1886547824)`：豆包音频采集的转换器配置失败（1886547824 = `'prop'`）。**每次开口必刷时是"半恢复"状态的特征**，别只凭它判死。
- `tt_frontier_client_sdk ... FindAvailableStream service id: N, service is not ready.`：豆包自己的**流式 ASR 通道没建起来**。注意它**在能用的时候也会刷一条**（首连失败→重试成功），只有"连续刷 + 一直批量"才是故障。

重启豆包输入法（长跑失效的复位动作，**本次靠它把"完全没反应"救回来**）：

```bash
killall DoubaoIme   # 切一下输入法/敲字即自动 relaunch，无需重登录
```

判据：豆包进程 `etime` 超过 1 天就要怀疑全局热键监听失效；`RemoteMic` 也一样（长跑 7 天）。

### 2.5 流式 vs 批量（"时实时时批量"的唯一判据）

```bash
curl -s --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/connections | python3 -c '
import json,sys
d=json.load(sys.stdin)
for c in d.get("connections") or []:
    h=c.get("metadata",{}).get("host","")
    p=c.get("metadata",{}).get("processPath","")
    if "oubao" in p: print(h, c.get("chains"), "up",c.get("upload"),"down",c.get("download"))'
```

- 有 `frontier*-audio-ime-ws-*.doubao.com` → 流式通道在，文字应该边说边出。
- 只有 `speech.bytedance.com` / `ime.doubao.com` → 当前是批量识别：**说完才出字、波浪动画不动**（波浪吃的就是流式实时电平 `onMonitorAmplitude` / `currentAmplitude`）。
- 网络不用怀疑：本机实测各 frontier 节点 TCP 建连 13–30 ms，IPv6/UDP 正常。

### 2.6 "踢"一下卡死的虚拟声卡（第 3 节坑 6 的解法）

打开一次新的 IO 客户端（见附录 B）：若 App 侧日志全绿、豆包却听不到声音，这一步能在几秒内把设备 IO 重新初始化。彻底修：重启机器，或 `sudo killall coreaudiod`。

## 3. 本次踩过的坑（按踩坑代价排序）

1. **日志目录被清理工具删掉**（腾讯柠檬一类）：`~/Library/Logs/RemoteMic/` 整个没了 → 老进程之后 7 天的日志全丢，`AppLogger` 静默失败。→ 先 `ls` 目录，不存在就重启 App 重建。
2. **runtime.log 是 UTC**，本地 15:xx 的事件在日志里是 `07:xx`，grep 本地时间会"什么都没有"。
3. **每秒 `TCCAccessRequest()` 是权限轮询**，不是故障；别把它当异常。
4. **`service is not ready` 不是病根**：能用时也刷一条。只有"连续刷 + 只用批量"才代表流式通道死了。
5. **"输入电平全灰"不等于没音频**：没开会话时它本来就是灰的。用它当证据会得到错误结论（用户当时据此问"是不是被谁占据了"——并没有人占用）。
6. **MiRemoteV 的 IO 会卡死**（7 天不重启 + 9 次睡眠唤醒）：App 日志 `AUDIO READY bound_to_selected=true`、`ATVV STREAM START` 全正常，豆包也确实打开了麦克风（设备 running=1），但读出来的是静音。**重启 App 无效，只有新的 IO 客户端 / 重启 coreaudiod / 重启机器能复位**。这是最像"玄学"的一层，也是本次真正的病根之一。
7. **不要用 `ffmpeg -f avfoundation` 做电平判断**：本机 `-list_devices` 直接报 I/O error，CLI 拿不到麦克风 TCC；自建 AVAudioEngine 回环测试会因为 TCC 状态不可靠而得到假结果（本次测得 peak 0.0045，无法区分"设备没声"和"权限被静默置零"）。→ 电平这事要么看豆包自己的日志/连接表，要么别测。
8. **豆包的 alog 日志读不了**（`~/Library/Application Support/DoubaoIme/Log/alog/*.hot`，53 MB，加密+压缩）。别在这上面花时间，转去 `log show` 的 `chromium_logging` 通道。
9. **Clash 订阅自动更新会改激活配置**（本次今天 10:16 自动更新并切换配置，旧配置有 `bytedance.com → 全球直连`，新配置没有），时间上极像元凶。**证伪方法**：关系统代理 → 重启豆包 → 再测一次（本次做完证明无关，代理已恢复）。
10. **兼容模式是常态**：本机 `seize` 一直失败（`-536870207`），显示"兼容模式"，其他按键照样可用；不要因为看到"兼容模式"就以为按钮功能没生效。
11. **引擎会被 macOS 悄悄甩回系统默认输出**（2026-11-04 复发）：`按住麦克风键反而外放、豆包收不到`。App 自己的日志不会自己变（没触发恢复事件），必须用进程级观察：`pmset -g assertions | grep audio` 看谁占着哪个设备，或 `log show --predicate 'process == "coreaudiod"' | grep 'on behalf of <pid>'` 看该进程实际在哪个设备上跑 IO。本次实测 `RemoteMic(466)` 在 `BuiltInSpeakerDevice` 上连续持有 IO 上下文 14 分钟（09:08:06→09:22:31），而它以为自己在 MiRemoteV。
12. **App 退出会把麦克风键映射还原**（`VOICE FN MAPPING restored=1`）：App 没运行时麦克风键就是裸 F5，按了当然"没反应"；排查前先确认 App 在跑。

## 4. 协作约定（本机用户习惯，务必遵守）

- **不要让他截图、点 GUI、开 QuickTime、切系统设置来回验证**。他明确说过："直接通过日志、数据库、埋点排查"。所有验证都要程序化（`hidutil`、CoreAudio、mihomo 连接表、`log show`）。
- 一开始花 10 分钟把"现象"对齐清楚（三分支：完全没反应 / 有界面无字 / 有字但断），比后面盲试快得多；本次靠这一问直接砍掉了两条链路。
- 一轮排查 5–15 分钟，卡住就说明卡在哪一层，不要闷着耗；同一个问题拖到半小时就是在猜。
- 回复格式：**当前情况 / 做了哪些 / 其他** 三段，只讲逻辑和业务，不贴代码细节。
- **所有临时改动必须还原并在结尾列出清单**：HID 映射改回 `0xE4`、默认输入改回 MiRemoteV 2ch、系统代理恢复、关掉的进程重启（本次清单照此执行）。

## 5. 本次故障的真实时间线与根因（两个独立故障叠加）

- 10:16 Clash Verge 自动更新订阅并切换激活配置（后来证明与故障无关）。
- 11:19 用户当天第一次用语音，豆包开始全程刷 `FindAvailableStream ... not ready`（流式通道从此没稳定过）。
- 15:0x 用户报"昨天还好好的今天不行"：其实叠加了两件事
  1. **豆包进程跑了 4 天 18 小时** → 全局语音热键监听失效 → 按麦克风键"完全没反应"（重启豆包即恢复）。
  2. **MiRemoteV 虚拟声卡 IO 卡死** → 豆包能打开麦克风但收到静音 → 恢复触发后依然"没字"。
- 15:19 重启 App（无效，因为问题不在 App 的软件状态）；15:26 重启豆包（恢复触发）；15:45 开了一个新 IO 客户端 → 音频通道复位 → 出字。
- 之后剩"时实时时批量 + 波浪不动"：属于豆包**流式通道**自身不稳定（ws 连接时有时无），本机侧已无改动点。

## 6. 代码侧待加固（TODO，下次改代码时优先做）

1. `AppLogger`：每次写日志前确保父目录存在（`createDirectory` 一次不够，清理工具删掉后就永久静默）。
2. ✅ 已完成（2026-11-04）：`AudioOutput` 不再信任"设置过"的设备，`configure` 回读 AUHAL 实际设备、不一致即停引擎报错；新增 `ensureBoundToSelectedDevice()` 在每次开口前校验并重建；`BridgeAppModel` 注册 `NSWorkspace.didWakeNotification` 唤醒后自动重绑。验证锚点：日志 `AUDIO VOICE SESSION begin bound=true`、异常时 `AUDIO CONFIGURE failed reason=bind_mismatch` / `AUDIO BINDING drift`。
3. 麦克风键触发不要 100% 依赖 HID `UserKeyMapping`：兼容模式回落时可用 `KeyboardInjector.postRightControlTap()`（代码里已有但当前未使用）——注意先去重，避免与映射产生双触发。
4. 菜单"显示日志"在日志文件不存在时给出明确提示，而不是打开一个不存在的路径。
5. （可选）在"连接与语音"页加一个自检按钮：一键输出"映射是否生效 / 默认输入是否 MiRemoteV / 最近一次会话是否有音频写入"，把本文第 2 节的手工命令产品化。

## 附录 A：程序化切换默认输入设备（无 GUI）

```swift
// setinput.swift  →  swiftc -O setinput.swift -o setinput && ./setinput MiRemoteV
import CoreAudio
import Foundation

func devices() -> [AudioDeviceID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
    var ids = [AudioDeviceID](repeating: 0, count: Int(sz) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)
    return ids
}
func name(_ id: AudioDeviceID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: CFString = "" as CFString
    var sz = UInt32(MemoryLayout<CFString>.size)
    withUnsafeMutablePointer(to: &cf) { _ = AudioObjectGetPropertyData(id, &a, 0, nil, &sz, $0) }
    return cf as String
}
let needle = CommandLine.arguments.dropFirst().first?.lowercased() ?? ""
guard let dev = devices().first(where: { name($0).lowercased().contains(needle) }) else { exit(2) }
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var d = dev
print("set default input -> \(name(dev)) status=\(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &d))")
```

## 附录 B：给 MiRemoteV 开一次新 IO（"踢"活卡死的设备）

```swift
// kick.swift → swiftc -O kick.swift -o kick && ./kick MiRemoteV
import AVFoundation
import CoreAudio
import Foundation

func deviceID(_ needle: String) -> AudioDeviceID? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
    var ids = [AudioDeviceID](repeating: 0, count: Int(sz) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)
    return ids.first { id in
        var n = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: CFString = "" as CFString; var s = UInt32(MemoryLayout<CFString>.size)
        withUnsafeMutablePointer(to: &cf) { _ = AudioObjectGetPropertyData(id, &n, 0, nil, &s, $0) }
        return (cf as String).contains(needle)
    }
}
guard let dev = deviceID(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MiRemoteV") else { exit(2) }
let engine = AVAudioEngine()
for node in [engine.outputNode, engine.inputNode] {
    if let au = node.audioUnit {
        var d = dev
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
}
engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
do { try engine.start() } catch { print("start error: \(error)"); exit(3) }
Thread.sleep(forTimeInterval: 2)
engine.stop()
print("IO restarted on device \(dev)")
```

> 备注：本次是靠着这个探针把 MiRemoteV 的 IO 复位后，豆包才开始出字。**它是"急救"不是"修好"**——要根治，还是重启机器 / `sudo killall coreaudiod`。

# 语音链路复发记录（2026-11-04，已根治其中一层）

## 现象

- 按住遥控器麦克风键，豆包输入法**完全不出现**（连"识别中"都没有）。
- 同时又**有外放**：按住说话时，自己说话的声音从 Mac 自带扬声器放出来。

## 定位（10 分钟，全部靠日志，无截图无 GUI）

1. `ps -o lstart,etime -p $(pgrep -x RemoteMic) $(pgrep -x DoubaoIme)` → App 连跑 2 天 0 小时、豆包连跑 2 天 → 豆包热键监听失效属于必然复发（见坑 6 同理，触发层先判长跑）。
2. `hidutil property --matching '{"VendorID":0x2717,"ProductID":0x32B8}' --get UserKeyMapping` → 映射仍在（F5→右 Control），映射层没坏。
3. `tail -30 ~/Library/Logs/RemoteMic/runtime.log` → `VOICE RIGHT_CTRL HARDWARE DOWN mapping=true` + `ATVV STREAM START` 都正常：遥控器→App 这条链路是通的。
4. **关键一步：查进程实际在哪个设备上跑 IO**
   ```bash
   pmset -g assertions | grep -i audio
   log show --last 30m --predicate 'process == "coreaudiod"' --style compact | grep -E "on behalf of <AppPID>|IOWorkLoopInit"
   ```
   结论：`RemoteMic(466)` 在 **BuiltInSpeakerDevice** 上从 09:08:06 连续持有 IO 上下文到 09:22:31（14 分钟），期间每次语音会话还另开 MiRemoteV 上下文 → 引擎的实际输出已经漂到系统扬声器，而 App 的 `diagnosticState()` 仍停留在上一次成功绑定时的 MiRemoteV（没有恢复事件，日志不动）。
5. 豆包侧只有常规 `CMIO` 转换器告警：它打开的是 MiRemoteV，但那边没有声音 → 没有字。

## 根因（两处独立）

1. **音频引擎被 macOS 甩回系统默认输出（外放 + 豆包收不到）**：`AVAudioEngine` 在设备重排/睡眠唤醒后可能把 IO 绑回默认设备，而 App 只在 `AVAudioEngineConfigurationChange` 通知里检查绑定；那次没有通知，于是引擎一直渲染到扬声器，App 还以为一切正常。
2. **豆包进程长跑后全局语音热键监听失效（按键完全不唤起）**：`killall DoubaoIme` 后自动重启即恢复。

## 修复（代码，2 个文件 +76 行）

- `Sources/RemoteMic/AudioOutput.swift`
  - 新增 `boundOutputDevice(of:)` 回读 AUHAL `kAudioOutputUnitProperty_CurrentDevice`：只认引擎**实际**绑定的设备，不认 `selectedDevice`。
  - `configure()` 启动后校验：实际设备 ≠ 所选设备 → 停引擎、报 `AUDIO CONFIGURE failed reason=bind_mismatch`，**绝不退回默认输出**（宁可不发声也不外放）。
  - 新增 `isBoundToSelectedDevice` 与 `ensureBoundToSelectedDevice()`：发现漂移就按所选 UID 重建引擎。
- `Sources/RemoteMic/BridgeAppModel.swift`
  - `bluetoothBridgeDidStartVoice` 开口前调用 `ensureBoundToSelectedDevice()`，并落日志 `AUDIO VOICE SESSION begin bound=...`（下次一眼能看出绑定对不对）。
  - `startIfNeeded` 注册 `NSWorkspace.didWakeNotification` → `scheduleAudioRecovery(reason: "system_wake")`：唤醒后主动重绑，不再等那个不一定会来的通知。

## 验证锚点（下次直接 grep 这三条）

```
AUDIO VOICE SESSION begin bound=true          # 每次开口前绑定正常
AUDIO BINDING drift expected={MiRemoteV 2ch}  # 发生过漂移并已重建
AUDIO CONFIGURE failed reason=bind_mismatch   # 重建失败（此时应无声音，也不外放）
```

实测 09:31 两次开口均 `bound=true state={...actual_output={name=MiRemoteV 2ch...bound_to_selected=true}`，用户确认"外放消失、豆包正常出字"。

## 教训

- "外放"这种听感现象，**不要从 App 界面/设置里找原因**：界面显示的是"希望绑定"的设备，只有进程级 IO 断言（`pmset -g assertions` / `on behalf of <pid>`）能证明"实际渲染到哪"。
- 长跑进程（App、豆包、甚至 coreaudiod）都要先看 `etime`；豆包 > 1 天先重启再谈别的（这一步 30 秒，能省掉一整轮误判）。



# 虚拟设备链路异常：先怀疑「谁动过它」，再怀疑自己的代码（2026-11-19）

## 现象

按住遥控器能唤起豆包输入法，但一个字都不出。RemoteMic 日志全绿
（`ATVV STREAM`、`samples=41520 peak=17857`），豆包也确实在 MiRemoteV 上开了录音。

## 这次走错的路

第一反应是「音频代码/驱动坏了」，于是去查 ffmpeg、AUHAL、IOProc、驱动 ABI，
绕了两个小时。真正的原因不在这一层。

## 正确的第一问

**这个虚拟设备，最近有没有被别的软件动过？**

MiRemoteV 不是物理声卡，它是一条软件通路。任何能改设备状态的工具
（静音工具、音量工具、音频路由、会议软件、远程桌面）都可能把它掐断。

## 通用排查顺序（虚拟声卡 / 虚拟键盘 / 虚拟蓝牙都适用）

1. **状态位**：设备当前是 muted / disabled / disconnected 吗？
   - 声卡：`muted`、`volume`
   - 键盘：HID 映射是否被改写、事件是否被拦截
   - 蓝牙：连接是否被别的 App 抢走
2. **谁在改它**：有没有常驻工具、LaunchAgent、定时任务在操作这类设备？
3. **最近变化**：新装的工具、改过的配置、跑过的脚本。
4. **才轮到自己的代码**：日志、数据面、驱动、系统。

## 本次实例（只作为证据，不作为唯一答案）

`mutectl snapshot` 显示 `MiRemoteV 2ch: muted=True`；解除后，同一段写入的环回
从 `0` 恢复到 `-17.3 dBFS`。改它的是另一个常驻工具 auto-mute 的「静音全部输出设备」。

## 举一反三

| 虚拟设备 | 可能被谁影响 | 先查什么 |
|---|---|---|
| 虚拟声卡（MiRemoteV / BlackHole） | 静音工具、音量工具、音频路由、会议软件 | `muted` / `volume` / 谁在写它 |
| 虚拟键盘（HID 注入 / 映射） | 键盘增强工具、自动化脚本、输入法 | 映射表、事件是否被拦截 |
| 虚拟蓝牙（BLE 桥接） | 蓝牙管理工具、耳机切换、其他 App 的连接 | 连接归属、是否被抢 |
| 虚拟摄像头 | OBS、会议软件、虚拟背景工具 | 是否被独占 |

## 教训

1. 虚拟设备是「共享资源」，不是「我的私有外设」。先问谁动过它。
2. 先查状态位（10 秒），再查数据面（分钟），最后查驱动/系统（小时）。
3. 不要在故障链路上做变量切换——那是在给自己加变量。
