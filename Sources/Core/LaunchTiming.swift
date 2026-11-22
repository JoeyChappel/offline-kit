import Foundation

#if DEBUG
/// Debug-only launch timing: how long from the process starting to the main window's first onAppear.
/// Logged once as "LAUNCH first onAppear <ms> ms since process start".
enum LaunchTiming {
    nonisolated(unsafe) private static var logged = false

    /// Milliseconds since this process was created (kernel start time, so it includes dyld and the App init).
    static func millisecondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let startSeconds = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - startSeconds) * 1000
    }

    /// Logs a named step with the time since process start, to see where the time before the first frame goes.
    static func mark(_ step: String) {
        if let ms = millisecondsSinceProcessStart() { NSLog("LAUNCH %@ at %.0f ms", step, ms) }
    }

    /// Call from the main window's onAppear. Only the first call logs.
    static func firstAppear() {
        guard !logged else { return }
        logged = true
        if let ms = millisecondsSinceProcessStart() { NSLog("LAUNCH first onAppear %.0f ms since process start", ms) }
    }

    nonisolated(unsafe) private static var shelfLogged = false
    /// Call when the first shelf row appears on screen. Only the first call logs.
    static func firstShelf() {
        guard !shelfLogged else { return }
        shelfLogged = true
        mark("first shelf on screen")
    }
}

/// Debug-only main-thread stall meter for profiling runs (test home only). A 4 ms timer on the main queue notes how
/// late each firing is; `report` logs, for the time since the last report, the stall total, the longest stall and how
/// many gaps were longer than two frames. Used by the -cycleSections hook.
@MainActor
enum StallProbe {
    private static var timer: DispatchSourceTimer?
    private static var last = DispatchTime.now().uptimeNanoseconds
    private static var gaps: [Double] = []
    private static var mainThread = mach_port_t()
    private static var lastCPU = 0.0

    /// Main-thread CPU time (user + system) so far, in ms. Unlike wall-clock stalls it doesn't move when other
    /// processes compete for the machine, so before/after runs compare.
    private static func cpuMilliseconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(mainThread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        func ms(_ t: time_value_t) -> Double { Double(t.seconds) * 1000 + Double(t.microseconds) / 1000 }
        return ms(info.user_time) + ms(info.system_time)
    }

    static func start() {
        guard timer == nil else { return }
        last = DispatchTime.now().uptimeNanoseconds
        mainThread = mach_thread_self()
        lastCPU = cpuMilliseconds()
        NSLog("STALL main-thread CPU since launch: %.0f ms", lastCPU)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler {
            let now = DispatchTime.now().uptimeNanoseconds
            let gap = Double(now - last) / 1_000_000
            last = now
            if gap > 12 { gaps.append(gap - 4) }
        }
        t.resume()
        timer = t
    }

    /// Logs and clears. Stall = main-thread time beyond the 4 ms tick (gaps over 12 ms only).
    static func report(_ label: String) {
        let total = gaps.reduce(0, +), longest = gaps.max() ?? 0
        let hitches = gaps.filter { $0 > 33 }.count
        let cpu = cpuMilliseconds()
        NSLog("STALL %@ total=%.0f ms longest=%.0f ms over33=%d cpu=%.0f", label, total, longest, hitches, cpu - lastCPU)
        lastCPU = cpu
        gaps.removeAll()
    }
}
#endif
