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
}
#endif
