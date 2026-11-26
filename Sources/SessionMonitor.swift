import AppKit
import Combine

enum SessionStatus: Int, Comparable {
    case needsYou = 0, finished = 1, starting = 2, working = 3, idle = 4
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .needsYou: return "needs you"
        case .finished: return "done"
        case .working: return "working"
        case .idle: return "idle"
        case .starting: return "starting (check its window)"
        }
    }
    var symbol: String {
        switch self {
        case .needsYou: return "exclamationmark.bubble.fill"
        case .finished: return "checkmark.circle.fill"
        case .working: return "circle.dotted.circle"
        case .idle: return "moon.zzz"
        case .starting: return "hourglass"
        }
    }
    var color: NSColor {
        switch self {
        case .needsYou: return .systemOrange
        case .finished: return .systemGreen
        case .working: return .systemBlue
        case .idle: return .tertiaryLabelColor
        case .starting: return .systemYellow
        }
    }
}

/// One running Claude Code session, from Desktop or a terminal.
struct LiveSession: Identifiable, Hashable {
    let pid: pid_t
    let sessionId: String
    let hostSessionId: String?     // Desktop's "local_…" id, used to open that exact session
    let name: String
    let cwd: String
    let status: SessionStatus
    let waitingFor: String?
    let statusSince: Date?
    let startedAt: Date?
    let isDesktop: Bool
    let accountID: UUID?
    let tty: String?
    /// Registry kind: "interactive", or "bg" / "daemon-worker" for `claude --bg` sessions.
    var kind: String? = nil
    /// Background sessions' short id, as used by `claude attach <id>`.
    var jobId: String? = nil
    var id: pid_t { pid }

    var isBackground: Bool { kind == "bg" || kind == "daemon-worker" }
    var where_: String { isDesktop ? "Desktop" : isBackground ? "Background" : "Terminal" }

    var folderName: String { URL(fileURLWithPath: cwd).lastPathComponent }
}

struct InstanceStats: Equatable {
    var memory: UInt64 = 0
    var cpuPercent: Double = 0
    var sessionCount = 0

    var summary: String {
        let mem = ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)
        return "\(mem) · \(Int(cpuPercent.rounded()))% CPU"
    }
}

/// Watches Claude Code's own live-session registry (`<config dir>/sessions/<pid>.json`), which every
/// session — Desktop or terminal — keeps up to date with "busy" / "idle" and what it's waiting for.
/// No hooks or changes to Claude's settings are needed.
final class SessionMonitor: ObservableObject {
    static let shared = SessionMonitor()

    @Published private(set) var sessions: [LiveSession] = []
    @Published private(set) var stats: [UUID: InstanceStats] = [:]

    /// Sessions that went from working to idle since the menu was last opened.
    private var finishedUnseen: Set<String> = []
    private var lastRawStatus: [String: String] = [:]
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastSampleAt: Date?
    private let queue = DispatchQueue(label: "ai.antcodelabs.session-monitor")
    private var timer: Timer?

    var attentionCount: Int { sessions.filter { [.needsYou, .finished, .starting].contains($0.status) }.count }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Clears "done" markers (called when the user opens the menu and has seen them).
    func markFinishedSeen() {
        queue.async { [weak self] in
            guard let self else { return }
            self.finishedUnseen.removeAll()
            DispatchQueue.main.async {
                self.sessions = self.sessions.map { s in
                    s.status == .finished ? s.with(status: .idle) : s
                }.sorted(by: Self.order)
            }
        }
    }

    func refresh() {
        let accounts = ConfigStore.shared.config.accounts
        let running = ClaudeInstances.running()
        let instancePIDs = accounts.compactMap { a in running[a.resolvedDataDir].map { (a.id, $0.processIdentifier) } }
        queue.async { [weak self] in
            guard let self else { return }
            let procs = Processes.all()
            let sessions = self.readSessions(accounts: accounts, procs: procs)
            let stats = self.sampleStats(instancePIDs, procs: procs, sessions: sessions)
            DispatchQueue.main.async {
                if self.sessions != sessions { self.sessions = sessions }
                if self.stats != stats { self.stats = stats }
            }
        }
    }

    // MARK: Registry

    private func readSessions(accounts: [Account], procs: [Processes.Info]) -> [LiveSession] {
        let fm = FileManager.default
        let byPID = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        // Desktop sessions register under ~/.claude whichever login started them.
        var dirs = Set(accounts.map(\.effectiveCLIConfigDir))
        dirs.insert(ClaudeInstances.normalise("~/.claude"))

        var out: [LiveSession] = []
        var seenIDs = Set<String>()
        for dir in dirs.sorted() {
            let sessionsDir = URL(fileURLWithPath: dir).appendingPathComponent("sessions")
            let files = (try? fm.contentsOfDirectory(atPath: sessionsDir.path)) ?? []
            for file in files where file.hasSuffix(".json") {
                guard let pid = pid_t(file.dropLast(5)), Processes.isAlive(pid),
                      let proc = byPID[pid], proc.comm.lowercased().contains("claude"),
                      let data = try? Data(contentsOf: sessionsDir.appendingPathComponent(file)),
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sessionId = j["sessionId"] as? String, !seenIDs.contains(sessionId)
                else { continue }
                seenIDs.insert(sessionId)

                let exe = Processes.executablePath(pid) ?? ""
                let isDesktop = (j["entrypoint"] as? String) == "claude-desktop" || exe.contains("/claude-code/")
                let account: Account? = isDesktop
                    ? accounts.first { exe.hasPrefix($0.resolvedDataDir + "/") }
                    : accounts.first { $0.effectiveCLIConfigDir == dir }

                let raw = (j["status"] as? String) ?? "idle"
                let waitingFor = (j["waitingFor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let previous = lastRawStatus[sessionId]
                lastRawStatus[sessionId] = raw
                if previous == "busy" && raw != "busy" && waitingFor == nil { finishedUnseen.insert(sessionId) }
                if raw == "busy" { finishedUnseen.remove(sessionId) }

                let status: SessionStatus = waitingFor != nil ? .needsYou
                    : raw == "busy" ? .working
                    : finishedUnseen.contains(sessionId) ? .finished : .idle

                let cwd = (j["cwd"] as? String) ?? ""
                let name = ((j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? URL(fileURLWithPath: cwd).lastPathComponent
                out.append(LiveSession(
                    pid: pid, sessionId: sessionId,
                    hostSessionId: j["hostSessionId"] as? String,
                    name: name, cwd: cwd, status: status, waitingFor: waitingFor,
                    statusSince: Self.date(j["statusUpdatedAt"]),
                    startedAt: Self.date(j["startedAt"]),
                    isDesktop: isDesktop, accountID: account?.id, tty: isDesktop ? nil : proc.tty,
                    kind: j["kind"] as? String, jobId: j["jobId"] as? String))
            }
        }
        // Terminal sessions that haven't registered yet (e.g. sitting at the "trust this folder?" question).
        let registeredPIDs = Set(out.map(\.pid))
        for p in procs where p.comm == "claude" && p.tty != nil && !registeredPIDs.contains(p.pid) {
            let dir = ClaudeInstances.normalise(Processes.environmentValue(p.pid, "CLAUDE_CONFIG_DIR") ?? "~/.claude")
            let cwd = Processes.cwd(p.pid) ?? ""
            let account = accounts.first { $0.effectiveCLIConfigDir == dir }
            out.append(LiveSession(
                pid: p.pid, sessionId: "pid-\(p.pid)", hostSessionId: nil,
                name: URL(fileURLWithPath: cwd).lastPathComponent, cwd: cwd, status: .starting, waitingFor: nil,
                statusSince: nil, startedAt: nil, isDesktop: false, accountID: account?.id, tty: p.tty))
        }

        lastRawStatus = lastRawStatus.filter { seenIDs.contains($0.key) }
        finishedUnseen = finishedUnseen.intersection(seenIDs)
        return out.sorted(by: Self.order)
    }

    private static func order(_ a: LiveSession, _ b: LiveSession) -> Bool {
        if a.status != b.status { return a.status < b.status }
        return (a.statusSince ?? .distantPast) > (b.statusSince ?? .distantPast)
    }

    private static func date(_ any: Any?) -> Date? {
        guard let ms = any as? Double else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    // MARK: Desktop instance resources

    private func sampleStats(_ instances: [(UUID, pid_t)], procs: [Processes.Info], sessions: [LiveSession]) -> [UUID: InstanceStats] {
        let now = Date()
        let wall = lastSampleAt.map { now.timeIntervalSince($0) } ?? 0
        var newCPU: [pid_t: UInt64] = [:]
        var result: [UUID: InstanceStats] = [:]
        for (accountID, root) in instances {
            var s = InstanceStats()
            var cpuDelta: UInt64 = 0
            for pid in [root] + Processes.descendants(of: root, in: procs) {
                guard let u = Processes.usage(pid) else { continue }
                s.memory += u.footprint
                newCPU[pid] = u.cpuNanos
                if let prev = lastCPU[pid], u.cpuNanos >= prev { cpuDelta += u.cpuNanos - prev }
            }
            if wall > 0 { s.cpuPercent = Double(cpuDelta) / (wall * 1e9) * 100 }
            s.sessionCount = sessions.filter { $0.isDesktop && $0.accountID == accountID }.count
            result[accountID] = s
        }
        lastCPU = newCPU
        lastSampleAt = now
        return result
    }

    // MARK: Actions

    /// Brings a session to the front: the exact Desktop session, or the terminal tab it runs in.
    func focus(_ session: LiveSession) {
        let config = ConfigStore.shared.config
        if session.isDesktop {
            guard let account = config.accounts.first(where: { $0.id == session.accountID }) else { return }
            let url = session.hostSessionId.flatMap { $0.hasPrefix("local_") ? ClaudeInstances.continueURL(session: $0) : nil }
            ClaudeInstances.open(account, url: url, claudeAppPath: config.claudeAppPath) { err in
                if let err { AppDelegate.showError(err) }
            }
            return
        }
        if session.isBackground {
            // No window to bring forward: open it in Terminal with `claude attach <id>`, under the same login.
            guard let id = session.jobId,
                  let account = config.accounts.first(where: { $0.id == session.accountID }) else { return }
            let ws = Workspace(name: session.folderName, path: session.cwd)
            TerminalLauncher.launch(account, workspace: ws, config: config, extraArgs: ["attach", id]) { err in
                if let err { AppDelegate.showError(err) }
            }
            return
        }
        let host = Processes.hostApp(of: session.pid, in: Processes.all())
        if host?.bundleIdentifier == "com.apple.Terminal", let tty = session.tty {
            TerminalLauncher.focusTerminalTab(tty: "/dev/\(tty)")
        } else {
            host?.activate()
        }
    }

    /// Ends a terminal session the way closing its window would.
    func stop(_ session: LiveSession) {
        guard !session.isDesktop, !session.isBackground else { return }
        kill(session.pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }
}

private extension LiveSession {
    func with(status: SessionStatus) -> LiveSession {
        LiveSession(pid: pid, sessionId: sessionId, hostSessionId: hostSessionId, name: name, cwd: cwd,
                    status: status, waitingFor: waitingFor, statusSince: statusSince, startedAt: startedAt,
                    isDesktop: isDesktop, accountID: accountID, tty: tty, kind: kind, jobId: jobId)
    }
}
