// HyprMac Usage: a floating HUD that watches the running HyprMac from a separate process,
// so the numbers don't include the monitor itself. Build and launch:
//   bash scripts/build-usage-monitor.sh
//
// Sources, sampled every 250 ms:
//   lag     AX round trip (kAXRoleAttribute) to HyprMac; AX is served on its main thread.
//           Needs Accessibility for "HyprMac Usage".
//   cpu     proc_pid_rusage V4, user+system time delta over wall time.
//   memory  ri_phys_footprint.
//   switch  debug file log, "matched: switchWorkspace" to the focus hand-over
//           (or the last retile/frame attempt when nothing gets focused).

import AppKit
import ApplicationServices

let bundleIDs = ["com.zachgray.HyprMac.debug", "com.zachgray.HyprMac"]
let logPath = NSHomeDirectory() + "/Library/Logs/HyprMac/com.zachgray.HyprMac.debug.log"
let tick = 0.25
let holdSeconds = 60.0

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

/// Values from the last `holdSeconds`, for the held max and the chart.
struct Held {
    var items: [(t: Double, v: Double)] = []
    mutating func add(_ v: Double, at t: Double = nowMs()) {
        items.append((t, v))
        items.removeAll { t - $0.t > holdSeconds * 1000 }
    }
    var max: Double { items.map(\.v).max() ?? 0 }
}

// MARK: - Switch timing from the debug log

final class SwitchParser {
    struct Result: Equatable { let ms: Double; let frames: Int; let label: String }

    private var start: Date?
    private var lastEnd: Date?
    private var frames = 0
    private var label = ""
    private var lastFeed = Date.distantPast

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    func feed(_ line: Substring, wall: Date = Date()) -> Result? {
        guard let space = line.firstIndex(of: " "),
              let ts = Self.fmt.date(from: String(line[..<space])) else { return nil }
        if line.contains("matched: ") {
            let done = finish()
            if line.contains("matched: switchWorkspace") {
                start = ts; lastEnd = ts; frames = 0; label = ""; lastFeed = wall
            }
            return done
        }
        guard start != nil else { return nil }
        lastFeed = wall
        if let r = line.range(of: "] switch: ") {
            label = String(line[r.upperBound...].prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
        } else if line.contains("frame write:") && line.contains("steps=") {
            frames += 1
        } else if line.contains("(switchWorkspace") {
            lastEnd = ts
            return finish()
        }
        if line.contains("retile: ") || line.contains("frame attempt:") { lastEnd = ts }
        return nil
    }

    /// A switch that focuses nothing has no closing line; close it after 1 s of silence.
    func flushIfIdle(wall: Date = Date()) -> Result? {
        start != nil && wall.timeIntervalSince(lastFeed) > 1 ? finish() : nil
    }

    private func finish() -> Result? {
        guard let s = start, let e = lastEnd else { return nil }
        start = nil
        return Result(ms: (e.timeIntervalSince(s) * 1000).rounded(), frames: frames, label: label)
    }
}

final class LogTail {
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var partial = Data()

    func poll() -> [Substring] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.size] as? UInt64 else {
            handle = nil
            return []
        }
        if handle == nil {
            handle = FileHandle(forReadingAtPath: logPath)
            offset = size  // only new lines
        } else if size < offset {
            handle = FileHandle(forReadingAtPath: logPath)  // rotated or truncated
            offset = 0
        }
        guard let h = handle, size > offset else { return [] }
        try? h.seek(toOffset: offset)
        let data = h.readData(ofLength: Int(size - offset))
        offset += UInt64(data.count)
        partial.append(data)
        guard let nl = partial.lastIndex(of: 10) else { return [] }
        let text = String(decoding: partial[..<nl], as: UTF8.self)
        partial = Data(partial[(nl + 1)...])
        return text.split(separator: "\n")
    }
}

// MARK: - The watched process

final class Target {
    private(set) var pid: pid_t = 0
    private(set) var name = ""
    private var app: AXUIElement?
    private var lastCPU = 0.0, lastWall = 0.0
    private let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    // AX probe state, touched on main only.
    private var probeStart = 0.0
    private(set) var lastLag = 0.0
    private(set) var axDenied = false
    private let axQueue = DispatchQueue(label: "usage.ax")

    func resolve() {
        if pid != 0, kill(pid, 0) == 0 { return }
        pid = 0; app = nil
        for id in bundleIDs {
            guard let a = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { continue }
            pid = a.processIdentifier
            name = a.localizedName ?? id
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 5)
            app = el
            lastWall = 0
            return
        }
    }

    /// CPU % since the last call and the physical footprint in MB.
    func usage() -> (cpu: Double, mb: Double)? {
        guard pid != 0 else { return nil }
        var ri = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        let cpu = Double(ri.ri_user_time + ri.ri_system_time) * timebase / 1e6  // mach units → ms
        let wall = nowMs()
        defer { lastCPU = cpu; lastWall = wall }
        let pct = lastWall == 0 ? 0 : max(0, cpu - lastCPU) / (wall - lastWall) * 100
        return (pct, Double(ri.ri_phys_footprint) / 1_048_576)
    }

    /// Starts an AX round trip unless one is still waiting on HyprMac's main thread.
    func probe() {
        guard probeStart == 0, let app else { return }
        let started = nowMs()
        probeStart = started
        axQueue.async {
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &value)
            let ms = nowMs() - started
            DispatchQueue.main.async {
                self.axDenied = err == .apiDisabled
                if !self.axDenied { self.lastLag = ms }
                self.probeStart = 0
            }
        }
    }

    /// The last round trip, or the one still in flight once it runs longer.
    var lag: Double { probeStart == 0 ? lastLag : max(lastLag, nowMs() - probeStart) }
}

// MARK: - HUD

let red = NSColor.systemRed
let dim = NSColor.secondaryLabelColor

final class Row {
    let value = NSTextField(labelWithString: "—")
    let peak = NSTextField(labelWithString: "")
    let view: NSStackView

    init(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.textColor = dim
        label.font = .systemFont(ofSize: 11)
        label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 128).isActive = true
        peak.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        peak.alignment = .right
        peak.widthAnchor.constraint(equalToConstant: 64).isActive = true
        view = NSStackView(views: [label, value, peak])
        view.spacing = 6
    }

    func show(_ text: String, hot: Bool, peak p: String, peakHot: Bool) {
        value.stringValue = text
        value.textColor = hot ? red : .labelColor
        peak.stringValue = p
        peak.textColor = peakHot ? red : dim
    }
}

final class ChartView: NSView {
    var lag = Held()
    let threshold = 100.0

    override func draw(_ dirtyRect: NSRect) {
        let top = max(250, lag.max * 1.1)
        let y = { (v: Double) in self.bounds.minY + CGFloat(min(v, top) / top) * self.bounds.height }
        let barW = bounds.width / CGFloat(holdSeconds / tick)
        let now = nowMs()
        for item in lag.items {
            let x = bounds.maxX - CGFloat((now - item.t) / (tick * 1000)) * barW
            (item.v > threshold ? red : NSColor.systemGreen.withAlphaComponent(0.8)).setFill()
            NSRect(x: x - barW, y: bounds.minY, width: max(barW - 0.5, 1), height: max(y(item.v) - bounds.minY, 1)).fill()
        }
        let line = NSBezierPath()
        line.move(to: NSPoint(x: bounds.minX, y: y(threshold)))
        line.line(to: NSPoint(x: bounds.maxX, y: y(threshold)))
        line.setLineDash([3, 3], count: 2, phase: 0)
        dim.setStroke()
        line.stroke()
        let caption = "\(Int(top)) ms · 60 s"
        caption.draw(at: NSPoint(x: bounds.minX + 2, y: bounds.maxY - 12),
                     withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: dim])
    }
}

final class HUD: NSObject, NSApplicationDelegate {
    let target = Target()
    let tail = LogTail()
    let parser = SwitchParser()
    let header = NSTextField(labelWithString: "")
    let lagRow = Row("lag"), cpuRow = Row("CPU"), memRow = Row("memory"), switchRow = Row("switch")
    let chart = ChartView()
    var cpu = Held(), mem = Held(), switches = Held()
    var lastSwitch: SwitchParser.Result?
    var panel: NSPanel!

    func applicationDidFinishLaunching(_ note: Notification) {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)

        header.font = .systemFont(ofSize: 10)
        header.textColor = dim
        chart.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let stack = NSStackView(views: [header, lagRow.view, cpuRow.view, memRow.view, switchRow.view, chart])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        chart.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit HyprMac Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        blur.menu = menu

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 190),
                        styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = blur
        if !panel.setFrameUsingName("HyprMacUsage"), let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - 296, y: vf.minY + 16))
        }
        panel.setFrameAutosaveName("HyprMacUsage")
        panel.orderFrontRegardless()

        Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    func update() {
        target.resolve()
        for line in tail.poll() { if let r = parser.feed(line) { record(r) } }
        if let r = parser.flushIfIdle() { record(r) }

        guard target.pid != 0, let u = target.usage() else {
            header.stringValue = "HyprMac not running"
            return
        }
        header.stringValue = "\(target.name) · pid \(target.pid)"

        target.probe()
        if target.axDenied {
            lagRow.show("no AX access", hot: true, peak: "", peakHot: false)
        } else {
            let lag = target.lag
            chart.lag.add(lag)
            lagRow.show(String(format: "%.0f ms", lag), hot: lag > 100,
                        peak: String(format: "max %.0f", chart.lag.max), peakHot: chart.lag.max > 100)
        }
        cpu.add(u.cpu)
        mem.add(u.mb)
        cpuRow.show(String(format: "%.1f %%", u.cpu), hot: u.cpu > 50,
                    peak: String(format: "max %.0f", cpu.max), peakHot: cpu.max > 50)
        memRow.show(String(format: "%.0f MB", u.mb), hot: u.mb > 300,
                    peak: String(format: "max %.0f", mem.max), peakHot: mem.max > 300)
        switches.add(0)  // keeps the 60 s window moving between switches
        if let s = lastSwitch {
            let peak = switches.max
            switchRow.show(String(format: "%.0f ms · %d fr", s.ms, s.frames), hot: s.ms > 300,
                           peak: String(format: "max %.0f", peak), peakHot: peak > 300)
            switchRow.value.toolTip = s.label
        }
        chart.needsDisplay = true
    }

    func record(_ r: SwitchParser.Result) {
        lastSwitch = r
        switches.add(r.ms)
    }
}

// MARK: - Entry

/// Checks the switch parser on real log lines from 2026-10-28.
func selfTest() {
    let p = SwitchParser()
    let wall = Date()
    let focused = """
    2026-10-28T14:41:29.230+0100 [debug] [lifecycle] matched: switchWorkspace
    2026-10-28T14:41:29.277+0100 [notice] [lifecycle] switch: C34H89x ws8→ws6 (hide 0, show 1)
    2026-10-28T14:41:29.277+0100 [debug] [lifecycle] retile: workspace=6 screen=0, 1 windows
    2026-10-28T14:41:29.334+0100 [debug] [tiling] frame write: wid=86 phase=candidate steps=position:0/4ms complete=true
    2026-10-28T14:41:29.372+0100 [debug] [tiling] frame attempt: phase=candidate gen=514 wids=[86] verdict=accepted
    2026-10-28T14:41:29.388+0100 [debug] [focus] focus 80 → 86 (switchWorkspace-after-show)
    """
    let r1 = focused.split(separator: "\n").compactMap { p.feed($0, wall: wall) }
    precondition(r1 == [.init(ms: 158, frames: 1, label: "C34H89x ws8→ws6")], "\(r1)")

    let hideOnly = """
    2026-10-28T14:41:28.396+0100 [debug] [lifecycle] matched: switchWorkspace
    2026-10-28T14:41:28.438+0100 [notice] [lifecycle] switch: C34H89x ws7→ws8 (hide 1, show 0)
    2026-10-28T14:41:28.494+0100 [debug] [tiling] frame attempt: phase=candidate gen=513 wids=[78] verdict=accepted in place
    """
    precondition(hideOnly.split(separator: "\n").compactMap { p.feed($0, wall: wall) }.isEmpty)
    precondition(p.flushIfIdle(wall: wall) == nil)
    let r2 = p.flushIfIdle(wall: wall.addingTimeInterval(2))
    precondition(r2?.frames == 0 && r2?.label == "C34H89x ws7→ws8" && abs(r2!.ms - 98) < 0.5, "\(String(describing: r2))")
    print("selftest ok")
}

if CommandLine.arguments.contains("--selftest") {
    selfTest()
    exit(0)
}
let hud = HUD()
NSApplication.shared.delegate = hud
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
