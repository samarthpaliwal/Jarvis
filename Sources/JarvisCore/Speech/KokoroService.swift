import Foundation

/// Runs the free on-device Kokoro voice server (installed by scripts/setup-kokoro.sh) as a child
/// process bound to 127.0.0.1, and reports when it's ready. Stopped when Jarvis quits.
@MainActor
public final class KokoroService: ObservableObject {
    @Published public private(set) var isReady = false
    @Published public private(set) var status = "not installed"
    public let port: Int
    public let directory: URL
    public var onReady: (() -> Void)?
    private var process: Process?
    private var restarts = 0

    public init(directory: URL = ConfigLocator.userConfigDirectory.deletingLastPathComponent().appendingPathComponent("kokoro"), port: Int = 8880) {
        self.directory = directory
        self.port = port
    }

    public var isInstalled: Bool {
        let fm = FileManager.default
        return ["/.venv/bin/python", "/kokoro_server.py", "/kokoro-v1.0.fp16.onnx", "/voices-v1.0.bin"].allSatisfy { fm.fileExists(atPath: directory.path + $0) }
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    public func start() {
        guard isInstalled else { status = "not installed (run scripts/setup-kokoro.sh)"; return }
        guard process == nil else { return }
        Task {
            // Reuse a server that is already running (e.g. left over from a previous launch).
            if await Self.healthy(baseURL) { markReady(); return }
            launch()
        }
    }

    private func launch() {
        let p = Process()
        p.executableURL = directory.appendingPathComponent(".venv/bin/python")
        p.arguments = [directory.appendingPathComponent("kokoro_server.py").path, directory.path, String(port)]
        p.currentDirectoryURL = directory
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.isReady = false
                JarvisLog.warn("Kokoro voice server exited (\(proc.terminationStatus))")
                if self.restarts < 3 { self.restarts += 1; self.launch() } else { self.status = "crashed" }
            }
        }
        do {
            try p.run()
            process = p
            status = "starting…"
            JarvisLog.info("Kokoro voice server starting (pid \(p.processIdentifier))")
        } catch {
            status = "failed: \(error.localizedDescription)"
            return
        }
        Task {
            for _ in 0..<60 {   // model load + warm-up takes a few seconds
                try? await Task.sleep(for: .milliseconds(500))
                if await Self.healthy(baseURL) { markReady(); return }
            }
            status = "didn't start"
            JarvisLog.error("Kokoro voice server didn't become ready")
        }
    }

    private func markReady() {
        isReady = true
        status = "ready"
        JarvisLog.info("Kokoro voice ready on 127.0.0.1:\(port)")
        onReady?()
    }

    public func stop() {
        restarts = 99
        process?.terminate()
        process = nil
        isReady = false
    }

    nonisolated static func healthy(_ base: URL) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 1
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        guard let (_, resp) = try? await URLSession(configuration: cfg).data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
