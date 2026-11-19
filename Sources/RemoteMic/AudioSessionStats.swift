import Foundation

/// 一次语音会话的音频统计。
///
/// 蓝牙侧用它统计“遥控器发来了什么”，声卡侧用它统计“写进去了什么”。
/// 两侧共用同一个结构和同一组字段名，日志才能逐字段对照——这正是以前缺的东西：
/// 只有 `ATVV STREAM START/STOP` 时，谁也无法判断到底是没收到声音，
/// 还是收到了却写不进虚拟声卡。三个判据由此分开：
///
/// - `chunks == 0`：遥控器根本没发音频，问题在蓝牙链路或遥控器侧；
/// - `peak == 0`：数据到了但全程静音，问题在采集/解码；
/// - 写了但设备不消费：虚拟声卡那头卡住，豆包打开麦克风也只能读到静音。
///
/// 本类型不持有设备、不写日志，纯粹累计数值，方便单测。
struct AudioSessionStats: Equatable {
    /// 收到的数据块数。蓝牙侧是音频包数，声卡侧是写入的缓冲区数。
    private(set) var chunks = 0
    /// 累计字节数；声卡侧不做字节统计时为 0。
    private(set) var bytes = 0
    /// 凑够并解码的完整帧数；声卡侧不适用时为 0。
    private(set) var frames = 0
    /// 累计样本数。
    private(set) var samples = 0
    /// 会话内峰值量值（0…32767）。
    private(set) var peak = 0
    /// 被拒绝的次数（例如引擎未运行时的写入）。
    private(set) var rejected = 0

    var isEmpty: Bool {
        chunks == 0 && bytes == 0 && frames == 0 && samples == 0 && peak == 0 && rejected == 0
    }

    mutating func reset() {
        self = AudioSessionStats()
    }

    /// 记一个数据块。`byteCount` 只有蓝牙侧需要，声卡侧传 0 即可。
    mutating func recordChunk(byteCount: Int) {
        chunks += 1
        bytes += byteCount
    }

    /// 记一帧解码结果或一次写入的样本。
    mutating func recordSamples(_ buffer: [Int16]) {
        samples += buffer.count
        let magnitude = AudioSampleMath.peakMagnitude(of: buffer)
        if magnitude > peak { peak = magnitude }
    }

    /// 记一帧（不含样本）——蓝牙侧区分“凑够帧”和“帧内样本”时用。
    mutating func recordFrame() {
        frames += 1
    }

    mutating func recordRejection() {
        rejected += 1
    }

    /// 输出给日志的键值串。两侧字段名对齐，`chunkLabel` 让蓝牙侧写 `packets`、
    /// 声卡侧写 `buffers`，读日志时不用再猜哪个数字对应哪个含义。
    func summary(chunkLabel: String) -> String {
        "\(chunkLabel)=\(chunks) bytes=\(bytes) frames=\(frames) " +
            "samples=\(samples) peak=\(peak) rejected=\(rejected)"
    }
}
