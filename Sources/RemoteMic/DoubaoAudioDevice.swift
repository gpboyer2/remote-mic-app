import Foundation

enum DoubaoAudioDevicePolicy {
    static let deviceUID = "MiRemoteV2ch_UID"
    static let deviceName = "MiRemoteV 2ch"

    // Fallback-compatible virtual audio devices (macOS 13 适配)
    private static let compatibleDevices: [(uid: String, name: String)] = [
        (uid: "MiRemoteV2ch_UID", name: "MiRemoteV 2ch"),
        (uid: "OrayVirtualAudioDevice", name: "OrayVirtualAudioDevice"),
        (uid: "BlackHole2ch", name: "BlackHole 2ch")
    ]

    static func device(in devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        for candidate in compatibleDevices {
            if let match = devices.first(where: { device in
                device.uid == candidate.uid
                    || device.name == candidate.name
                    || device.uid.hasSuffix(candidate.uid)
                    || device.name.contains(candidate.name)
            }) {
                return match
            }
        }
        return nil
    }

    static func status(in devices: [AudioDeviceInfo]) -> LocalizedMessage {
        if let match = device(in: devices) {
            return LocalizedMessage("已检测到 %@（豆包兼容）", arguments: [match.name])
        }
        return LocalizedMessage("未检测到兼容的虚拟音频设备")
    }
}
