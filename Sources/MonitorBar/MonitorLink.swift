import Foundation
import MonitorCore

/// Owns the connection to the monitor and does all the slow talking on one background queue, so
/// the panel never freezes and two requests never collide on the wire.
///
/// "No monitor" is a normal state: the control channel disappears for a few seconds whenever the
/// display reconnects or changes mode. If a request fails, the link looks the monitor up again
/// once and retries before reporting failure.
final class MonitorLink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "uk.co.instadesign.monitor-bar.link", qos: .userInitiated)
    private var monitor: Monitor?  // only touched on `queue`

    /// Drop the current handle (after a display change); the next request looks it up afresh.
    func forget() {
        queue.async { self.monitor = nil }
    }

    private func connect() -> Monitor? {
        if monitor == nil { monitor = Monitor.waitForAll(timeout: 4).first }
        return monitor
    }

    private func attempt<T>(_ op: (Monitor) -> T?) -> T? {
        let hadHandle = monitor != nil
        if let m = connect(), let r = op(m) { return r }
        monitor = nil
        guard hadHandle else { return nil }  // a fresh lookup already failed
        if let m = connect(), let r = op(m) { return r }
        monitor = nil
        return nil
    }

    /// Read each code in turn. `each` and `done` are called on the main queue.
    /// `done(true)` means the monitor answered at least once.
    func read(_ codes: [UInt8], each: @escaping (UInt8, VCPReading?) -> Void, done: @escaping (Bool) -> Void) {
        queue.async {
            var answered = false
            for code in codes {
                let r = self.attempt { $0.read(code) }
                if r != nil { answered = true }
                DispatchQueue.main.async { each(code, r) }
                if r == nil && self.monitor == nil { break }  // the monitor has gone; stop asking
            }
            DispatchQueue.main.async { done(answered) }
        }
    }

    /// Write one value. `done` is called on the main queue.
    func write(_ code: UInt8, _ value: Int, done: @escaping (Bool) -> Void) {
        queue.async {
            let ok = self.attempt { $0.write(code, value) ? true : nil } ?? false
            DispatchQueue.main.async { done(ok) }
        }
    }
}
