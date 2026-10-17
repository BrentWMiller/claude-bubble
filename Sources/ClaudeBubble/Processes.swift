import AppKit
import ClaudeBubbleCore
import Darwin

/// Just enough of the process table to find which app a Claude Code session is running in, straight from the kernel.
enum Processes {
    /// A process's parent.
    static func parent(_ pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The regular app (Dock icon, windows) a process runs under, if any.
    static func owningApp(of pid: Int32) -> NSRunningApplication? {
        TerminalApp.owningApp(of: pid, parent: parent, isApp: {
            NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular
        }).flatMap(NSRunningApplication.init(processIdentifier:))
    }

    /// Every running `claude` process with its arguments.
    static func claudeProcesses() -> [(pid: Int32, args: [String])] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        // By argv[0], as `ps` shows it: the kernel's own name for the process is the binary's, and Claude Code's
        // `claude` is a link to a versioned binary ("2.1.302").
        return procs.prefix(count).compactMap { p in
            let pid = p.kp_proc.p_pid
            let args = arguments(pid)
            guard let first = args.first, (first as NSString).lastPathComponent.hasPrefix("claude") else { return nil }
            return (pid, args)
        }
    }

    /// A process's argv (from KERN_PROCARGS2: argc, the executable path, padding, then the arguments).
    private static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }   // the executable path
        while i < size, buffer[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
