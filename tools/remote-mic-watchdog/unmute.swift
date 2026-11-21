// miremote-unmute —— 查看并解除虚拟声卡的静音状态。
//
// 为什么需要它：虚拟声卡被静音时，写进去的语音读不出来，
// 豆包会「浮窗正常、联网正常、就是一个字不出」。这是排查该现象的第一步，
// 不要在 ffmpeg、AUHAL、驱动 ABI 上绕。
//
// 用法：
//   miremote-unmute [UID] [input|output|both]
// 输出（供 mute-guard.sh 判定，格式勿改）：
//   input: before=1 set=ok after=0
import CoreAudio
import Foundation

@main
enum UnmuteMain {
    static func main() {
        let arguments = CommandLine.arguments
        let uid = arguments.count > 1 ? arguments[1] : "MiRemoteV2ch_UID"
        let target = arguments.count > 2 ? arguments[2] : "both"

        guard let device = CoreAudioDevice.id(forUID: uid) else {
            print("not_found")
            exit(2)
        }

        let scopes: [AudioObjectPropertyScope]
        switch target {
        case "input": scopes = [kAudioObjectPropertyScopeInput]
        case "output": scopes = [kAudioObjectPropertyScopeOutput]
        default: scopes = [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput]
        }

        for scope in scopes {
            let name = CoreAudioDevice.scopeName(scope)
            guard let before = CoreAudioDevice.mute(device, scope: scope) else {
                print("\(name): no mute property")
                continue
            }
            let status = CoreAudioDevice.setMute(false, scope: scope, of: device)
            let after = CoreAudioDevice.mute(device, scope: scope) ?? 9
            let result = status == noErr ? "ok" : "err_\(status)"
            print("\(name): before=\(before) set=\(result) after=\(after)")
        }
    }
}