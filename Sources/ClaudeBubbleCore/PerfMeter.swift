import Darwin
import Foundation
import os

/// Count, mean, 95th percentile and worst of a set of samples.
public struct PerfStats: Equatable {
    public let count: Int
    public let average: Double
    public let p95: Double
    public let max: Double

    public init(samples: [Double]) {
        count = samples.count
        guard !samples.isEmpty else { average = 0; p95 = 0; max = 0; return }
        let sorted = samples.sorted()
        average = samples.reduce(0, +) / Double(samples.count)
        p95 = sorted[Swift.max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        max = sorted[sorted.count - 1]
    }
}

/// What the stress test reads back: the main thread's work and stalls, frame rates and the app's CPU and memory,
/// over the last few seconds.
public struct PerfReport {
    public let window: Double
    public let sections: [PerfMeter.Section: PerfStats]
    /// Per second.
    public let rates: [PerfMeter.Counter: Double]
    /// How late the main thread ran a timer due every 10ms (a stall shows as one big sample).
    public let hitches: PerfStats
    /// Percent of one core, averaged over the window.
    public let cpu: Double?
    public let memoryMB: Double?

    public var text: String {
        func ms(_ s: Double) -> String { String(format: "%.1fms", s * 1000) }
        var lines: [String] = []
        for section in PerfMeter.Section.allCases {
            let s = sections[section] ?? PerfStats(samples: [])
            lines.append("\(section.rawValue): \(String(format: "%.1f", Double(s.count) / window))/s  avg \(ms(s.average))  p95 \(ms(s.p95))  max \(ms(s.max))")
        }
        lines.append("main stalls: p95 \(ms(hitches.p95))  max \(ms(hitches.max))")
        lines.append(PerfMeter.Counter.allCases.map { "\($0.label) \(String(format: "%.0f", rates[$0] ?? 0))/s" }.joined(separator: "  "))
        lines.append("cpu \(cpu.map { String(format: "%.0f%%", $0) } ?? "–")  memory \(memoryMB.map { String(format: "%.0fMB", $0) } ?? "–")")
        return lines.joined(separator: "\n")
    }
}

/// Times the app's hot paths for the stress test (and Instruments, through signposts). Records nothing until
/// `recording` is on, so it costs next to nothing the rest of the time.
public final class PerfMeter {
    public enum Section: String, CaseIterable {
        /// Reading the session and job files.
        case load
        /// Handing a new set of sessions to the orb, pips, island and toasts.
        case sync
    }

    public enum Counter: String, CaseIterable {
        case event, orbFrame, glowFrame

        var label: String {
            switch self {
            case .event: "events"
            case .orbFrame: "orb fps"
            case .glowFrame: "glow fps"
            }
        }
    }

    public static let shared = PerfMeter()
    private static let signposter = OSSignposter(subsystem: "com.claudebubble.app", category: .pointsOfInterest)

    public let window: Double
    private let lock = NSLock()
    private var _recording = false
    private var samples: [Section: [(Date, Double)]] = [:]
    private var counts: [Counter: [(Date, Int)]] = [:]
    private var hitchSamples: [(Date, Double)] = []
    private var cpuMarks: [(Date, Double)] = []

    public init(window: Double = 5) { self.window = window }

    public var recording: Bool {
        get { lock.withLock { _recording } }
        set { lock.withLock { _recording = newValue; if !newValue { clear() } } }
    }

    @discardableResult
    public func measure<T>(_ section: Section, _ body: () throws -> T) rethrows -> T {
        let state = Self.signposter.beginInterval("perf", id: .exclusive, "\(section.rawValue, privacy: .public)")
        defer { Self.signposter.endInterval("perf", state) }
        guard recording else { return try body() }
        let start = CACurrentMediaTimeShim.now()
        let result = try body()
        record(section, seconds: CACurrentMediaTimeShim.now() - start)
        return result
    }

    public func record(_ section: Section, seconds: Double, at date: Date = Date()) {
        lock.withLock {
            guard _recording else { return }
            samples[section, default: []].append((date, seconds))
        }
    }

    public func count(_ counter: Counter, _ n: Int = 1, at date: Date = Date()) {
        lock.withLock {
            guard _recording else { return }
            counts[counter, default: []].append((date, n))
        }
    }

    public func hitch(_ seconds: Double, at date: Date = Date()) {
        lock.withLock {
            guard _recording else { return }
            hitchSamples.append((date, seconds))
        }
    }

    /// The last `window` seconds (and drops anything older).
    public func report(now: Date = Date()) -> PerfReport {
        lock.withLock {
            let cutoff = now.addingTimeInterval(-window)
            for key in samples.keys { samples[key]?.removeAll { $0.0 < cutoff } }
            for key in counts.keys { counts[key]?.removeAll { $0.0 < cutoff } }
            hitchSamples.removeAll { $0.0 < cutoff }
            let cpuTime = Self.cpuSeconds()
            if let cpuTime { cpuMarks.append((now, cpuTime)) }
            cpuMarks.removeAll { $0.0 < cutoff }
            var cpu: Double?
            if let first = cpuMarks.first, let last = cpuMarks.last, last.0 > first.0 {
                cpu = (last.1 - first.1) / last.0.timeIntervalSince(first.0) * 100
            }
            return PerfReport(window: window,
                              sections: samples.mapValues { PerfStats(samples: $0.map(\.1)) },
                              rates: counts.mapValues { Double($0.reduce(0) { $0 + $1.1 }) / window },
                              hitches: PerfStats(samples: hitchSamples.map(\.1)),
                              cpu: cpu, memoryMB: Self.footprintMB())
        }
    }

    private func clear() {
        samples = [:]
        counts = [:]
        hitchSamples = []
        cpuMarks = []
    }

    /// User + system CPU time this process has used.
    static func cpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    /// What Activity Monitor calls Memory.
    static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }
}

/// A monotonic clock without QuartzCore (Core stays Foundation-only).
enum CACurrentMediaTimeShim {
    static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
}
