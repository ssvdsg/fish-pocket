import Foundation
import NodeMobile

/// Runs Node (`nodejs-project/main.mjs`, which hosts the DSH engine in a worker)
/// on a dedicated thread and publishes the web URL once `dsh web` is listening.
/// Node can be started only once per process, so this is a singleton for the
/// app's lifetime; engine restarts happen inside it and show up here as a new
/// `generation`, which tells the web view to reload.
@MainActor
final class NodeEngine: ObservableObject {
    enum Phase: Equatable {
        case starting
        case running(URL, generation: Int)
        case exited(Int32)
        /// The processor lacks the instructions the engine's prebuilt code uses (see `cpuRunsEngine`),
        /// so it is not started: starting it would crash the app on launch.
        case unsupported
    }

    static let shared = NodeEngine()

    @Published private(set) var phase: Phase = .starting
    /// When the current engine generation started listening (the engine card atop 设置).
    @Published private(set) var runningSince: Date?
    /// Start-up has run far past a normal launch and still has no URL. `main.mjs`
    /// restarts an engine worker that dies, so a boot that keeps failing never ends
    /// the process and so never reaches `.exited`, and neither does one a plugin
    /// keeps from finishing: without this the launch screen stays up forever. A launch
    /// that hangs is not a crash either, so nothing about it reaches App Store Connect —
    /// the device's own log is the only account of it.
    @Published private(set) var stalled = false
    /// When `start()` ran, for the counter on that screen.
    @Published private(set) var startedAt: Date?
    private var started = false

    /// A cold start is a few seconds, and far less once the engine is warm. What this
    /// brings up says the engine is still being waited for and leaves on its own if it
    /// does come up, so waiting any longer would only hide the problem.
    private static let stallAfter: TimeInterval = 20

    private init() {}

    var logFile: URL { EnginePaths.real(EnginePaths.shared + "/engine.log") }

    /// Recovery (engine/runtime/recovery.mjs, driven by `main.mjs`): the way back in when
    /// the engine will not come up. It is asked by file, since an engine that never came up
    /// answers no HTTP; `main.mjs` looks every second and says how the launch stands in
    /// another file, read here with the URL.
    private static let recoveryRequest = EnginePaths.real(EnginePaths.shared + "/recovery-request.json")
    private static let recoveryStateFile = EnginePaths.real(EnginePaths.shared + "/recovery-state.json")
    private static let recoveryReport = EnginePaths.real(EnginePaths.shared + "/recovery-report.json")

    /// How the launch stands, as `main.mjs` last wrote it.
    @Published private(set) var recovery: RecoveryState?

    /// Ask for one recovery step. Returns its id, which comes back in `recovery.action` once done.
    @discardableResult
    func requestRecovery(_ action: RecoveryAction) -> String {
        let id = UUID().uuidString
        var body: [String: String] = ["id": id, "action": action.name]
        if case .edit(let path, let text) = action {
            body["path"] = path
            body["text"] = text
        }
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            try? data.write(to: Self.recoveryRequest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return id
    }

    /// What recovery did before this launch came up, once: the record goes as it is read.
    func takeRecoveryReport() -> [RecoveryState.Action]? {
        guard let data = try? Data(contentsOf: Self.recoveryReport) else { return nil }
        try? FileManager.default.removeItem(at: Self.recoveryReport)
        struct Report: Decodable { let actions: [RecoveryState.Action] }
        guard let actions = (try? RecoveryState.decoder.decode(Report.self, from: data))?.actions, !actions.isEmpty else { return nil }
        return actions
    }

    func start() {
        guard !started else { return }
        started = true
        guard Self.cpuRunsEngine else {
            phase = .unsupported
            return
        }
        startedAt = Date()
        // 本机能力的预热（目前是电量监测）。放在引擎起来之前：UIKit 刚打开电量监测时
        // 还报不出电量，而智能体问电量通常只问一次。
        DshNativePrepare()
        // 写操作要弹的那些界面由 Swift 实现，addon 通过这个桥找过来。必须在引擎起来
        // 之前登记：引擎一跑，第一次调用随时可能到。
        NativeBridge.install()
        // 闹钟和天气的原生实现在 Swift 侧（AlarmKit、WeatherKit 都没有 ObjC 接口），
        // 同样要在引擎起来之前登记。
        AlarmProvider.install()
        WeatherProvider.install()
        // 浏览器能力驱动的是工作台里那个 WKWebView，也在 Swift 侧。
        BrowserAgent.install()
        guard EnginePaths.install() else {
            phase = .exited(-1)
            return
        }
        let urlFile = EnginePaths.real(EnginePaths.shared + "/web-url")
        try? FileManager.default.createDirectory(at: urlFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: urlFile)
        // A request left from a launch that ended before the engine saw it: a new launch
        // has not been asked. The state is the last launch's until `main.mjs` writes its own.
        try? FileManager.default.removeItem(at: Self.recoveryRequest)
        try? FileManager.default.removeItem(at: Self.recoveryStateFile)
        setenv("DSH_IOS_HOME", EnginePaths.home, 1)
        setenv("DSH_IOS_DATA", EnginePaths.shared, 1)
        setenv("DSH_IOS_DOCUMENTS", EnginePaths.documents, 1)
        // The agent ends an iCTRL task by opening this app's own link (references/phone-control.md).
        // Not DSH_-prefixed: dsh keeps those to itself and strips them from every command's
        // environment (dsh-subprocess `scrubbedParentEnv`), so the agent would never see it.
        setenv("FISH_POCKET_URL_SCHEME", DshLink.scheme, 1)
        #if DEBUG
        // Lets <data>/debug/*.mjs run inside the engine (engine/runtime/debug-inbox.mjs).
        setenv("DSH_IOS_DEBUG", "1", 1)
        #endif

        let thread = Thread {
            let code = NodeEngine.runNode(["node", "--expose-internals", EnginePaths.script])
            Task { @MainActor in NodeEngine.shared.phase = .exited(code) }
        }
        thread.name = "node"
        // V8 derives its stack limit from the thread; DSH's module graph is deep.
        thread.stackSize = 16 * 1024 * 1024
        thread.start()

        Task { await waitForURL(urlFile) }
    }

    /// The engine rewrites the URL file each time it (re)starts listening.
    private func waitForURL(_ file: URL) async {
        var seen: Date?
        var stateSeen: Date?
        var generation = 0
        while true {
            if case .exited = phase { return }
            let stateModified = (try? FileManager.default.attributesOfItem(atPath: Self.recoveryStateFile.path))?[.modificationDate] as? Date
            if stateModified != stateSeen {
                stateSeen = stateModified
                let state = (try? Data(contentsOf: Self.recoveryStateFile)).flatMap { try? RecoveryState.decoder.decode(RecoveryState.self, from: $0) }
                if state != recovery { recovery = state }
            }
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            if let modified, modified != seen,
               let text = try? String(contentsOf: file, encoding: .utf8),
               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                seen = modified
                generation += 1
                phase = .running(url, generation: generation)
                runningSince = Date()
                stalled = false
            }
            // `main.mjs` has stopped restarting: no point waiting out the rest of the 20 s.
            if case .starting = phase, let startedAt,
               Date().timeIntervalSince(startedAt) > Self.stallAfter || recovery?.state == .failed {
                if !stalled { stalled = true }
            }
            // The launch screen is up until the URL comes: look often then. Once running,
            // this only notices an engine restart, which can wait half a second.
            let starting = if case .starting = phase { true } else { false }
            try? await Task.sleep(for: .milliseconds(starting ? 100 : 500))
        }
    }

    /// Whether this processor has the ARMv8.1 atomics (LSE). nodejs-mobile's builtins are
    /// generated on a Mac, whose compiler has them, so V8 bakes them in with no fallback
    /// (`CpuFeaturesFromCompiler` in deps/v8/src/codegen/arm64/assembler-arm64.cc). A10 and
    /// A10X lack them: iPad (6th and 7th generation) and iPad Pro (2nd generation), where the
    /// engine dies of SIGILL in `Builtins_AtomicsAdd` on its first `process.chdir`.
    /// A device that answers neither name is taken to have them, so nothing else is shut out.
    nonisolated static var cpuRunsEngine: Bool {
        #if DEBUG
        // UI checks: `simctl launch … -dshSimulateNoLSE 1` shows the screen such a device gets.
        if UserDefaults.standard.bool(forKey: "dshSimulateNoLSE") { return false }
        #endif
        for name in ["hw.optional.arm.FEAT_LSE", "hw.optional.armv8_1_atomics"] {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname(name, &value, &size, nil, 0) == 0 { return value != 0 }
        }
        return true
    }

    /// node_start needs argv in one contiguous buffer (libuv rewrites it for the process title).
    nonisolated private static func runNode(_ arguments: [String]) -> Int32 {
        let total = arguments.reduce(0) { $0 + $1.utf8.count + 1 }
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: total)
        var argv: [UnsafeMutablePointer<CChar>?] = []
        var cursor = buffer
        for argument in arguments {
            argument.withCString { source in
                let length = strlen(source) + 1
                cursor.update(from: source, count: length)
                argv.append(cursor)
                cursor += length
            }
        }
        return argv.withUnsafeMutableBufferPointer { pointer in
            node_start(Int32(arguments.count), pointer.baseAddress)
        }
    }
}

/// One step the launch screen can ask of `main.mjs` (engine/runtime/recovery.mjs).
enum RecoveryAction: Equatable {
    /// Switch off every third-party plugin.
    case safeMode
    /// Put back the settings of the last launch that came up.
    case restore
    /// Move every setting aside: the engine starts from its defaults.
    case reset
    /// Rewrite one settings file by hand.
    case edit(path: String, text: String)
    /// Only start the engine again.
    case restart

    var name: String {
        switch self {
        case .safeMode: "safe-mode"
        case .restore: "restore"
        case .reset: "reset"
        case .edit: "edit"
        case .restart: "restart"
        }
    }
}

/// How the launch stands (`recovery-state.json`, written by `main.mjs`).
struct RecoveryState: Decodable, Equatable {
    enum Phase: String, Decodable { case starting, running, failed }

    /// One recovery step carried out.
    struct Action: Decodable, Equatable {
        let id: String
        let action: String
        let at: Date
        let ok: Bool
        let error: String?
        /// The plugins switched off (safe mode).
        let disabled: [String]?
        /// The settings files changed, relative to `~/.dsh`.
        let files: [String]?
        /// When the settings put back were kept (restore).
        let checkpoint: Date?
        /// Where what was replaced went, as `~/…`.
        let backup: String?
    }

    struct Change: Decodable, Equatable, Hashable {
        enum Kind: String, Decodable { case changed, added, removed }
        let path: String
        let kind: Kind
    }

    /// The settings of the last launch that came up, and what putting them back would change.
    struct Checkpoint: Decodable, Equatable {
        let at: Date
        let changes: [Change]
    }

    let state: Phase
    /// While starting: the engine is up and only third-party plugins are still loading
    /// (engine/plugins/ios-host/startup.mjs). Absent from an engine that predates it.
    let thirdPartyStarting: Bool?
    let action: Action?
    let checkpoint: Checkpoint?
    /// The settings files, relative to `~/.dsh`.
    let files: [String]

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // `toISOString()`: with milliseconds, which `.iso8601` does not take.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = withFraction.date(from: text) ?? plain.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)"))
            }
            return date
        }
        return decoder
    }()
}
