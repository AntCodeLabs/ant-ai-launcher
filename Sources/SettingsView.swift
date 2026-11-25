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
                        AntMark().stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).frame(width: 48, height: 48)
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

    private func addAccount() {
        let n = store.config.accounts.count + 1
        let account = Account(name: "Login \(n)", dataDir: "~/Library/Application Support/Claude-Login\(n)")
        store.config.accounts.append(account)
        nav.selection = account.id
    }

    private func removeSelected() {
        guard let sel = nav.selection, let idx = store.config.accounts.firstIndex(where: { $0.id == sel }) else { return }
        let name = store.config.accounts[idx].name
        let alert = NSAlert()
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "This only removes it from Ant AI Launcher. Claude's data folder and sign-in are left untouched."
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
                Text("Terminal sessions run `claude` with CLAUDE_CONFIG_DIR=\(abbreviate(account.effectiveCLIConfigDir)), so they use that Claude Code sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Claude Code in Terminal") }

            foldersSection
        }
        .formStyle(.grouped)
        .onAppear { usage.refreshIfStale() }
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
                    stat("Today", UsageStore.tokens(u.today.total), "tokens")
                    stat("Output", UsageStore.tokens(u.today.output), "tokens")
                    stat("Replies", "\(u.today.messages)", "today")
                    stat("Sessions", "\(u.sessionsToday)", "today")
                }
                UsageBars(days: u.days)
                    .frame(height: 120)
                Text("Counts every reply's tokens (input incl. cache + output) from Claude Code's session logs, for terminal sessions and this login's Desktop Code sessions.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(usage.isRefreshing ? "Counting…" : "No usage recorded in the last week.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Usage · last 7 days")
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
        let peak = max(days.map(\.1.total).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days, id: \.0) { day, t in
                VStack(spacing: 4) {
                    Text(t.total > 0 ? UsageStore.tokens(t.total) : "")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: Brand.acid).opacity(day == days.last?.0 ? 1 : 0.6))
                                .frame(height: max(2, geo.size.height * CGFloat(t.total) / CGFloat(peak)))
                        }
                    }
                    Text(Self.label(day)).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(day): \(UsageStore.tokens(t.allInput)) in, \(UsageStore.tokens(t.output)) out, \(t.messages) replies")
            }
        }
    }

    private static func label(_ day: String) -> String {
        guard let d = UsageStore.dayFormatter.date(from: day) else { return day }
        let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: d)
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
