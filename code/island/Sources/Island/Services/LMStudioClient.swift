import Foundation

final class LMStudioClient: LMStudioControlling {
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        c.timeoutIntervalForResource = 1.5
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private struct ModelList: Decodable {
        struct Item: Decodable { let id: String; let state: String?; let type: String? }
        let data: [Item]
    }

    func status() async -> LMStudioStatus {
        // /api/v0/models has a per-model "state"; /v1/models lists every DOWNLOADED model when JIT is on.
        guard let url = URL(string: "http://127.0.0.1:1234/api/v0/models") else { return LMStudioStatus() }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return LMStudioStatus() }
            let list = try JSONDecoder().decode(ModelList.self, from: data)
            let loaded = list.data.filter { $0.state == "loaded" && $0.type != "embeddings" }.map(\.id)
            return LMStudioStatus(serverUp: true, loadedModels: loaded)
        } catch {
            return LMStudioStatus()
        }
    }

    func unloadAll() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let lms = NSHomeDirectory() + "/.lmstudio/bin/lms"
                guard FileManager.default.isExecutableFile(atPath: lms) else { cont.resume(returning: false); return }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: lms)
                p.arguments = ["unload", "--all"]
                var env = ProcessInfo.processInfo.environment
                env.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
                p.environment = env
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                let done = DispatchSemaphore(value: 0)
                p.terminationHandler = { _ in done.signal() }
                do { try p.run() } catch { cont.resume(returning: false); return }
                if done.wait(timeout: .now() + 20) == .timedOut {
                    p.terminate()
                    cont.resume(returning: false)
                } else {
                    cont.resume(returning: p.terminationStatus == 0)
                }
            }
        }
    }
}
