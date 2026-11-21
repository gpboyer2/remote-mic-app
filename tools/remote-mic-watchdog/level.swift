// miremote-level —— 从虚拟声卡录一小段，报峰值电平。
//
// 为什么要另起一个工具，而不是继续用 ffmpeg：
// ffmpeg 的 avfoundation 输入对这两个虚拟设备一律给 -91dB（静音期间的假阴性会被
// 当成"环回坏了"，正常时也一样），于是 watchdog 在环回健康时也判失败，
// 一旦装了 root helper 就会无意义地杀驱动宿主 / 重启 coreaudiod。
// 豆包走的是 AVAudioEngine，这里就用同一条路径测，量到的才是它实际读到的。
//
// 输出单行 JSON，便于脚本取值：
//   {"ok":true,"frames":139200,"peak":0.137,"db":-17.3}
import AVFoundation
import CoreAudio
import Foundation

@main
enum LevelMain {
    static func main() {
        let arguments = CommandLine.arguments
        let uid = arguments.count > 1 ? arguments[1] : "MiRemoteV2ch_UID"
        let seconds = arguments.count > 2 ? (Double(arguments[2]) ?? 3.0) : 3.0

        guard let device = CoreAudioDevice.id(forUID: uid) else {
            print("{\"ok\":false,\"error\":\"device_not_found\"}")
            exit(2)
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        var deviceID = device
        let bindResult = AudioUnitSetProperty(
            input.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard bindResult == noErr else {
            print("{\"ok\":false,\"error\":\"set_device_\(bindResult)\"}")
            exit(3)
        }

        let format = input.inputFormat(forBus: 0)
        var peak: Float = 0
        var frames: AVAudioFrameCount = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            frames += buffer.frameLength
            guard let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for index in 0..<count {
                    let magnitude = abs(samples[index])
                    if magnitude > peak { peak = magnitude }
                }
            }
        }

        do {
            try engine.start()
        } catch {
            print("{\"ok\":false,\"error\":\"start_failed\"}")
            exit(4)
        }
        Thread.sleep(forTimeInterval: seconds)
        engine.stop()

        let db = peak > 0 ? 20 * log10(peak) : -180
        print(String(format: "{\"ok\":true,\"frames\":%u,\"peak\":%.5f,\"db\":%.1f}", frames, peak, db))
    }
}