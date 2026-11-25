import AppKit
import Darwin

/// Small wrappers over sysctl / libproc for the process facts the monitor needs.
enum Processes {
    struct Info {
        let pid: pid_t
        let ppid: pid_t
        let tty: String?      // "ttys003", or nil when the process has no terminal
        let comm: String
    }

    /// Every process on the machine (pid, parent, terminal, short name).
    static func all() -> [Info] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map { p in
            var p = p
            let comm = withUnsafePointer(to: &p.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            let tdev = p.kp_eproc.e_tdev
            var tty: String?
            if tdev != -1, let name = devname(tdev, S_IFCHR) { tty = String(cString: name) }
            return Info(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid, tty: tty, comm: comm)
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// One environment variable of another process (same user), from KERN_PROCARGS2 after its argv.
    /// Only the requested variable is kept; the rest of the environment (which may hold API keys) is skipped.
    static func environmentValue(_ pid: pid_t, _ name: String) -> String? {
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mibMax, 2, &argMax, &size, nil, 0) == 0, argMax > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: Int(argMax))
        var len = Int(argMax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &len, nil, 0) == 0, len > 4 else { return nil }
        defer { _ = buf.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }  // wipe the copy
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<4]) }
        var i = 4
        while i < len && buf[i] != 0 { i += 1 }      // exec path
        while i < len && buf[i] == 0 { i += 1 }
        let prefix = Array((name + "=").utf8)
        var index = 0
        while i < len {
            let start = i
            while i < len && buf[i] != 0 { i += 1 }
            if i == start { break }                  // empty string ends the env block
            if index >= Int(argc), i - start > prefix.count, Array(buf[start..<start + prefix.count]) == prefix {
                return String(decoding: buf[(start + prefix.count)..<i], as: UTF8.self)
            }
            index += 1; i += 1
        }
        return nil
    }

    /// Current working directory of another process.
    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// All descendants of `root` (children, grandchildren, …) given a process list.
    static func descendants(of root: pid_t, in list: [Info]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for p in list { children[p.ppid, default: []].append(p.pid) }
        var out: [pid_t] = [], stack = [root]
        while let next = stack.popLast() {
            for c in children[next] ?? [] { out.append(c); stack.append(c) }
        }
        return out
    }

    /// Walks up from `pid` to the first ancestor that is a regular app (e.g. Terminal, iTerm, VS Code).
    static func hostApp(of pid: pid_t, in list: [Info]) -> NSRunningApplication? {
        let parent = Dictionary(list.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        var current = parent[pid]
        var hops = 0
        while let p = current, p > 1, hops < 30 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            current = parent[p]; hops += 1
        }
        return nil
    }

    struct Usage { var footprint: UInt64; var cpuNanos: UInt64 }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// Memory footprint and total CPU time for one process.
    static func usage(_ pid: pid_t) -> Usage? {
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard rc == 0 else { return nil }
        // CPU times are in mach absolute-time units (not ns) on Apple silicon.
        let ticks = info.ri_user_time + info.ri_system_time
        return Usage(footprint: info.ri_phys_footprint, cpuNanos: ticks * timebase.numer / timebase.denom)
    }
}
