import AVFoundation
import AudioExceptionGuard
import AudioToolbox
import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioPlayerNodeSafety {
    static func play(_ player: AVAudioPlayerNode) -> Bool {
        RemoteMicTryPlayAudioPlayerNode(player)
    }
}

enum CoreAudioDeviceCatalog {
    private static let propertyLock = NSRecursiveLock()

    static func outputDevices() -> [AudioDeviceInfo] {
        withPropertyLock {
            outputDevicesLocked()
        }
    }

    private static func outputDevicesLocked() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        let result = deviceIDs.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return OSStatus(-1) }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        guard result == noErr else { return [] }

        var seenUIDs = Set<String>()
        return deviceIDs.compactMap { deviceID in
            guard outputChannelCount(for: deviceID) > 0 else { return nil }
            return deviceInfo(for: deviceID)
        }
        .filter { seenUIDs.insert($0.uid).inserted }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func deviceInfo(for deviceID: AudioDeviceID) -> AudioDeviceInfo? {
        withPropertyLock {
            guard deviceID != kAudioObjectUnknown,
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
            else { return nil }
            return AudioDeviceInfo(id: deviceID, uid: uid, name: name)
        }
    }

    static func routeDiagnostic() -> String {
        withPropertyLock {
            let input = defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
            let output = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
            let systemOutput = defaultDevice(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
            return "default_input={\(deviceDiagnostic(input))} " +
                "default_output={\(deviceDiagnostic(output))} " +
                "default_system_output={\(deviceDiagnostic(systemOutput))}"
        }
    }

    static func outputDevicesDiagnostic(_ devices: [AudioDeviceInfo]) -> String {
        devices.map(deviceDiagnostic).joined(separator: " | ")
    }

    static func deviceDiagnostic(_ device: AudioDeviceInfo?) -> String {
        guard let device else { return "none" }
        return "name=\(device.name) id=\(device.id)"
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceInfo? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return nil }
        return deviceInfo(for: deviceID)
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func withPropertyLock<T>(_ operation: () -> T) -> T {
        propertyLock.lock()
        defer { propertyLock.unlock() }
        return operation()
    }
}

final class VirtualAudioOutput {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var engineConfigurationObserver: NSObjectProtocol?
    private var engineConfigurationGeneration: UInt64 = 0
    private var rejectedWriteCount = 0
    private var lastRejectedWriteLogDate = Date.distantPast
    // 会话级写入统计：用来区分“遥控器没声音”“写不进去”“写进去但声卡没消费”三种故障。
    private var sessionStats = AudioSessionStats()
    // 会话开始时的播放计数基线。必须在开口时采样，结束后才能算出
    // “本会话期间设备消费了多少帧”；若只在收尾时采样，两段会话之间的空闲渲染
    // 也会被算进来，device_frames 永远非零，这个判据就废了。
    private var consumedBaseline: Int64?
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private(set) var selectedDevice: AudioDeviceInfo?
    private(set) var status = LocalizedMessage("未选择语音输出设备")
    var onConfigurationChange: (() -> Void)?

    @discardableResult
    func configure(deviceUID: String) -> Bool {
        let previousState = diagnosticState()
        stop()
        guard !deviceUID.isEmpty else {
            status = LocalizedMessage("未选择语音输出设备")
            AppLogger.shared.write("AUDIO CONFIGURE skipped reason=no_selected_device previous={\(previousState)}")
            return false
        }
        let availableDevices = CoreAudioDeviceCatalog.outputDevices()
        guard let device = availableDevices.first(where: { $0.uid == deviceUID }) else {
            status = LocalizedMessage("所选语音输出设备不可用")
            AppLogger.shared.write(
                "AUDIO CONFIGURE failed reason=selected_device_unavailable " +
                    "available={\(CoreAudioDeviceCatalog.outputDevicesDiagnostic(availableDevices))}"
            )
            return false
        }
        AppLogger.shared.write(
            "AUDIO CONFIGURE begin target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} " +
                "previous={\(previousState)}"
        )

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: sourceFormat)

        guard let outputUnit = engine.outputNode.audioUnit else {
            status = LocalizedMessage("无法打开 CoreAudio 输出单元")
            AppLogger.shared.write("AUDIO CONFIGURE failed reason=no_output_unit target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))}")
            return false
        }
        var deviceID = device.id
        let result = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard result == noErr else {
            status = LocalizedMessage("无法选择音频设备（错误 %@）", arguments: [String(result)])
            AppLogger.shared.write(
                "AUDIO CONFIGURE failed reason=set_current_device " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} error=\(result)"
            )
            return false
        }

        do {
            engine.prepare()
            try engine.start()
            // macOS 可能把引擎输出甩回系统默认设备（表现为“按住语音键反而外放”）。
            // 读得到实际设备就严格校验；读不到（极少数情况）只记一笔，交给开口前的漂移校验兜住。
            let boundDevice = Self.boundOutputDevice(of: engine)
            if let boundDevice, boundDevice.id != device.id {
                player.stop()
                engine.stop()
                status = LocalizedMessage(
                    "语音输出未生效（实际输出：%@）",
                    arguments: [boundDevice.name]
                )
                AppLogger.shared.write(
                    "AUDIO CONFIGURE failed reason=bind_mismatch " +
                        "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} " +
                        "actual={\(CoreAudioDeviceCatalog.deviceDiagnostic(boundDevice))}"
                )
                return false
            }
            if boundDevice == nil {
                AppLogger.shared.write(
                    "AUDIO CONFIGURE unverified reason=current_device_unreadable " +
                        "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))}"
                )
            }
            guard AudioPlayerNodeSafety.play(player) else {
                player.stop()
                engine.stop()
                status = LocalizedMessage("所选语音输出设备不可用")
                AppLogger.shared.write(
                    "AUDIO ERROR player_start_exception " +
                        "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))}"
                )
                return false
            }
            self.engine = engine
            self.player = player
            selectedDevice = device
            // 新引擎的播放计数从零开始，旧基线必须丢弃，
            // 否则第一次汇总会拿新计数减旧基线，算出负数。
            consumedBaseline = nil
            observeConfigurationChanges(for: engine)
            status = LocalizedMessage("语音输出：%@", arguments: [device.name])
            AppLogger.shared.write("AUDIO READY target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} state={\(diagnosticState())}")
            return true
        } catch {
            status = LocalizedMessage(
                "启动音频输出失败：%@",
                arguments: [error.localizedDescription]
            )
            AppLogger.shared.write(
                "AUDIO ERROR start_failed=\(error.localizedDescription) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(device))} state={\(diagnosticState())}"
            )
            return false
        }
    }

    var isReadyForTestTone: Bool {
        selectedDevice != nil && engine?.isRunning == true
    }

    /// 引擎是否真的渲染在所选设备上。每次开口前必须用它判断，
    /// 这是 2026-11-04 “按住麦克风键外放、豆包收不到声音” 的复发点。
    var isBoundToSelectedDevice: Bool {
        guard let selectedDevice,
              engine?.isRunning == true,
              let actual = currentOutputDevice()
        else { return false }
        return actual.id == selectedDevice.id
    }

    /// 语音开始前校验绑定：已绑定直接返回 true；否则按所选 UID 重建引擎。
    /// 重建失败返回 false，调用方必须停止继续推送音频，绝不退回系统默认输出设备。
    @discardableResult
    func ensureBoundToSelectedDevice() -> Bool {
        if isBoundToSelectedDevice { return true }
        guard let selectedDevice else { return false }
        AppLogger.shared.write(
            "AUDIO BINDING drift expected={\(CoreAudioDeviceCatalog.deviceDiagnostic(selectedDevice))} " +
                "actual={\(CoreAudioDeviceCatalog.deviceDiagnostic(currentOutputDevice()))}"
        )
        return configure(deviceUID: selectedDevice.uid)
    }

    /// Schedules the test tone and reports actual playback completion via `scheduleBuffer`'s
    /// `.dataPlayedBack` callback rather than a fixed timer. `completion` receives `true` only
    /// when the tone finished sounding; `false` if it was cut short (device torn down, real
    /// voice preempted it, etc.). Returns `false` immediately if scheduling never happened.
    @discardableResult
    func playTestTone(completion: @escaping (Bool) -> Void) -> Bool {
        guard isReadyForTestTone,
              let player,
              let buffer = makeBuffer(samples: TestToneGenerator.samples(sampleRate: sourceFormat.sampleRate))
        else { return false }
        player.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { callbackType in
            completion(callbackType == .dataPlayedBack)
        }
        return true
    }

    /// Flushes any buffer currently queued on the player node (including an in-flight test
    /// tone) so real RC003 voice audio scheduled right after this call is not delayed behind it.
    func cancelTestTone() {
        flushPlayer()
    }

    private func makeBuffer(samples: [Int16]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else { return nil }

        for index in samples.indices {
            channel[index] = AudioSampleMath.normalizedFloat(of: samples[index])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    @discardableResult
    func enqueue(samples: [Int16]) -> Bool {
        guard let player, engine?.isRunning == true, let buffer = makeBuffer(samples: samples) else {
            logRejectedWrite()
            return false
        }
        if rejectedWriteCount > 0 {
            AppLogger.shared.write("AUDIO WRITE resumed rejected_count=\(rejectedWriteCount) state={\(basicDiagnosticState())}")
            rejectedWriteCount = 0
        }
        player.scheduleBuffer(buffer)
        sessionStats.recordChunk(byteCount: 0)
        sessionStats.recordSamples(samples)
        return true
    }

    /// 开口前打一个播放计数基线，用于收尾时计算“本会话期间设备真的消费了多少帧”。
    /// 读不到就保持 nil：宁可让收尾报 `device_frames=-1`（未知），
    /// 也不要退回去用上一轮的旧值，算出一个看着正常其实无意义的数。
    func beginSession() {
        consumedBaseline = currentConsumedSampleTime()
    }

    /// 一次语音会话收尾：把“写了多少”和“设备真的消耗了多少”一起落日志。
    /// `device_frames` 不增长说明声卡那端根本没在拉数据（MiRemoteV IO 卡死的典型特征），
    /// 此时豆包会打开麦克风却只能读到静音。
    func endSession() {
        let consumed = consumedFramesSinceSessionStart()
        if !sessionStats.isEmpty || consumed > 0 {
            AppLogger.shared.write(
                "AUDIO WRITE SUMMARY " + sessionStats.summary(chunkLabel: "buffers") +
                    " device_frames=\(consumed) state={\(basicDiagnosticState())}"
            )
        }
        sessionStats.reset()
        consumedBaseline = nil
        flushPlayer()
    }

    private func currentConsumedSampleTime() -> Int64? {
        guard let player,
              let nodeTime = player.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return nil }
        return Int64(playerTime.sampleTime)
    }

    /// 本会话期间播放节点实际推出去的帧数。读不到基线或读不到计数一律返回 -1：
    /// 这个判据的价值全在“不骗人”，宁可报未知，也不要用上一轮的旧值算出一个看着正常的数。
    private func consumedFramesSinceSessionStart() -> Int64 {
        guard let baseline = consumedBaseline,
              let current = currentConsumedSampleTime()
        else { return -1 }
        return current >= baseline ? current - baseline : current
    }

    private func flushPlayer() {
        guard let player, engine?.isRunning == true else { return }
        player.stop()
        player.reset()
        guard AudioPlayerNodeSafety.play(player) else {
            AppLogger.shared.write("AUDIO ERROR player_restart_exception state={\(diagnosticState())}")
            stop()
            onConfigurationChange?()
            return
        }
    }

    func stop() {
        removeEngineConfigurationObserver()
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        selectedDevice = nil
        consumedBaseline = nil
    }

    private func observeConfigurationChanges(for engine: AVAudioEngine) {
        engineConfigurationGeneration &+= 1
        let generation = engineConfigurationGeneration
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            guard let self,
                  let engine,
                  self.engine === engine,
                  self.engineConfigurationGeneration == generation
            else { return }
            if self.isReadyForTestTone,
               let selectedDevice = self.selectedDevice,
               self.currentOutputDevice()?.id == selectedDevice.id {
                AppLogger.shared.write(
                    "AUDIO ENGINE configuration_ignored generation=\(generation) reason=still_bound"
                )
                return
            }
            AppLogger.shared.write("AUDIO ENGINE configuration_changed generation=\(generation)")
            self.onConfigurationChange?()
        }
    }

    private func removeEngineConfigurationObserver() {
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
        engineConfigurationGeneration &+= 1
    }

    func diagnosticState() -> String {
        let actualOutput = currentOutputDevice()
        let isBound: String
        if let selectedDevice, let actualOutput {
            isBound = selectedDevice.id == actualOutput.id ? "true" : "false"
        } else {
            isBound = "unknown"
        }
        return "\(basicDiagnosticState()) " +
            "actual_output={\(CoreAudioDeviceCatalog.deviceDiagnostic(actualOutput))} " +
            "bound_to_selected=\(isBound) \(CoreAudioDeviceCatalog.routeDiagnostic())"
    }

    private func basicDiagnosticState() -> String {
        "engine_running=\(engine?.isRunning == true) selected={\(CoreAudioDeviceCatalog.deviceDiagnostic(selectedDevice))}"
    }

    private func currentOutputDevice() -> AudioDeviceInfo? {
        guard let engine else { return nil }
        return Self.boundOutputDevice(of: engine)
    }

    /// 读取 AUHAL 真正在用的输出设备。`configure` 的绑定校验和每次开口前的漂移校验都以此为准，
    /// 不能信任 `selectedDevice`（那是我们“希望”的设备，不是引擎“实际”的设备）。
    private static func boundOutputDevice(of engine: AVAudioEngine) -> AudioDeviceInfo? {
        guard let outputUnit = engine.outputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        ) == noErr else { return nil }
        return CoreAudioDeviceCatalog.deviceInfo(for: deviceID)
    }

    private func logRejectedWrite() {
        rejectedWriteCount += 1
        sessionStats.recordRejection()
        let now = Date()
        guard now.timeIntervalSince(lastRejectedWriteLogDate) >= 1 else { return }
        lastRejectedWriteLogDate = now
        AppLogger.shared.write("AUDIO WRITE rejected count=\(rejectedWriteCount) state={\(basicDiagnosticState())}")
    }
}
