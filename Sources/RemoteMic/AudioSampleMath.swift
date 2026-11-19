import Foundation

/// 定点音频样本的通用数学。
///
/// 饱和钳制、增益钳制、峰值统计这三件事以前散在 `ATVVProtocol`、`AudioOutput`、
/// `XiaomiBluetoothBridge` 里各写一份。散着写的代价不是啰嗦，而是边界不一致：
/// `Int16.min` 取绝对值的正确结果是 32768（放不进 `Int16`），
/// 一处按 `Int16.max` 兜住、另一处忘了兜，同一段音频在两侧日志里就会得出不同的峰值，
/// 排查时反而互相矛盾。
///
/// 所以这里只放“和音频样本有关、且被两处以上用到”的纯函数，不放任何状态。
enum AudioSampleMath {
    /// `Int16` 可表示的取值范围，用作饱和钳制的上下界。
    static let int16LowerBound = Int(Int16.min)
    static let int16UpperBound = Int(Int16.max)

    /// 把 `Int16` 样本转成振幅量值（非负）。
    ///
    /// `Int16.min` 取负数会溢出，按 `Int16.max` 计——这是音频电平表的惯例，
    /// 也让“满幅负峰”和“满幅正峰”得到同一个读数。
    static func magnitude(of sample: Int16) -> Int {
        sample == Int16.min ? int16UpperBound : abs(Int(sample))
    }

    /// 一组样本的峰值量值；空数组返回 0。
    static func peakMagnitude(of samples: [Int16]) -> Int {
        var peak = 0
        for sample in samples {
            let magnitude = magnitude(of: sample)
            if magnitude > peak { peak = magnitude }
        }
        return peak
    }

    /// 把 `Int16` 样本归一化到 `[-1, 1]` 的 `Float`，供播放侧写缓冲使用。
    ///
    /// 以前这行换算直接写在 `AudioOutput.makeBuffer` 里；和 `magnitude` 放在一起，
    /// 是为了让「读峰值」和「写缓冲」用同一个满幅基准，不会一处除 `Int16.max`、
    /// 另一处除 `32768`。
    static func normalizedFloat(of sample: Int16) -> Float {
        Float(sample) / Float(int16UpperBound)
    }

    /// 把任意整数饱和到 `Int16` 范围内，用于浮点缩放后的落回。
    static func clampToInt16(_ value: Int) -> Int16 {
        Int16(min(int16UpperBound, max(int16LowerBound, value)))
    }

    /// 把任意整数饱和到闭区间内。
    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// 把增益钳制到可用的 ±24 dB 区间。
    ///
    /// `NaN` 与 `±Inf` 退化成 0 dB 而不是上限：设置里出现脏值时，
    /// 用户听到的原声音量比被放大 15 倍安全得多。
    static func clampGainDB(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(24, max(-24, value))
    }
}
