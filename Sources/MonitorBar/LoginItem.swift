import AppKit
import ServiceManagement

/// "Open at login", using macOS's own login-items list (System Settings › General › Login Items).
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    /// Only the copy in an Applications folder should ever become the login item, not a build copy.
    var isInstalled: Bool { Bundle.main.bundlePath.contains("/Applications/") }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("MonitorBar login item: could not \(on ? "register" : "unregister"): \(error)")
        }
        refresh()
        NSLog("MonitorBar login item: status is now \(status.rawValue) (0 not registered, 1 enabled, 2 needs approval, 3 not found)")
    }

    /// Start at login is on by default: switch it on the first time the installed copy runs.
    /// After that the checkbox in the panel is in charge.
    func switchOnFirstTime() {
        let key = "loginItemSwitchedOnOnce"
        guard isInstalled, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
