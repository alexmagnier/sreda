import AppKit
import SwiftUI

extension AgentState {
    var color: Color {
        switch self {
        case .working: return .green
        case .idle: return .blue
        case .waiting: return .orange
        case .error: return .red
        }
    }
}

extension MemoryPressure {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }
}

struct StateDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct MemoryBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.18))
                Capsule().fill(color).frame(width: max(height, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var tint: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint ?? Color.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 10))
    }
}

struct PermissionBanner: View {
    let text: String
    let button: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.orange).font(.system(size: 14))
            Text(text).font(.system(size: 11.5)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action)
                .buttonStyle(.glass).controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 10))
    }
}

struct AppIcon: View {
    let pid: pid_t
    var size: CGFloat = 18
    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app").frame(width: size, height: size).foregroundStyle(.secondary)
        }
    }
}

/// Row hover highlight without animation loops.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color.primary.opacity(0.10) : Color.clear, in: .rect(cornerRadius: 9))
    }
}

/// ScrollView that degrades to a plain stack when rendered offscreen (ImageRenderer draws no ScrollView content).
struct IslandScroll<Content: View>: View {
    @Environment(\.islandOffscreen) private var offscreen
    @ViewBuilder let content: () -> Content
    var body: some View {
        if offscreen {
            content().frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { content() }.scrollIndicators(.hidden)
        }
    }
}
