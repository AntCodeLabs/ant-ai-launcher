import SwiftUI
import AppKit

// Note: the Command Line Tools ship without SwiftUI's macro plugin, so this file avoids `@State`
// (a macro in this SDK). Shared state lives in ObservableObjects; DisclosureGroups keep their own.

/// Which sidebar row Settings shows; shared so the menu can open Settings on a given login.
final class SettingsSelection: ObservableObject {
    static let shared = SettingsSelection()
    @Published var selection: UUID?
}

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var nav = SettingsSelection.shared

    static let generalID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $nav.selection) {
                    Section("Logins") {
                        ForEach(store.config.accounts) { account in
                            Label(account.name.isEmpty ? "Untitled" : account.name,
                                  systemImage: account.isDefaultProfile ? "person.crop.circle" : "person.crop.circle.badge")
                                .tag(account.id)
                        }
                        .onMove { store.config.accounts.move(fromOffsets: $0, toOffset: $1) }
                    }
                    Section {
                        Label("General", systemImage: "gearshape").tag(Self.generalID)
                    }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 4) {
                            Button { addAccount() } label: { Image(systemName: "plus") }
                                .help("Add a login")
                            Button { removeSelected() } label: { Image(systemName: "minus") }
                                .disabled(nav.selection == nil || nav.selection == Self.generalID)
                                .help("Remove the selected login")
                            Spacer()
                            Button { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                            }
                            .help("Show config.json in Finder")
                        }
                        .buttonStyle(.borderless)
                        Divider()
                        BrandFooter()
                    }
                    .padding(10)
                }
            }
            .frame(width: 210)
            .background(.regularMaterial)
            Divider()
            Group {
                if nav.selection == Self.generalID {
                    GeneralEditor(config: $store.config)
                } else if let idx = store.config.accounts.firstIndex(where: { $0.id == nav.selection }) {
                    AccountEditor(account: $store.config.accounts[idx], config: store.config)
                        .id(store.config.accounts[idx].id)
                } else {
                    VStack(spacing: 8) {
                        ShrimpMark().stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).frame(width: 56, height: 56)
                        Text("Select a login, or add one with +").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { if nav.selection == nil { nav.selection = store.config.accounts.first?.id } }
    }

    /// Adds "Login N" with its own, unused Claude Desktop and Claude Code folders, so it never shares a
    /// sign-in with another login by accident.
    private func addAccount() {
        let fm = FileManager.default
        let accounts = store.config.accounts
        var n = accounts.count + 1
        while true {
            let name = "Login \(n)"
            let data = Account.defaultDataDir(for: name), cli = Account.defaultCLIConfigDir(for: name)
            let taken = accounts.contains {
                $0.name == name || $0.resolvedDataDir == ClaudeInstances.normalise(data)
                    || $0.effectiveCLIConfigDir == ClaudeInstances.normalise(cli)
            }
            if !taken && !fm.fileExists(atPath: ClaudeInstances.normalise(data))
                && !fm.fileExists(atPath: ClaudeInstances.normalise(cli)) {
                let account = Account(name: name, dataDir: data, cliConfigDir: cli)
                store.config.accounts.append(account)
                nav.selection = account.id
                return
            }
            n += 1
        }
    }

    private func removeSelected() {
        guard let sel = nav.selection, let idx = store.config.accounts.firstIndex(where: { $0.id == sel }) else { return }
        let name = store.config.accounts[idx].name
        let alert = NSAlert()
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "This only removes it from Clauncher. Claude's data folder and sign-in are left untouched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.config.accounts.remove(at: idx)
        nav.selection = store.config.accounts.first?.id
    }
}

// MARK: - Login

struct AccountEditor: View {
    @Binding var account: Account
    let config: LauncherConfig
    @ObservedObject private var monitor = SessionMonitor.shared
    @ObservedObject private var usage = UsageStore.shared

    private var isRunning: Bool { ClaudeInstances.running()[account.resolvedDataDir] != nil }
    private var sessions: [LiveSession] { monitor.sessions.filter { $0.accountID == account.id } }

    var body: some View {
        Form {
            statusSection
            usageSection

            Section {
                TextField("Name", text: $account.name)
                HStack {
                    TextField("Data folder", text: $account.dataDir, prompt: Text("Claude's normal profile"))
                    Button("Choose…") { chooseDataDir() }
                }
                Text(account.isDefaultProfile
                     ? "Uses Claude's normal profile (\(ClaudeInstances.defaultDataDir))."
                     : "Launched with --user-data-dir, so it keeps its own sign-in. Resolves to \(account.resolvedDataDir)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let other = sharing(\.resolvedDataDir) {
                    sharedWarning("Same Claude Desktop folder as “\(other)”, so both open the same Claude with the same sign-in.")
                }
            } header: { Text("Claude Desktop") }

            Section {
                HStack {
                    TextField("Config folder", text: $account.cliConfigDir, prompt: Text("~/.claude (default)"))
                    Menu("Pick") {
                        ForEach(TerminalLauncher.detectedConfigDirs(), id: \.self) { dir in
                            Button(dir) { account.cliConfigDir = dir }
                        }
                    }
                    .fixedSize()
                }
                Text("Terminal sessions run `claude` with CLAUDE_CONFIG_DIR=\(abbreviate(account.effectiveCLIConfigDir)), so they use that Claude Code sign-in. A new folder is created the first time; sign in there with /login.")
                    .font(.caption).foregroundStyle(.secondary)
                if let other = sharing(\.effectiveCLIConfigDir) {
                    sharedWarning("Same Claude Code config folder as “\(other)”, so Terminal sessions here use that login's account.")
                }
            } header: { Text("Claude Code in Terminal") }

            foldersSection
        }
        .formStyle(.grouped)
        .onAppear { usage.refreshIfStale() }
        .onChange(of: account.name) { old, new in followRename(from: old, to: new) }
    }

    // MARK: Shared folders

    /// Name of another login that uses the same folder, if any.
    private func sharing(_ key: KeyPath<Account, String>) -> String? {
        config.accounts.first { $0.id != account.id && $0[keyPath: key] == account[keyPath: key] }
            .map { $0.name.isEmpty ? "Untitled" : $0.name }
    }

    private func sharedWarning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    /// While a login still uses its default folders and they don't exist yet (nobody has signed in),
    /// renaming it renames them too: "Client" → Claude-Client and ~/.claude-client.
    private func followRename(from old: String, to new: String) {
        let fm = FileManager.default
        if account.dataDir == Account.defaultDataDir(for: old),
           !fm.fileExists(atPath: account.resolvedDataDir) {
            account.dataDir = Account.defaultDataDir(for: new)
        }
        if account.cliConfigDir == Account.defaultCLIConfigDir(for: old),
           let dir = account.resolvedCLIConfigDir, !fm.fileExists(atPath: dir) {
            account.cliConfigDir = Account.defaultCLIConfigDir(for: new)
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            LabeledContent("Claude Desktop") {
                HStack(spacing: 6) {
                    switch ClaudeConfigInfo.desktopState(account) {
                    case .signedIn: badge("Signed in", .green)
                    case .signedOut: badge("Not signed in", .orange)
                    case .missing: badge("Not set up yet", .secondary)
                    }
                    if isRunning, let st = monitor.stats[account.id] {
                        Text("Running · \(st.summary)").foregroundStyle(.secondary)
                    } else if !isRunning {
                        Text("Not running").foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Claude Code") {
                if let id = ClaudeConfigInfo.cliIdentity(account) {
                    let extra = [id.organization, id.plan].compactMap { $0 }.joined(separator: " · ")
                    HStack(spacing: 6) {
                        badge("Signed in", .green)
                        Text((id.email ?? "") + (extra.isEmpty ? "" : " · \(extra)"))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    HStack(spacing: 6) {
                        badge("Not signed in", .orange)
                        Text("Run claude in Terminal and use /login").foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Sessions open") {
                let working = sessions.filter { $0.status == .working }.count
                let needs = sessions.filter { $0.status == .needsYou }.count
                Text(sessions.isEmpty ? "None" : "\(sessions.count) · \(working) working · \(needs) need you")
                    .foregroundStyle(.secondary)
            }
        } header: { Text("Status") }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    // MARK: Usage

    private var usageSection: some View {
        Section {
            if let u = usage.summaries[account.id] {
                HStack(spacing: 18) {
                    stat("Today", Pricing.usd(u.today.cost), "\(UsageStore.tokens(u.today.total)) tokens")
                    stat("7 days", Pricing.usd(u.week.cost), "\(UsageStore.tokens(u.week.total)) tokens")
                    stat("30 days", Pricing.usd(u.month.cost), "\(UsageStore.tokens(u.month.total)) tokens")
                    stat("Sessions", "\(u.sessionsToday)", "today")
                }
                UsageBars(days: u.days)
                    .frame(height: 120)
                if !u.monthByModel.isEmpty {
                    ModelBreakdown(rows: u.monthByModel, total: u.month)
                }
                (Text("What this usage would cost at Claude API pay-as-you-go list prices (as of \(Pricing.asOf)), not what a subscription charges. Covers terminal sessions and this login's Desktop Code sessions, from Claude Code's session logs. ")
                    + Text("[Pricing](\(Pricing.source.absoluteString))"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(usage.isRefreshing ? "Counting…" : "No usage recorded in the last month.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Usage at API prices")
                Spacer()
                if usage.isRefreshing { ProgressView().controlSize(.small) }
                Button { usage.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Recount now")
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(unit).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: Folders

    private var foldersSection: some View {
        Section {
            if account.workspaces.isEmpty {
                Text("No folders yet. Add one to start sessions there from the menu bar.")
                    .foregroundStyle(.secondary)
            }
            ForEach($account.workspaces) { $ws in
                WorkspaceRow(workspace: $ws, usedHotkeys: usedHotkeys(excluding: ws.id)) {
                    account.workspaces.removeAll { $0.id == ws.id }
                } launch: { terminal in
                    launch(ws, terminal: terminal)
                }
            }
            .onMove { account.workspaces.move(fromOffsets: $0, toOffset: $1) }
            HStack {
                Button("Add Folders…") { addFolders() }
                let recent = ClaudeConfigInfo.recentFolders(account, limit: 15)
                Menu("Add Recent") {
                    if recent.isEmpty { Text("No recent folders") }
                    ForEach(recent, id: \.path) { r in
                        Button("\(r.name) — \(abbreviate(r.path))") {
                            account.workspaces.append(Workspace(name: r.name, path: abbreviate(r.path)))
                        }
                    }
                }
                .fixedSize()
                .disabled(recent.isEmpty)
                Spacer()
                Button(isRunning ? "Show Claude" : "Open Claude") { launch(nil, terminal: false) }
            }
        } header: {
            Text("Folders")
        } footer: {
            Text("In the menu, a folder opens in its default app; hold ⌥ for the other one, or ⇧ to continue the last terminal session there. Expand a folder for its shortcut, Start My Day and saved prompts. Drag rows to reorder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func usedHotkeys(excluding id: UUID) -> [Int: String] {
        var used: [Int: String] = [:]
        for a in ConfigStore.shared.config.accounts {
            for w in a.workspaces where w.id != id { if let h = w.hotkey { used[h] = "\(a.name): \(w.name)" } }
        }
        return used
    }

    private func launch(_ ws: Workspace?, terminal: Bool) {
        let done: (Error?) -> Void = { error in if let error { AppDelegate.showError(error) } }
        if terminal {
            TerminalLauncher.launch(account, workspace: ws, config: config, completion: done)
        } else {
            ClaudeInstances.launch(account, workspace: ws, claudeAppPath: config.claudeAppPath, completion: done)
        }
    }

    private func chooseDataDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Pick (or create) a folder for this login's Claude data"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        if panel.runModal() == .OK, let url = panel.url {
            account.dataDir = abbreviate(url.path)
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            for url in panel.urls {
                guard !account.workspaces.contains(where: { $0.expandedPath == url.path }) else { continue }
                account.workspaces.append(Workspace(name: url.lastPathComponent, path: abbreviate(url.path)))
            }
        }
    }
}

/// Seven days of token totals as simple bars (no Charts dependency).
struct UsageBars: View {
    let days: [(String, DayTotals)]

    var body: some View {
        let peak = max(days.map(\.1.cost).max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days, id: \.0) { day, t in
                VStack(spacing: 4) {
                    Text(t.cost > 0 ? Pricing.usd(t.cost) : "")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: Brand.acid).opacity(day == days.last?.0 ? 1 : 0.6))
                                .frame(height: max(2, geo.size.height * CGFloat(t.cost / peak)))
                        }
                    }
                    Text(Self.label(day)).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(day): \(Pricing.usd(t.cost)) · \(UsageStore.tokens(t.total)) tokens · \(t.messages) replies")
            }
        }
    }

    private static func label(_ day: String) -> String {
        guard let d = UsageStore.dayFormatter.date(from: day) else { return day }
        let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: d)
    }
}

/// Per-model table for the last 30 days: tokens by type and their API-price cost.
struct ModelBreakdown: View {
    let rows: [(String, DayTotals)]
    let total: DayTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By model · last 30 days").font(.subheadline.weight(.semibold))
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Model").gridColumnAlignment(.leading)
                    Text("Replies"); Text("Input"); Text("Cache write"); Text("Cache read"); Text("Output"); Text("Cost"); Text("")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(rows, id: \.0) { model, t in
                    GridRow {
                        Text(Pricing.displayName(model)).gridColumnAlignment(.leading)
                        Text("\(t.messages)")
                        Text(UsageStore.tokens(t.input))
                        Text(UsageStore.tokens(t.cacheWrite)).help("5-minute \(UsageStore.tokens(t.cacheWrite5m)) · 1-hour \(UsageStore.tokens(t.cacheWrite1h))")
                        Text(UsageStore.tokens(t.cacheRead))
                        Text(UsageStore.tokens(t.output))
                        Text(t.unpriced == t.messages ? "—" : Pricing.usd(t.cost)).fontWeight(.semibold)
                        Text(total.cost > 0 ? "\(Int((t.cost / total.cost * 100).rounded()))%" : "").foregroundStyle(.secondary)
                    }
                    .help("Input \(Pricing.usd(t.costInput)) · cache writes \(Pricing.usd(t.costCacheWrite)) · cache reads \(Pricing.usd(t.costCacheRead)) · output \(Pricing.usd(t.costOutput))\(t.unpriced > 0 ? " · \(t.unpriced) replies from a model without a known price" : "")")
                }
                Divider()
                GridRow {
                    Text("Total").gridColumnAlignment(.leading)
                    Text("\(total.messages)")
                    Text(UsageStore.tokens(total.input))
                    Text(UsageStore.tokens(total.cacheWrite))
                    Text(UsageStore.tokens(total.cacheRead))
                    Text(UsageStore.tokens(total.output))
                    Text(Pricing.usd(total.cost))
                    Text("")
                }
                .fontWeight(.semibold)
                GridRow {
                    Text("Cost").gridColumnAlignment(.leading).foregroundStyle(.secondary)
                    Text("")
                    Text(Pricing.usd(total.costInput))
                    Text(Pricing.usd(total.costCacheWrite))
                    Text(Pricing.usd(total.costCacheRead))
                    Text(Pricing.usd(total.costOutput))
                    Text(""); Text("")
                }
                .foregroundStyle(.secondary)
            }
            .font(.callout.monospacedDigit())
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Folder row

struct WorkspaceRow: View {
    @Binding var workspace: Workspace
    let usedHotkeys: [Int: String]
    var remove: () -> Void
    var launch: (_ terminal: Bool) -> Void

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Opens in", selection: $workspace.mode) {
                    ForEach(LaunchMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                HStack {
                    Picker("Shortcut", selection: $workspace.hotkey) {
                        Text("None").tag(Int?.none)
                        ForEach(1...9, id: \.self) { d in
                            Text("⌃⌥⌘\(d)" + (usedHotkeys[d].map { "  (\($0))" } ?? "")).tag(Int?.some(d))
                        }
                    }
                    .fixedSize()
                    if let h = workspace.hotkey, let other = usedHotkeys[h] {
                        Text("Also set on \(other); the first one wins.").font(.caption).foregroundStyle(.orange)
                    }
                }

                Toggle("Open with Start My Day", isOn: $workspace.startOfDay)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Saved prompts").font(.subheadline.weight(.semibold))
                    ForEach($workspace.prompts) { $p in
                        HStack(alignment: .top) {
                            TextField("Name", text: $p.name).frame(width: 140)
                            TextField("Prompt", text: $p.text, axis: .vertical).lineLimit(1...4)
                            Button { workspace.prompts.removeAll { $0.id == p.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button {
                        workspace.prompts.append(SavedPrompt(name: "New prompt", text: ""))
                    } label: { Label("Add Prompt", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: workspace.mode == .terminal ? "terminal" : "folder").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        TextField("Menu title", text: $workspace.name).textFieldStyle(.plain).font(.body)
                        if let h = workspace.hotkey { tag("⌃⌥⌘\(h)") }
                        if workspace.startOfDay { tag("Start My Day") }
                        if !workspace.prompts.isEmpty { tag("\(workspace.prompts.count) prompt\(workspace.prompts.count == 1 ? "" : "s")") }
                    }
                    Text(workspace.path)
                        .font(.caption)
                        .foregroundStyle(FileManager.default.fileExists(atPath: workspace.expandedPath) ? Color.secondary : Color.red)
                        .lineLimit(1).truncationMode(.middle)
                        .help(workspace.expandedPath)
                }
                Spacer()
                Button { launch(false) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless).help("Start a Code session here in Claude Desktop")
                Button { launch(true) } label: { Image(systemName: "terminal") }
                    .buttonStyle(.borderless).help("Start Claude Code here in Terminal")
                Button { remove() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove from list")
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }
}

func abbreviate(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

// MARK: - General

struct GeneralEditor: View {
    @Binding var config: LauncherConfig

    var body: some View {
        Form {
            Section("Apps") {
                HStack {
                    TextField("Claude Desktop", text: $config.claudeAppPath)
                    Button("Choose…") { if let p = chooseApp() { config.claudeAppPath = p } }
                }
                HStack {
                    TextField("Terminal", text: $config.terminalAppPath)
                    Button("Choose…") { if let p = chooseApp() { config.terminalAppPath = p } }
                }
                Text("Terminal sessions are opened as a .command file, which Terminal and iTerm both run. Bringing a session's tab to the front works in Terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code command") {
                TextField("Command", text: $config.claudeCommand, prompt: Text("claude"))
                Text("Run in the folder after setting CLAUDE_CONFIG_DIR. You can add flags, e.g. `claude --model opus`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                LabeledContent("Open the menu anywhere", value: "⌃⌥⌘C")
                LabeledContent("Open a folder", value: "⌃⌥⌘1 … 9 (set per folder)")
                LabeledContent("In the menu", value: "⌥ other app · ⇧ continue · ⌃ quit / stop")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseApp() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
