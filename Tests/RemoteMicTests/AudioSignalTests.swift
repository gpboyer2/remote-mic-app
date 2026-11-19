import Testing
@testable import RemoteMic

@Suite("Audio sample math")
struct AudioSampleMathTests {
    @Test func magnitudeTreatsMinimumAsFullScale() {
        // Int16.min 取绝对值会溢出成负数，必须按满幅计，否则峰值统计会漏掉负向满幅。
        #expect(AudioSampleMath.magnitude(of: Int16.min) == Int(Int16.max))
        #expect(AudioSampleMath.magnitude(of: Int16.max) == Int(Int16.max))
        #expect(AudioSampleMath.magnitude(of: 0) == 0)
        #expect(AudioSampleMath.magnitude(of: -1_234) == 1_234)
    }

    @Test func peakMagnitudeHandlesEmptyAndSilence() {
        #expect(AudioSampleMath.peakMagnitude(of: []) == 0)
        #expect(AudioSampleMath.peakMagnitude(of: [0, 0, 0]) == 0)
        #expect(AudioSampleMath.peakMagnitude(of: [100, -9_000, 42]) == 9_000)
        #expect(AudioSampleMath.peakMagnitude(of: [Int16.min]) == Int(Int16.max))
    }

    @Test func clampToInt16SaturatesBothEnds() {
        #expect(AudioSampleMath.clampToInt16(0) == 0)
        #expect(AudioSampleMath.clampToInt16(32_767) == Int16.max)
        #expect(AudioSampleMath.clampToInt16(32_768) == Int16.max)
        #expect(AudioSampleMath.clampToInt16(-32_768) == Int16.min)
        #expect(AudioSampleMath.clampToInt16(-99_999) == Int16.min)
        #expect(AudioSampleMath.clampToInt16(99_999) == Int16.max)
    }

    @Test func clampKeepsValueInsideRange() {
        #expect(AudioSampleMath.clamp(5, to: 0...88) == 5)
        #expect(AudioSampleMath.clamp(-3, to: 0...88) == 0)
        #expect(AudioSampleMath.clamp(200, to: 0...88) == 88)
    }

    @Test func gainClampRejectsNonFiniteAndCapsAtTwentyFourDB() {
        #expect(AudioSampleMath.clampGainDB(.nan) == 0)
        #expect(AudioSampleMath.clampGainDB(.infinity) == 0)
        #expect(AudioSampleMath.clampGainDB(-(.infinity)) == 0)
        #expect(AudioSampleMath.clampGainDB(30) == 24)
        #expect(AudioSampleMath.clampGainDB(-30) == -24)
        #expect(AudioSampleMath.clampGainDB(6) == 6)
    }
}

@Suite("Audio session stats")
struct AudioSessionStatsTests {
    @Test func freshStatsReportEmpty() {
        #expect(AudioSessionStats().isEmpty)
    }

    @Test func recordingChunksAndSamplesAccumulates() {
        var stats = AudioSessionStats()
        stats.recordChunk(byteCount: 120)
        stats.recordFrame()
        stats.recordSamples([0, 100, -200])
        #expect(stats.chunks == 1)
        #expect(stats.bytes == 120)
        #expect(stats.frames == 1)
        #expect(stats.samples == 3)
        #expect(stats.peak == 200)
        #expect(!stats.isEmpty)
    }

    @Test func peakNeverDecreases() {
        var stats = AudioSessionStats()
        stats.recordSamples([9_000])
        stats.recordSamples([10])
        #expect(stats.peak == 9_000)
    }

    @Test func rejectionIsCountedSeparately() {
        var stats = AudioSessionStats()
        stats.recordRejection()
        #expect(stats.rejected == 1)
        #expect(stats.chunks == 0)
        #expect(!stats.isEmpty)
    }

    @Test func resetReturnsToPristineState() {
        var stats = AudioSessionStats()
        stats.recordChunk(byteCount: 7)
        stats.recordSamples([5])
        stats.recordRejection()
        stats.reset()
        #expect(stats == AudioSessionStats())
        #expect(stats.isEmpty)
    }

    @Test func summaryUsesRequestedChunkLabel() {
        var stats = AudioSessionStats()
        stats.recordChunk(byteCount: 4)
        let packets = stats.summary(chunkLabel: "packets")
        #expect(packets.contains("packets=1"))
        #expect(packets.contains("bytes=4"))
        // 声卡侧同一结构体改用 buffers 标签，字段名之外的格式必须完全一致。
        let buffers = stats.summary(chunkLabel: "buffers")
        #expect(buffers.contains("buffers=1"))
        #expect(buffers.contains("bytes=4"))
    }
}
