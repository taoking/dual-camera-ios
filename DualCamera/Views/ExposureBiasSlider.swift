import SwiftUI

/// 右侧竖向曝光补偿滑杆，兼作 AE/AF 锁定状态指示。
/// 只在设备报告了有效补偿范围时才出现。
struct ExposureBiasSlider: View {
    let value: Float
    let range: ClosedRange<Float>
    let isLocked: Bool
    let onChange: (Float) -> Void

    private let trackHeight: CGFloat = 180

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                if isLocked {
                    Text("AE/AF\n锁定")
                        .font(.caption2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.yellow, in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityIdentifier("focus-lock-badge")
                }

                Image(systemName: "sun.max.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))

                track

                Text(String(format: "%+.1f", value))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(.black.opacity(0.28), in: Capsule())
            .padding(.trailing, 14)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("曝光补偿")
        .accessibilityValue(String(format: "%+.1f", value))
        .accessibilityIdentifier("exposure-slider")
    }

    private var track: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(width: 3)
                    .frame(maxWidth: .infinity)

                Circle()
                    .fill(.yellow)
                    .frame(width: 16, height: 16)
                    .frame(maxWidth: .infinity)
                    .offset(y: knobOffset(in: height))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onChange(bias(forY: gesture.location.y, in: height))
                    }
            )
        }
        .frame(width: 28, height: trackHeight)
    }

    /// 顶部对应最亮，与「向上调亮」的直觉一致，因此 y 与补偿值反向。
    private func knobOffset(in height: CGFloat) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return height / 2 }
        let ratio = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let usable = max(0, height - 16)
        return usable * CGFloat(1 - ratio)
    }

    private func bias(forY y: CGFloat, in height: CGFloat) -> Float {
        let usable = max(1, height - 16)
        let clamped = min(max(y - 8, 0), usable)
        let ratio = Float(1 - clamped / usable)
        return range.lowerBound + ratio * (range.upperBound - range.lowerBound)
    }
}
