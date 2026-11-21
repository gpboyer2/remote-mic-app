// miremote-probe —— 往虚拟声卡写一段极短测试音，用于验证它是否还在环回。
// 只负责「写」，读回与判定交给调用方（ffmpeg / AVAudioEngine），保持单一职责。
// 设备查找与静音读写统一走 CoreAudioDevice，不再自带一份实现。
import AVFoundation
import CoreAudio
import Foundation

@main
enum ProbeMain {
    static func main() {
        let arguments = CommandLine.arguments
        let uid = arguments.count > 1 ? arguments[1] : "MiRemoteV2ch_UID"
        let seconds = arguments.count > 2 ? (Double(arguments[2]) ?? 0.15) : 0.15
        let amplitude = arguments.count > 3 ? (Float(arguments[3]) ?? 0.25) : 0.25

        guard let device = CoreAudioDevice.id(forUID: uid) else {
            print("{\"ok\":false,\"error\":\"device_not_found\"}")
            exit(2)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        var deviceID = device
        let setResult = AudioUnitSetProperty(
            engine.outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setResult == noErr else {
            print("{\"ok\":false,\"error\":\"set_device_\(setResult)\"}")
            exit(3)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("{\"ok\":false,\"error\":\"start_failed\"}")
            exit(4)
        }
        player.play()

        let frames = AVAudioFrameCount(Double(16000) * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] =
                Float(sin(2.0 * Double.pi * 1000.0 * Double(index) / 16000.0)) * amplitude
        }
        buffer.frameLength = frames
        player.scheduleBuffer(buffer)
        Thread.sleep(forTimeInterval: seconds + 0.05)
        engine.stop()
        print("{\"ok\":true,\"seconds\":\(seconds)}")
    }
}