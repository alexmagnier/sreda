import AppKit
import SwiftUI

/// Collapsed island: glass capsule around the notch. The middle (notch) stays empty.
struct PillView: View {
    @ObservedObject var state: AppState
    let notchWidth: CGFloat
    let height: CGFloat
    /// false when the pill sits inside an AppKit NSGlassEffectView (live app): the native glass view is
    /// ~3× cheaper than SwiftUI .glassEffect for an always-on element (measured 0.5% vs 1.6% CPU).
    var drawsGlass = true
    static let sideWidth: CGFloat = 84
    @Environment(\.islandOffscreen) private var offscreen

    var body: some View {
        let c = state.counts
        ZStack {
            if offscreen {
                Capsule().fill(Color.black.opacity(0.55))
            } else if drawsGlass {
                Capsule().fill(.clear).glassEffect(.regular, in: .capsule)   // not .interactive(): it re-renders continuously (measured 2% CPU idle)
            }
            if let h = state.highlight {
                Capsule().strokeBorder(h.color.opacity(0.9), lineWidth: 1.5)
                    .shadow(color: h.color.opacity(0.8), radius: 8)
                    .transition(.opacity)
            }
            HStack(spacing: 0) {
                memory
                    .frame(width: Self.sideWidth, alignment: .leading)
                    .padding(.leading, 10)
                Color.clear.frame(width: notchWidth)
                agents(c)
                    .frame(width: Self.sideWidth, alignment: .trailing)
                    .padding(.trailing, 10)
            }
        }
        .frame(width: notchWidth + 2 * Self.sideWidth, height: height)
        .animation(.easeInOut(duration: 0.4), value: state.highlight)
        .contentShape(Capsule())
        .contextMenu {
            Button("Скрыть на час") { state.hide(for: 3600) }
            Button("Скрыть на 3 часа") { state.hide(for: 3 * 3600) }
            Button("Скрыть до утра") { state.hideUntilMorning() }
            Divider()
            Text("Вернуть — значок островка в строке меню")
        }
    }

    private var memory: some View {
        let s = state.system
        let frac = s.memoryTotalBytes > 0 ? Double(s.memoryUsedBytes) / Double(s.memoryTotalBytes) : 0
        let total = Int((Double(s.memoryTotalBytes) / 1_073_741_824).rounded())
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(Fmt.bytes(s.memoryUsedBytes, unit: false))/\(total) ГБ")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.8)
            MemoryBar(fraction: frac, color: s.memoryPressure.color, height: 3)
                .frame(width: 60)
        }
        .help("Занято оперативной памяти: \(Fmt.bytes(s.memoryUsedBytes, unit: false)) из \(total) ГБ. Полоска краснеет, когда памяти не хватает.")
    }

    private func agents(_ c: (working: Int, ready: Int, waiting: Int)) -> some View {
        HStack(spacing: 5) {
            if state.system.thermal == .serious || state.system.thermal == .critical {
                Image(systemName: "flame.fill").font(.system(size: 10)).foregroundStyle(.orange)
            }
            if c.working > 0 { counter(StateDot(color: .green, size: 6), c.working) }
            if c.ready > 0 {
                counter(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.blue), c.ready)
            }
            if c.waiting > 0 {
                counter(Text("!").font(.system(size: 11, weight: .heavy)).foregroundStyle(.orange), c.waiting)
            }
            if c.working + c.ready + c.waiting == 0 {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .help("Агенты Claude Code: ● работают — \(c.working), ✓ закончили, не просмотрено — \(c.ready), ! ждут тебя — \(c.waiting). Клик — список. Правый клик — скрыть.")
    }

    private func counter<L: View>(_ label: L, _ n: Int) -> some View {
        HStack(spacing: 2) {
            label
            Text("\(n)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        }
    }
}
