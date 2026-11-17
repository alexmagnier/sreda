import AppKit
import SwiftUI

struct SystemTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        let s = state.system
        let frac = s.memoryTotalBytes > 0 ? Double(s.memoryUsedBytes) / Double(s.memoryTotalBytes) : 0
        IslandScroll {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Память").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(Fmt.bytes(s.memoryUsedBytes)) из \(Fmt.bytes(s.memoryTotalBytes))")
                            .font(.system(size: 12).monospacedDigit())
                    }
                    MemoryBar(fraction: frac, color: s.memoryPressure.color, height: 6)
                    HStack(spacing: 4) {
                        StateDot(color: s.memoryPressure.color, size: 6)
                        Text("давление: \(Fmt.pressureWord(s.memoryPressure)) · сжато \(Fmt.bytes(s.memoryCompressedBytes))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 12))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    StatTile(title: "CPU", value: Fmt.percent(s.cpuPercent))
                    StatTile(title: "GPU", value: Fmt.percent(s.gpuPercent), tint: (s.gpuPercent ?? 0) > 60 ? .orange : nil)
                    StatTile(title: "Нагрев", value: s.thermal.label,
                             tint: s.thermal == .nominal ? nil : (s.thermal == .fair ? .yellow : .orange))
                    StatTile(title: "Диск", value: s.diskFreeBytes.map { Fmt.bytes($0, unit: false) + " ГБ" } ?? "—")
                }

                HStack(alignment: .top, spacing: 10) {
                    processList("Топ по CPU", state.processesByCPU) { Fmt.percent($0.cpuPercent) }
                    processList("Топ по памяти", state.processesByMemory) { Fmt.bytesShort($0.memoryBytes) }
                }

                lmCard
            }
        }
    }

    private func confirmAndUnload() {
        if Self.localClaudeSessionRunning() {
            let a = NSAlert()
            a.messageText = "Идёт локальная сессия claude-local — выгрузка модели её прервёт. Выгрузить?"
            a.addButton(withTitle: "Выгрузить")
            a.addButton(withTitle: "Отмена")
            a.alertStyle = .warning
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        state.unloadModel()
    }

    /// True if a `sandbox-exec ... .claude-local` process is running.
    static func localClaudeSessionRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        return out.split(separator: "\n").contains { $0.contains("sandbox-exec") && $0.contains(".claude-local") }
    }

    private func processList(_ title: String, _ rows: [ProcessRow], value: @escaping (ProcessRow) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title)
            ForEach(rows.prefix(6)) { r in
                HStack(spacing: 4) {
                    Text(r.name).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 2)
                    Text(value(r)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var lmCard: some View {
        let lm = state.lmstudio
        return HStack(spacing: 10) {
            Image(systemName: "cpu").font(.system(size: 16)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("LM Studio").font(.system(size: 12, weight: .semibold))
                Text(!lm.serverUp ? "LM Studio не запущен"
                     : lm.loadedModels.isEmpty ? "модель не загружена"
                     : lm.loadedModels.joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if lm.serverUp && !lm.loadedModels.isEmpty {
                Button("Выгрузить модель") { confirmAndUnload() }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(state.unloading)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 12))
    }
}
