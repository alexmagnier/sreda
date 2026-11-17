// Composition root: real services by default; ISLAND_FAKE=1 (or --render) uses in-memory fakes.
import Foundation

@MainActor
func makeAppState() -> AppState {
    if ProcessInfo.processInfo.environment["ISLAND_FAKE"] == "1" {
        return makeFakeAppState()
    }
    return AppState(
        stats: SystemStats(),
        processes: ProcessSampler(),
        windows: WindowService(),
        sessions: SessionStore(),
        lms: LMStudioClient(),
        permissions: { Permissions.current() }
    )
}
