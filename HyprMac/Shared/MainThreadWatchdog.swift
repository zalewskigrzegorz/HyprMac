// Logs when the main thread stops answering. Every freeze a user feels is
// the main thread blocked (a slow AX call, a busy WindowServer), so this
// one probe sees all of them, whatever caused them.

import Foundation

/// Stall bookkeeping without threads or clocks, so the timing rules are
/// testable. Confined to the watchdog queue.
struct MainThreadStallTracker {
    let threshold: TimeInterval
    private var pingSentAt: TimeInterval?
    private var nextReport: TimeInterval = 0

    init(threshold: TimeInterval) {
        self.threshold = threshold
    }

    /// One watchdog tick. `sendPing` asks the caller to queue a ping on
    /// main. `blocked` is how long main has been silent, set only when a
    /// report is due: at the threshold, then at 4x, 16x, ... so a long
    /// hang leaves a trail even if the process never recovers.
    mutating func tick(at now: TimeInterval) -> (sendPing: Bool, blocked: TimeInterval?) {
        guard let sent = pingSentAt else {
            pingSentAt = now
            nextReport = threshold
            return (true, nil)
        }
        let age = now - sent
        guard age >= nextReport else { return (false, nil) }
        nextReport *= 4
        return (false, age)
    }

    /// The ping ran on main at `now`. Returns the stall length when it
    /// crossed the threshold.
    mutating func pong(at now: TimeInterval) -> TimeInterval? {
        guard let sent = pingSentAt else { return nil }
        pingSentAt = nil
        let age = now - sent
        return age >= threshold ? age : nil
    }
}

/// Pings the main queue every 250 ms from a background queue and logs
/// `.error` lines under `perf` when a ping waits 500 ms or more:
/// `main thread blocked …` while it lasts, `main thread stalled …` once
/// it ends. Each line carries the last log line main wrote, which is
/// usually the operation that blocked.
///
/// The clock is `systemUptime`, which stops during sleep, so a sleeping
/// Mac does not read as a stall.
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "com.zachgray.HyprMac.watchdog", qos: .userInitiated)

    // queue-confined
    private var timer: DispatchSourceTimer?
    private var tracker = MainThreadStallTracker(threshold: 0.5)
    private var lastSampleAt: TimeInterval = -.infinity

    private static let lastLineLock = NSLock()
    private static var lastLine: (at: TimeInterval, category: LogCategory, text: String)?

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Called by `hyprLog` for every rendered line written on main.
    static func noteMainThreadLine(_ category: LogCategory, _ text: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lastLineLock.lock()
        lastLine = (now, category, text)
        lastLineLock.unlock()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let (sendPing, blocked) = tracker.tick(at: now)
        if let blocked {
            hyprLog(.error, .perf, "main thread blocked \(Self.ms(blocked)) ms so far — \(Self.lastMainLine(now: now))")
            if blocked >= 2 { sampleMainStack(now: now) }
        }
        guard sendPing else { return }
        DispatchQueue.main.async { [weak self] in
            let at = ProcessInfo.processInfo.systemUptime
            self?.queue.async { self?.pong(at: at) }
        }
    }

    private func pong(at now: TimeInterval) {
        guard let stall = tracker.pong(at: now) else { return }
        hyprLog(.error, .perf, "main thread stalled \(Self.ms(stall)) ms — \(Self.lastMainLine(now: now))")
    }

    /// The last log line only hints at the culprit; a stack shows where main
    /// actually waits. One 1 s `sample` run, at most every 5 min. It needs
    /// get-task-allow, so it works in Debug builds and fails in release.
    private func sampleMainStack(now: TimeInterval) {
        guard now - lastSampleAt >= 300 else { return }
        lastSampleAt = now
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime])
        let path = NSHomeDirectory() + "/Library/Logs/HyprMac/stall-\(stamp).txt"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), "1", "-mayDie", "-file", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { p in
            hyprLog(.error, .perf, p.terminationStatus == 0
                ? "main stack sample written to \(path)"
                : "main stack sample failed with exit \(p.terminationStatus)")
        }
        do {
            try process.run()
        } catch {
            hyprLog(.error, .perf, "main stack sample failed to start: \(error.localizedDescription)")
        }
    }

    private static func lastMainLine(now: TimeInterval) -> String {
        lastLineLock.lock()
        let line = lastLine
        lastLineLock.unlock()
        guard let line else { return "no main-thread log yet" }
        return "last main log \(ms(now - line.at)) ms earlier: [\(line.category.rawValue)] \(line.text.prefix(200))"
    }

    private static func ms(_ seconds: TimeInterval) -> Int { Int(seconds * 1000) }
}
