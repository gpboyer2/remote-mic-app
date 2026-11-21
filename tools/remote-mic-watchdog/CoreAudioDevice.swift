import CoreAudio
import Foundation

/// CoreAudio 设备访问的公共封装。
///
/// 约定：调用方（探针、静音工具、守卫脚本）只描述「要做什么」，
/// 设备枚举、UID 换算、静音读写一律走这里，避免每个小工具各写一份。
/// 之前 `probe.swift` 与 `unmute.swift` 就各自复制了一份 `deviceID(forUID:)`，
/// 改一处漏一处。新增工具请直接复用本模块，不要再复制。
enum CoreAudioDevice {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let globalScope = AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal)
    static let mainElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)

    /// 当前系统里的全部音频设备 ID。
    static func allIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: globalScope,
            mElement: mainElement
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    /// 按 UID 精确查找设备。找不到返回 nil，调用方负责报错。
    static func id(forUID uid: String) -> AudioDeviceID? {
        for id in allIDs() where self.uid(of: id) == uid {
            return id
        }
        return nil
    }

    static func uid(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: globalScope,
            mElement: mainElement
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value as String
    }

    /// 设备在该作用域下是否支持 mute 属性。虚拟声卡的输入侧常常支持，物理设备未必。
    static func hasMute(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = muteAddress(scope)
        return AudioObjectHasProperty(id, &address)
    }

    /// 读静音状态。属性不存在返回 nil。
    static func mute(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32? {
        var address = muteAddress(scope)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    /// 写静音状态，返回 OSStatus 由调用方判定成败。
    @discardableResult
    static func setMute(_ muted: Bool, scope: AudioObjectPropertyScope, of id: AudioDeviceID) -> OSStatus {
        var address = muteAddress(scope)
        guard AudioObjectHasProperty(id, &address) else { return kAudioHardwareUnknownPropertyError }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        )
    }

    /// 日志里用的作用域名，保证各工具输出一致。
    static func scopeName(_ scope: AudioObjectPropertyScope) -> String {
        scope == kAudioObjectPropertyScopeInput ? "input" : "output"
    }

    private static func muteAddress(_ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: mainElement
        )
    }
}