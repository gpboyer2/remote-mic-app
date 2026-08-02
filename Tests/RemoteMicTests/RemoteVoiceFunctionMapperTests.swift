import Testing
@testable import RemoteMic

@Suite("RC003 hardware Fn mapping")
struct RemoteVoiceFunctionMapperTests {
    @Test func mapsVoiceKeyAndPreservesConfirmOutsideHandsFreeSession() {
        let unrelated = HIDUsageMapping(
            source: 0x0000_0007_0000_0004,
            destination: 0x0000_0007_0000_0005
        )
        let stale = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source,
            destination: 0x0000_0007_0000_00E1
        )
        let originalConfirm = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.handsFreeCancelKey.source,
            destination: 0x0000_0007_0000_0029
        )

        #expect(
            RemoteVoiceFunctionMappingPolicy.applying(
                to: [unrelated, stale, originalConfirm],
                originalConfirmMapping: originalConfirm,
                cancelWithConfirmKey: false
            ) == [
                unrelated,
                RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
                originalConfirm,
            ]
        )
    }

    @Test func handsFreeSessionMapsConfirmToHardwareRightControl() {
        let unrelated = HIDUsageMapping(
            source: 0x0000_0007_0000_0004,
            destination: 0x0000_0007_0000_0005
        )
        let originalConfirm = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.handsFreeCancelKey.source,
            destination: 0x0000_0007_0000_0029
        )
        #expect(
            RemoteVoiceFunctionMappingPolicy.applying(
                to: [unrelated, originalConfirm],
                originalConfirmMapping: originalConfirm,
                cancelWithConfirmKey: true
            ) == [
                unrelated,
                RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
                RemoteVoiceFunctionMappingPolicy.handsFreeCancelKey,
            ]
        )
    }

    @Test func voiceMappingIsIdempotentAndRoundTripsItsProperty() {
        let mapping = RemoteVoiceFunctionMappingPolicy.remoteVoiceKey
        #expect(RemoteVoiceFunctionMappingPolicy.applying(
            to: [mapping],
            originalConfirmMapping: nil,
            cancelWithConfirmKey: false
        ) == [mapping])
        #expect(HIDUsageMapping(property: mapping.property) == mapping)
    }

    @Test func restorePreservesUnrelatedChangesMadeWhileRunning() {
        let originalVoice = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source,
            destination: 0x0000_0007_0000_00E1
        )
        let changedUnrelated = HIDUsageMapping(
            source: 0x0000_0007_0000_0004,
            destination: 0x0000_0007_0000_0006
        )
        let originalConfirm = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.handsFreeCancelKey.source,
            destination: 0x0000_0007_0000_0029
        )

        #expect(
            RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: originalVoice,
                originalConfirmMapping: originalConfirm,
                in: [
                    changedUnrelated,
                    RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
                    RemoteVoiceFunctionMappingPolicy.handsFreeCancelKey,
                ]
            ) == [changedUnrelated, originalVoice, originalConfirm]
        )
        #expect(
            RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: nil,
                originalConfirmMapping: nil,
                in: [
                    changedUnrelated,
                    RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
                    RemoteVoiceFunctionMappingPolicy.handsFreeCancelKey,
                ]
            ) == [changedUnrelated]
        )
    }
}
