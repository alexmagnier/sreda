import SwiftUI

struct AgentsTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        if state.sessions.isEmpty {
            Text("Сессий Claude Code пока нет. Статусы появятся после установки хука (scripts/install.sh) и следующего сообщения агенту.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24).padding(.top, 60)
        } else {
            IslandScroll {
                VStack(spacing: 2) {
                    ForEach(state.sessions) { s in
                        Button { state.focus(s) } label: { AgentRow(session: s, isNew: state.unseen.contains(s.id)) }
                            .buttonStyle(RowButtonStyle())
                    }
                }
            }
        }
    }
}

struct AgentRow: View {
    let session: AgentSession
    var isNew = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StateDot(color: session.state.color, size: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project)
                        .font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if isNew {
                        HStack(spacing: 3) {
                            StateDot(color: .blue, size: 5)
                            Text("новое").font(.system(size: 10, weight: .medium)).foregroundStyle(.blue)
                        }
                    }
                }
                Text("\(session.name) · \(session.clientLabel)")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(session.state.label).foregroundStyle(session.state.color)
                    Text("· \(Fmt.relative(session.since))").foregroundStyle(.secondary)
                }
                .font(.system(size: 11.5)).lineLimit(1)
                if let m = session.message, !m.isEmpty {
                    Text(m).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}
