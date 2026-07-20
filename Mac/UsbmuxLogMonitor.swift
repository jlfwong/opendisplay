#if os(macOS)
import Foundation
import os

/// Tails `usbmuxd` unified-log output when LogPackets is enabled and emits
/// Points-of-Interest signposts (Instruments) plus a ring buffer for Perfetto.
///
/// Time base: Mac wall-clock ms from each log line's timestamp — the same basis
/// as trace spans (`Date().timeIntervalSince1970 * 1000`). Enable logging once:
///   sudo scripts/enable-usbmux-logpackets.sh
enum UsbmuxLogMonitor {

    private static let log = OSLog(subsystem: "com.peetzweg.opensidecar.mac",
                                 category: OSLog.Category.pointsOfInterest)
    private static let workQueue = DispatchQueue(label: "usbmux.log.monitor", qos: .utility)
    private static var process: Process?
    private static var running = false
    private static var events: [UsbmuxLogEvent] = []
    private static let maxEvents = 100_000
    private static let lock = NSLock()
    private static var lineRemainder = ""
    private static var totalParsed = 0

    /// Whether `/Library/Preferences/com.apple.usbmuxd.plist` enables packet logging.
    /// Both DebugLevel ≥ 7 and LogPackets are required for seq/ack/win lines in unified log.
    static var logPacketsEnabled: Bool {
        let path = "/Library/Preferences/com.apple.usbmuxd.plist"
        guard let plist = NSDictionary(contentsOf: URL(fileURLWithPath: path)) else { return false }
        let packets = (plist["LogPackets"] as? Bool) == true
            || (plist["LogPackets"] as? Int) == 1
        let level = (plist["DebugLevel"] as? Int) ?? 0
        return packets && level >= 7
    }

    /// Start tailing on pencil-down / trace start; discard any prior buffer.
    static func beginSession() {
        workQueue.async {
            clearBufferLocked()
            guard logPacketsEnabled else {
                Log.info("[usbmux-log] usbmux prefs incomplete — need DebugLevel≥7 and LogPackets (scripts/enable-usbmux-logpackets.sh)")
                return
            }
            if running { return }
            startProcessLocked()
        }
    }

    static func bufferedEventCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    static func stop() {
        workQueue.async {
            stopProcessLocked()
        }
    }

    /// Events whose log timestamp falls in [startMs, endMs] (Mac wall clock).
    static func snapshot(from startMs: Double, to endMs: Double) -> [UsbmuxLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0.timeMs >= startMs && $0.timeMs <= endMs }
    }

    // MARK: - Process

    private static func startProcessLocked() {
        stopProcessLocked()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream",
            "--predicate", "process == \"usbmuxd\"",
            "--style", "compact",
            "--info", "--debug",
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.terminationHandler = { _ in
            workQueue.async {
                if running {
                    Log.info("[usbmux-log] log stream exited — restarting in 2s")
                    stopProcessLocked()
                    workQueue.asyncAfter(deadline: .now() + 2) { startProcessLocked() }
                }
            }
        }
        do {
            try proc.run()
            process = proc
            running = true
            Log.info("[usbmux-log] streaming usbmuxd LogPackets → POI + Perfetto buffer")
            readLoop(from: pipe.fileHandleForReading)
        } catch {
            Log.info("[usbmux-log] failed to start log stream: \(error)")
        }
    }

    private static func stopProcessLocked() {
        running = false
        process?.terminate()
        process = nil
    }

    private static func readLoop(from handle: FileHandle) {
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            ingestChunk(chunk)
        }
    }

    private static func ingestChunk(_ chunk: String) {
        var text = lineRemainder + chunk
        lineRemainder = ""
        while let nl = text.firstIndex(of: "\n") {
            let line = String(text[..<nl])
            text = String(text[text.index(after: nl)...])
            parseLine(line)
        }
        lineRemainder = text
    }

    private static func clearBufferLocked() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        totalParsed = 0
        lineRemainder = ""
        lock.unlock()
    }

    // MARK: - Parse

    /// Compact: `2026-07-19 19:06:05.071 Db usbmuxd[…] [com.apple.usbmux:daemon] IN … 60815->14338 32728/32748 … seq=… ack=… win=…`
    private static let compactPrefix = try? NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3,6})"#)
    private static let seqAckWin = try? NSRegularExpression(
        pattern: #"seq=(\d+).*?ack=(\d+).*?win=(\d+)"#)
    /// Apple shipping usbmuxd (LogPackets): `] IN … sport->dport bytes/cap`
    private static let applePacket = try? NSRegularExpression(
        pattern: #"\]\s+(IN|OUT)\s+\S+\s+\S+\s+(\d+)->(\d+)\s+(\d+)/(\d+)"#)
    /// Legacy open-source clone format: `[IN] … len=N`
    private static let legacyPacket = try? NSRegularExpression(
        pattern: #"\[(IN|OUT)\].*?(\d+)->(\d+).*?len=(\d+)"#)
    private static let sendWindow = try? NSRegularExpression(
        pattern: #"send window (\d+) -> (\d+)"#)

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func parseLine(_ line: String) {
        guard !line.isEmpty else { return }
        guard line.contains("seq=") || line.contains("send window")
            || line.contains(" IN ") || line.contains(" OUT ")
            || line.contains("[IN]") || line.contains("[OUT]") else { return }

        let timeMs: Double
        if let re = compactPrefix,
           let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let r = Range(m.range(at: 1), in: line) {
            let ts = String(line[r])
            let frac = ts.split(separator: ".", maxSplits: 1).last.map(String.init) ?? "0"
            let normalized = frac.count > 3
                ? ts.replacingOccurrences(of: ".\(frac)", with: ".\(String(frac.prefix(3)))")
                : ts
            if let date = tsFormatter.date(from: normalized) {
                timeMs = date.timeIntervalSince1970 * 1000
            } else {
                timeMs = Date().timeIntervalSince1970 * 1000
            }
        } else {
            timeMs = Date().timeIntervalSince1970 * 1000
        }

        var direction = "?"
        var seq: UInt32?
        var ack: UInt32?
        var win: UInt32?
        var len: Int?
        var sport: Int?
        var dport: Int?

        if let re = applePacket,
           let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let r = Range(m.range(at: 1), in: line) { direction = String(line[r]).lowercased() }
            if let r = Range(m.range(at: 2), in: line) { sport = Int(line[r]) }
            if let r = Range(m.range(at: 3), in: line) { dport = Int(line[r]) }
            if let r = Range(m.range(at: 4), in: line) { len = Int(line[r]) }
        } else if let re = legacyPacket,
                  let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let r = Range(m.range(at: 1), in: line) { direction = String(line[r]).lowercased() }
            if let r = Range(m.range(at: 2), in: line) { sport = Int(line[r]) }
            if let r = Range(m.range(at: 3), in: line) { dport = Int(line[r]) }
            if let r = Range(m.range(at: 4), in: line) { len = Int(line[r]) }
        } else if line.contains("send window") {
            direction = "win"
        }

        if let re = seqAckWin,
           let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let r = Range(m.range(at: 1), in: line) { seq = UInt32(line[r]) }
            if let r = Range(m.range(at: 2), in: line) { ack = UInt32(line[r]) }
            if let r = Range(m.range(at: 3), in: line) { win = UInt32(line[r]) }
        }

        if let re = sendWindow,
           let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let r1 = Range(m.range(at: 1), in: line),
           let r2 = Range(m.range(at: 2), in: line) {
            win = UInt32(line[r1])
            len = Int(line[r2])
        }

        let ev = UsbmuxLogEvent(timeMs: timeMs, direction: direction,
                                seq: seq, ack: ack, win: win, len: len,
                                sport: sport, dport: dport,
                                raw: String(line.prefix(240)))
        record(ev)
    }

    private static func record(_ ev: UsbmuxLogEvent) {
        lock.lock()
        events.append(ev)
        totalParsed += 1
        let count = totalParsed
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        lock.unlock()
        if count == 1 {
            Log.info("[usbmux-log] first packet parsed dir=\(ev.direction) seq=\(ev.seq ?? 0) ports=\(ev.sport ?? 0)->\(ev.dport ?? 0)")
        }

        let id = OSSignpostID(log: log)
        if let seq = ev.seq, let win = ev.win {
            os_signpost(.event, log: log, name: "UsbmuxPacket", signpostID: id,
                        "dir=%{public}s seq=%{public}u win=%{public}u len=%{public}d",
                        ev.direction, seq, win, ev.len ?? 0)
        } else if ev.direction == "win", let win = ev.win {
            os_signpost(.event, log: log, name: "UsbmuxWindow", signpostID: id,
                        "win=%{public}u sendable=%{public}d", win, ev.len ?? 0)
        }
    }
}
#endif
