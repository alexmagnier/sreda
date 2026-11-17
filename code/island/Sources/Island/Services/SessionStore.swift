import Darwin
import Foundation

/// Merges Claude Code's own `<root>/sessions/<pid>.json` (busy|idle, liveness by pid) with the hook overlay
/// `<root>/island/waiting/<sessionId>.json` (waiting / error). Never deletes Claude Code's files.
final class SessionStore: SessionWatching {
    private struct Base: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String?
        let entrypoint: String?
        let name: String?
        let status: String?
        let statusUpdatedAt: Double?
        let kind: String?
    }
    private struct Overlay: Decodable {
        let waiting: Bool?
        let error: Bool?
        let ts_ms: Double?
        let message: String?
    }

    private let queue = DispatchQueue(label: "island.sessions", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var timer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var onChange: (([AgentSession]) -> Void)?
    private var lastDelivered: [AgentSession]?
    private var livePids: [Int32] = []

    private let overlayMaxAge: TimeInterval = 24 * 3600

    private var roots: [String] {
        let h = NSHomeDirectory()
        return ["\(h)/.claude", "\(h)/.claude-local", "\(h)/.claude-local-net"]
    }

    func start(onChange: @escaping ([AgentSession]) -> Void) {
        queue.async {
            self.stopLocked()
            self.onChange = onChange
            let fm = FileManager.default
            try? fm.createDirectory(atPath: self.roots[0] + "/island/waiting", withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            for root in self.roots {
                for dir in [root + "/sessions", root + "/island/waiting"] where fm.fileExists(atPath: dir) {
                    let fd = open(dir, O_EVTONLY)
                    guard fd >= 0 else { continue }
                    let src = DispatchSource.makeFileSystemObjectSource(
                        fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: self.queue)
                    src.setEventHandler { [weak self] in self?.scheduleDeliver() }
                    src.setCancelHandler { close(fd) }
                    src.resume()
                    self.sources.append(src)
                }
            }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(3))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                // cheap: only kill(pid,0) per known session; re-read files only if somebody died
                if self.livePids.contains(where: { !Self.isAlive($0) }) { self.deliver() }
            }
            t.resume()
            self.timer = t
            self.deliver()
        }
    }

    func stop() { queue.async { self.stopLocked() } }

    private func stopLocked() {
        sources.forEach { $0.cancel() }
        sources = []
        timer?.cancel(); timer = nil
        debounce?.cancel(); debounce = nil
        onChange = nil
        lastDelivered = nil
    }

    func reload() -> [AgentSession] { queue.sync { scan() } }

    private func scheduleDeliver() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.deliver() }
        debounce = w
        queue.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func deliver() {
        guard let cb = onChange else { return }
        let list = scan()
        if let last = lastDelivered, last == list { return }
        lastDelivered = list
        DispatchQueue.main.async { cb(list) }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// Must run on `queue`.
    private func scan() -> [AgentSession] {
        let fm = FileManager.default
        let dec = JSONDecoder()

        // overlays: newest per sessionId across roots
        var overlays: [String: (o: Overlay, path: String)] = [:]
        var overlayPaths: [String: [String]] = [:]
        for root in roots {
            let dir = root + "/island/waiting"
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".json") {
                let path = dir + "/" + n
                guard let d = fm.contents(atPath: path), d.count < 65536, let o = try? dec.decode(Overlay.self, from: d) else { continue }
                let sid = String(n.dropLast(5))
                overlayPaths[sid, default: []].append(path)
                if (overlays[sid]?.o.ts_ms ?? -1) < (o.ts_ms ?? 0) { overlays[sid] = (o, path) }
            }
        }

        var result: [AgentSession] = []
        var liveIDs = Set<String>()
        var pids: [Int32] = []
        for root in roots {
            let dir = root + "/sessions"
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".json") {      // skips *.key
                guard let d = fm.contents(atPath: dir + "/" + n), d.count < 65536,
                      let b = try? dec.decode(Base.self, from: d) else { continue }
                if (b.kind ?? "interactive") != "interactive" { continue }
                let ep = b.entrypoint ?? ""
                if ep.hasPrefix("sdk") { continue }
                guard Self.isAlive(b.pid) else { continue }
                pids.append(b.pid)
                liveIDs.insert(b.sessionId)
                let baseMs = b.statusUpdatedAt ?? 0
                var state: AgentState = (b.status == "busy") ? .working : .idle
                var sinceMs = baseMs
                var message: String?
                if let ov = overlays[b.sessionId]?.o, let ts = ov.ts_ms, ts > baseMs,
                   ov.waiting == true || ov.error == true {
                    state = ov.waiting == true ? .waiting : .error
                    sinceMs = ts
                    message = (ov.message?.isEmpty ?? true) ? nil : ov.message
                }
                let cwd = b.cwd ?? ""
                result.append(AgentSession(
                    id: b.sessionId, pid: b.pid, name: b.name ?? "", project: (cwd as NSString).lastPathComponent,
                    cwd: cwd, entrypoint: ep, state: state,
                    since: Date(timeIntervalSince1970: sinceMs / 1000), message: message))
            }
        }
        livePids = pids

        // prune stale overlays (our own files only): >24 h old and no live session
        let now = Date().timeIntervalSince1970 * 1000
        for (sid, paths) in overlayPaths where !liveIDs.contains(sid) {
            for p in paths {
                let ts = overlays[sid]?.o.ts_ms ?? 0
                if now - ts > overlayMaxAge * 1000 { try? fm.removeItem(atPath: p) }
            }
        }
        return result
    }
}
