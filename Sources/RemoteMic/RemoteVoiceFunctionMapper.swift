import Foundation
import IOKit.hid
import IOKit.hidsystem

struct HIDUsageMapping: Equatable {
    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"

    let source: UInt64
    let destination: UInt64

    init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }

    init?(property: [String: NSNumber]) {
        guard let source = property[Self.sourceKey],
              let destination = property[Self.destinationKey]
        else { return nil }
        self.source = source.uint64Value
        self.destination = destination.uint64Value
    }

    var property: [String: NSNumber] {
        [
            Self.sourceKey: NSNumber(value: source),
            Self.destinationKey: NSNumber(value: destination),
        ]
    }
}

enum RemoteVoiceFunctionMappingPolicy {
    /// RC003 语音键的原始 F5 usage 始终映射为真实右侧 Control。
    /// 豆包会忽略软件合成的右侧 Control，只有 HID 层的真实按键可靠。
    static let remoteVoiceKey = HIDUsageMapping(
        source: 0x0000_0007_0000_003E,
        destination: 0x0000_0007_0000_00E4
    )

    /// 免按会话中把确定键的 Return usage 临时映射为右侧 Control，
    /// 让确定键用真实硬件事件关闭豆包，同时不会泄漏 Return 提交。
    static let handsFreeCancelKey = HIDUsageMapping(
        source: 0x0000_0007_0000_0028,
        destination: 0x0000_0007_0000_00E4
    )

    /// 计算当前会话需要的唯一 HID 映射集合，并保留其他按键的运行时修改。
    static func applying(
        to existing: [HIDUsageMapping],
        originalConfirmMapping: HIDUsageMapping?,
        cancelWithConfirmKey: Bool
    ) -> [HIDUsageMapping] {
        var desired = existing.filter {
            $0.source != remoteVoiceKey.source && $0.source != handsFreeCancelKey.source
        }
        desired.append(remoteVoiceKey)
        if cancelWithConfirmKey {
            desired.append(handsFreeCancelKey)
        } else if let originalConfirmMapping {
            desired.append(originalConfirmMapping)
        }
        return desired
    }

    /// 应用退出时恢复语音键和确定键原有映射，不改动其他按键。
    static func restoring(
        originalVoiceMapping: HIDUsageMapping?,
        originalConfirmMapping: HIDUsageMapping?,
        in current: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        var restored = current.filter {
            $0.source != remoteVoiceKey.source && $0.source != handsFreeCancelKey.source
        }
        if let originalVoiceMapping {
            restored.append(originalVoiceMapping)
        }
        if let originalConfirmMapping {
            restored.append(originalConfirmMapping)
        }
        return restored
    }
}

final class RemoteVoiceFunctionMapper {
    private static let vendorID = 0x2717
    private static let productID = 0x32B8
    private static let mappingProperty = "UserKeyMapping" as CFString

    private struct OriginalMappings {
        let voiceKey: HIDUsageMapping?
        let confirmKey: HIDUsageMapping?
    }

    private var originalMappings: [UInt64: OriginalMappings] = [:]
    private(set) var isApplied = false
    private(set) var isCancelKeyApplied = false

    /// 按会话状态更新 RC003 的真实硬件映射。
    @discardableResult
    func apply(cancelWithConfirmKey: Bool) -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        var matchedCount = 0
        var appliedCount = 0

        for service in services where Self.isTarget(service) {
            matchedCount += 1
            guard let registryID = Self.registryID(service) else { continue }
            let current = Self.readMappings(service)
            if originalMappings[registryID] == nil {
                originalMappings[registryID] = OriginalMappings(
                    voiceKey: current.first {
                        $0.source == RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source
                    },
                    confirmKey: current.first {
                        $0.source == RemoteVoiceFunctionMappingPolicy.handsFreeCancelKey.source
                    }
                )
            }
            guard let original = originalMappings[registryID] else { continue }
            let desired = RemoteVoiceFunctionMappingPolicy.applying(
                to: current,
                originalConfirmMapping: original.confirmKey,
                cancelWithConfirmKey: cancelWithConfirmKey
            )
            if IOHIDServiceClientSetProperty(
                service,
                Self.mappingProperty,
                desired.map(\.property) as CFArray
            ) {
                appliedCount += 1
            }
        }

        isApplied = appliedCount > 0
        isCancelKeyApplied = isApplied && cancelWithConfirmKey
        AppLogger.shared.write(
            "VOICE FN MAPPING applied=\(isApplied) matched=\(matchedCount) " +
                "confirm_to_right_control=\(isCancelKeyApplied)"
        )
        return isApplied
    }

    /// 应用停止时恢复 RC003 原有映射。
    func restore() {
        guard !originalMappings.isEmpty else {
            isApplied = false
            isCancelKeyApplied = false
            return
        }

        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        var restoredCount = 0

        for service in services where Self.isTarget(service) {
            guard let registryID = Self.registryID(service),
                  let original = originalMappings[registryID]
            else { continue }
            let restored = RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: original.voiceKey,
                originalConfirmMapping: original.confirmKey,
                in: Self.readMappings(service)
            )
            if IOHIDServiceClientSetProperty(
                service,
                Self.mappingProperty,
                restored.map(\.property) as CFArray
            ) {
                restoredCount += 1
            }
        }

        originalMappings.removeAll()
        isApplied = false
        isCancelKeyApplied = false
        AppLogger.shared.write("VOICE FN MAPPING restored=\(restoredCount)")
    }

    private static func isTarget(_ service: IOHIDServiceClient) -> Bool {
        let vendor = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDVendorIDKey as CFString
        ) as? NSNumber
        let product = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDProductIDKey as CFString
        ) as? NSNumber
        return vendor?.intValue == vendorID && product?.intValue == productID
    }

    private static func registryID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    private static func readMappings(_ service: IOHIDServiceClient) -> [HIDUsageMapping] {
        let properties = IOHIDServiceClientCopyProperty(
            service,
            mappingProperty
        ) as? [[String: NSNumber]] ?? []
        return properties.compactMap(HIDUsageMapping.init(property:))
    }
}
