import Foundation
import Combine

/// Token counts and API-price cost for a set of replies.
struct DayTotals: Codable, Equatable {
    var input = 0          // uncached input tokens
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var output = 0
    var messages = 0
    var webSearches = 0
    /// USD at Claude API list prices (see Pricing), split by what was paid for.
    var costInput = 0.0
    var costCacheWrite = 0.0
    var costCacheRead = 0.0
    var costOutput = 0.0
    var costWebSearch = 0.0
    /// Replies from models missing from the price table (counted in tokens, not in cost).
    var unpriced = 0

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    var allInput: Int { input + cacheWrite + cacheRead }
    var total: Int { allInput + output }
    var cost: Double { costInput + costCacheWrite + costCacheRead + costOutput + costWebSearch }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ k: CodingKeys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: k) ?? 0 }
        input = try int(.input); cacheWrite5m = try int(.cacheWrite5m); cacheWrite1h = try int(.cacheWrite1h)
        cacheRead = try int(.cacheRead); output = try int(.output); messages = try int(.messages)
        webSearches = try int(.webSearches); unpriced = try int(.unpriced)
        func dbl(_ k: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? 0 }
        costInput = try dbl(.costInput); costCacheWrite = try dbl(.costCacheWrite); costCacheRead = try dbl(.costCacheRead)
        costOutput = try dbl(.costOutput); costWebSearch = try dbl(.costWebSearch)
    }

    mutating func add(_ o: DayTotals) {
        input += o.input; cacheWrite5m += o.cacheWrite5m; cacheWrite1h += o.cacheWrite1h
        cacheRead += o.cacheRead; output += o.output; messages += o.messages
        webSearches += o.webSearches; unpriced += o.unpriced
        costInput += o.costInput; costCacheWrite += o.costCacheWrite; costCacheRead += o.costCacheRead
        costOutput += o.costOutput; costWebSearch += o.costWebSearch
    }
}

struct UsageSummary: Equatable {
    var today = DayTotals()
    var sessionsToday = 0
    /// Last 7 days, oldest first ("yyyy-MM-dd", totals).
    var days: [(String, DayTotals)] = []
    var week = DayTotals()
    var month = DayTotals()
    /// Per model over the last 7 and 30 days, most expensive first (model id, totals).
    var weekByModel: [(String, DayTotals)] = []
    var monthByModel: [(String, DayTotals)] = []

    static func == (a: Self, b: Self) -> Bool {
        a.today == b.today && a.sessionsToday == b.sessionsToday && a.month == b.month && a.week == b.week
            && a.days.map(\.0) == b.days.map(\.0) && a.days.map(\.1) == b.days.map(\.1)
            && a.monthByModel.map(\.0) == b.monthByModel.map(\.0) && a.monthByModel.map(\.1) == b.monthByModel.map(\.1)
    }
}

/// Token usage per login, read from Claude Code's session logs (`<config dir>/projects/**.jsonl`).
/// Only the `usage` numbers, model, speed and region of assistant messages are read; each file is parsed
/// incrementally and per-day, per-model totals (with their API-price cost) are cached on disk.
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var summaries: [UUID: UsageSummary] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false

    private struct FileEntry: Codable {
        var size: UInt64
        var mtime: Double
        var offset: UInt64
        var lastMessageID: String?
        var sessionID: String
        var entrypoint: String?
        var configDir: String
        /// day → model → totals
        var days: [String: [String: DayTotals]]
        /// Message ids this file counted. Resumed or forked sessions copy earlier replies into a new log
        /// file, so each reply is counted once across all files: the first file to read it owns it.
        var ids: [String] = []
    }

    private var files: [String: FileEntry] = [:]
    /// message id → path of the file that counted it
    private var claimed: [String: String] = [:]
    private let queue = DispatchQueue(label: "ai.antcodelabs.usage", qos: .utility)
    private var timer: Timer?
    static let lookbackDays = 31

    /// Versioned so a change in pricing or format re-reads the logs instead of reusing stale totals.
    private var cacheURL: URL {
        ConfigStore.shared.fileURL.deletingLastPathComponent()
            .appendingPathComponent("usage-cache-v3-p\(Pricing.version).json")
    }

    func start() {
        queue.async { [weak self] in self?.loadCache() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Refreshes unless the last refresh was under `maxAge` seconds ago.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        if let last = lastUpdated, Date().timeIntervalSince(last) < maxAge { return }
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let accounts = ConfigStore.shared.config.accounts
        queue.async { [weak self] in
            guard let self else { return }
            self.scan(accounts: accounts)
            let result = self.summarise(accounts: accounts)
            self.saveCache()
            DispatchQueue.main.async {
                self.summaries = result
                self.lastUpdated = Date()
                self.isRefreshing = false
            }
        }
    }

    // MARK: Scanning

    private func scan(accounts: [Account]) {
        let fm = FileManager.default
        var dirs = Set(accounts.map(\.effectiveCLIConfigDir))
        dirs.insert(ClaudeInstances.normalise("~/.claude"))   // Desktop sessions log here
        let cutoff = Date().addingTimeInterval(-Double(Self.lookbackDays + 1) * 86400)
        var seen = Set<String>()

        for dir in dirs {
            let root = URL(fileURLWithPath: dir).appendingPathComponent("projects")
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = rv.contentModificationDate, mtime >= cutoff,
                      let size = rv.fileSize.map(UInt64.init) else { continue }
                seen.insert(url.path)
                var entry = files[url.path] ?? FileEntry(
                    size: 0, mtime: 0, offset: 0, lastMessageID: nil,
                    sessionID: url.deletingPathExtension().lastPathComponent,
                    entrypoint: nil, configDir: dir, days: [:])
                if entry.size == size && entry.mtime == mtime.timeIntervalSince1970 { continue }
                if size < entry.offset {   // rewritten: start over
                    for id in entry.ids where claimed[id] == url.path { claimed[id] = nil }
                    entry.offset = 0; entry.days = [:]; entry.lastMessageID = nil; entry.ids = []
                }
                parse(url: url, into: &entry)
                entry.size = size
                entry.mtime = mtime.timeIntervalSince1970
                files[url.path] = entry
            }
        }
        // Forget files that are gone or older than the window, and the replies they counted.
        for (path, entry) in files where !seen.contains(path) {
            for id in entry.ids where claimed[id] == path { claimed[id] = nil }
        }
        files = files.filter { seen.contains($0.key) }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private func parse(url: URL, into entry: inout FileEntry) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: entry.offset)

        let assistantTag = Data("\"type\":\"assistant\"".utf8)
        let usageTag = Data("\"usage\"".utf8)
        var pending = Data()
        var consumed = entry.offset

        while let chunk = try? fh.read(upToCount: 4 << 20), !chunk.isEmpty {
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let nl = pending[lineStart...].firstIndex(of: 0x0A) {
                let line = pending[lineStart..<nl]
                consumed += UInt64(nl - lineStart + 1)
                lineStart = pending.index(after: nl)
                guard line.range(of: assistantTag) != nil, line.range(of: usageTag) != nil,
                      let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let msg = j["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { continue }

                if entry.entrypoint == nil { entry.entrypoint = j["entrypoint"] as? String }
                if let sid = j["sessionId"] as? String, url.path.contains("/subagents/") { entry.sessionID = sid }

                // A response split over several lines repeats its message id and usage, and resumed or
                // forked sessions copy earlier replies into new files: count each message id once.
                let mid = msg["id"] as? String
                if let mid, mid == entry.lastMessageID { continue }
                entry.lastMessageID = mid
                if let mid {
                    if claimed[mid] != nil { continue }
                    claimed[mid] = url.path
                    entry.ids.append(mid)
                }

                let model = (msg["model"] as? String) ?? "unknown"
                if model == "<synthetic>" { continue }   // generated locally by Claude Code, never billed
                guard let ts = j["timestamp"] as? String,
                      let date = Self.isoFrac.date(from: ts) ?? Self.iso.date(from: ts) else { continue }
                let day = Self.dayFormatter.string(from: date)

                var u = Pricing.Usage()
                u.input = usage["input_tokens"] as? Int ?? 0
                u.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                u.output = usage["output_tokens"] as? Int ?? 0
                let written = usage["cache_creation_input_tokens"] as? Int ?? 0
                if let split = usage["cache_creation"] as? [String: Any] {
                    u.cacheWrite5m = split["ephemeral_5m_input_tokens"] as? Int ?? 0
                    u.cacheWrite1h = split["ephemeral_1h_input_tokens"] as? Int ?? 0
                    let rest = written - u.cacheWrite5m - u.cacheWrite1h
                    if rest > 0 { u.cacheWrite5m += rest }
                } else {
                    u.cacheWrite5m = written   // the API's default cache lifetime
                }
                u.webSearches = (usage["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int ?? 0
                u.fast = (usage["speed"] as? String) == "fast"
                u.usOnly = (usage["inference_geo"] as? String) == "us"

                var t = entry.days[day, default: [:]][model] ?? DayTotals()
                t.input += u.input; t.cacheWrite5m += u.cacheWrite5m; t.cacheWrite1h += u.cacheWrite1h
                t.cacheRead += u.cacheRead; t.output += u.output; t.webSearches += u.webSearches
                t.messages += 1
                if let c = Pricing.cost(model: model, u) {
                    t.costInput += c.input; t.costCacheWrite += c.cacheWrite; t.costCacheRead += c.cacheRead
                    t.costOutput += c.output; t.costWebSearch += c.webSearch
                } else {
                    t.unpriced += 1
                }
                entry.days[day, default: [:]][model] = t
            }
            pending = Data(pending[lineStart...])   // keep the unfinished last line for the next chunk
        }
        entry.offset = consumed
    }

    // MARK: Attribution

    private func summarise(accounts: [Account]) -> [UUID: UsageSummary] {
        // Desktop sessions all log under ~/.claude; each Desktop login's own session list says which are its.
        var desktopOwner: [String: UUID] = [:]
        for a in accounts {
            for s in ClaudeConfigInfo.desktopSessions(a, days: Self.lookbackDays + 1) { desktopOwner[s.cliSessionId] = a.id }
        }

        func day(_ offset: Int) -> String {
            Self.dayFormatter.string(from: Calendar.current.date(byAdding: .day, value: -offset, to: Date())!)
        }
        let today = day(0)
        let last7 = (0..<7).reversed().map(day)
        let last30 = Set((0..<30).map(day))

        var sessionsToday: [UUID: Set<String>] = [:]
        var perDay: [UUID: [String: DayTotals]] = [:]
        var weekModels: [UUID: [String: DayTotals]] = [:]
        var monthModels: [UUID: [String: DayTotals]] = [:]

        for entry in files.values {
            let owner: UUID?
            if let o = desktopOwner[entry.sessionID] {
                owner = o
            } else if entry.entrypoint == "claude-desktop" {
                owner = nil    // a Desktop session we can't place (e.g. archived long ago)
            } else {
                owner = accounts.first { $0.effectiveCLIConfigDir == entry.configDir }?.id
            }
            guard let owner else { continue }
            for (d, models) in entry.days where last30.contains(d) {
                for (model, t) in models {
                    monthModels[owner, default: [:]][model, default: DayTotals()].add(t)
                    if last7.contains(d) {
                        weekModels[owner, default: [:]][model, default: DayTotals()].add(t)
                        perDay[owner, default: [:]][d, default: DayTotals()].add(t)
                    }
                    if d == today && t.messages > 0 { sessionsToday[owner, default: []].insert(entry.sessionID) }
                }
            }
        }

        func sorted(_ m: [String: DayTotals]?) -> [(String, DayTotals)] {
            (m ?? [:]).sorted { $0.value.cost != $1.value.cost ? $0.value.cost > $1.value.cost : $0.value.total > $1.value.total }
                .map { ($0.key, $0.value) }
        }
        var result: [UUID: UsageSummary] = [:]
        for a in accounts {
            let d = perDay[a.id] ?? [:]
            var s = UsageSummary()
            s.today = d[today] ?? DayTotals()
            s.sessionsToday = sessionsToday[a.id]?.count ?? 0
            s.days = last7.map { ($0, d[$0] ?? DayTotals()) }
            s.days.forEach { s.week.add($0.1) }
            s.weekByModel = sorted(weekModels[a.id])
            s.monthByModel = sorted(monthModels[a.id])
            s.monthByModel.forEach { s.month.add($0.1) }
            result[a.id] = s
        }
        return result
    }

    // MARK: Cache

    private func loadCache() {
        // Remove caches from earlier formats.
        let dir = cacheURL.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix("usage-cache") && name != cacheURL.lastPathComponent {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: FileEntry].self, from: data) else { return }
        files = decoded
        for (path, entry) in files { for id in entry.ids { claimed[id] = path } }
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(files) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: Formatting

    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        case ..<1_000_000_000: return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        default: return String(format: "%.2fB", Double(n) / 1_000_000_000)
        }
    }
}
