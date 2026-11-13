// monitorctl: control an external monitor's own settings from the Mac over DDC/CI.
// Built 13 Nov 2026 for the UPERFECT 4K OLED portable monitor (Realtek controller) whose
// buttons stopped working. Apple Silicon only (uses the display's USB-C/DisplayPort channel).
//
// The protocol code lives in MonitorCore, shared with the Monitor Bar menu-bar app.
// Build with ./build.sh from the project folder.
import Foundation
import MonitorCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

struct Setting { let name: String; let code: UInt8; let label: String; let note: String }

let settings: [Setting] = [
    Setting(name: "brightness", code: VCPCode.brightness, label: "Brightness", note: "0-100"),
    Setting(name: "contrast", code: VCPCode.contrast, label: "Contrast", note: "0-100"),
    Setting(name: "volume", code: VCPCode.volume, label: "Volume", note: "0-100"),
    Setting(name: "sharpness", code: VCPCode.sharpness, label: "Sharpness", note: "0-4"),
    Setting(name: "preset", code: VCPCode.colourPreset, label: "Colour preset", note: "1-11 (11 = user)"),
    Setting(name: "red", code: VCPCode.redGain, label: "Red gain", note: "0-100"),
    Setting(name: "green", code: VCPCode.greenGain, label: "Green gain", note: "0-100"),
    Setting(name: "blue", code: VCPCode.blueGain, label: "Blue gain", note: "0-100"),
    Setting(name: "language", code: VCPCode.menuLanguage, label: "Menu language", note: "1-13 (2 = English)"),
    Setting(name: "osd", code: VCPCode.menuState, label: "Menu/buttons state", note: "1 or 2"),
    Setting(name: "power", code: VCPCode.powerMode, label: "Power mode", note: "1 = on, 4 = standby, 5 = off"),
]

func usage() -> Never {
    var text = """
    monitorctl: control the external monitor's own settings from the Mac.

      monitorctl status                 show the current settings
      monitorctl <setting>              show one setting
      monitorctl <setting> <value>      set it (a number, or +10 / -10 to step)
      monitorctl get <code>             read any setting by its hex code, e.g. get 10
      monitorctl set <code> <value>     write any setting by its hex code
      monitorctl scan                   list every code the monitor supports
      monitorctl reset <what> --yes     factory reset: all, brightness, geometry or colour
      monitorctl save                   ask the monitor to store the current settings

    Settings:

    """
    for s in settings { text += "  \(s.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(s.label) (\(s.note))\n" }
    print(text)
    exit(0)
}

func parseHex(_ s: String) -> UInt8 {
    let t = s.lowercased().hasPrefix("0x") ? String(s.dropFirst(2)) : s
    guard let v = UInt8(t, radix: 16) else { fail("'\(s)' is not a hex code between 00 and FF.") }
    return v
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, command != "help", command != "-h", command != "--help" else { usage() }

let monitors = Monitor.waitForAll(timeout: 4)
guard let monitor = monitors.first else { fail("No external monitor with a control channel was found. Is it plugged in over USB-C?") }
if monitors.count > 1 { FileHandle.standardError.write("Note: \(monitors.count) external monitors found; using the first.\n".data(using: .utf8)!) }

func read(_ code: UInt8) -> VCPReading {
    guard let v = monitor.read(code) else { fail(String(format: "The monitor did not answer for code %02X.", code)) }
    guard v.supported else { fail(String(format: "The monitor does not support code %02X.", code)) }
    return v
}

func write(_ code: UInt8, _ value: Int, label: String) {
    guard monitor.write(code, value) else { fail("The write to the monitor failed.") }
    usleep(150000)
    if let after = monitor.read(code), after.supported {
        print("\(label): now \(after.current)" + (after.max > 0 ? " of \(after.max)" : "") + (after.current == value ? "" : " (asked for \(value))"))
    } else {
        print("\(label): sent \(value) (the monitor gave no read-back)")
    }
}

switch command {
case "status":
    for s in settings {
        if let v = monitor.read(s.code), v.supported {
            print("\(s.label.padding(toLength: 20, withPad: " ", startingAt: 0)) \(v.current)" + (v.max > 0 ? " of \(v.max)" : ""))
        }
    }
case "scan":
    var found: [String] = []
    for code in 0...255 {
        if let v = monitor.read(UInt8(code)), v.supported { found.append(String(format: "%02X=%d/%d", code, v.current, v.max)) }
    }
    print("Supported codes (code=current/max):\n" + found.joined(separator: "  "))
case "get":
    guard args.count == 2 else { usage() }
    let code = parseHex(args[1]); let v = read(code)
    print(String(format: "%02X: current %d, max %d", code, v.current, v.max))
case "set":
    guard args.count == 3, let value = Int(args[2]), (0...65535).contains(value) else { usage() }
    let code = parseHex(args[1])
    write(code, value, label: String(format: "Code %02X", code))
case "reset":
    guard args.count >= 2, let reset = FactoryReset(rawValue: args[1]) else { fail("Say what to reset: all, brightness, geometry or colour.") }
    guard args.contains("--yes") else { fail("This restores the factory defaults for \(reset.what). Add --yes to go ahead.") }
    guard monitor.write(reset.code, 1) else { fail("The write to the monitor failed.") }
    print("Sent: restore factory defaults for \(reset.what).")
case "save":
    guard monitor.saveSettings() else { fail("The write to the monitor failed.") }
    print("Sent: save current settings.")
default:
    guard let s = settings.first(where: { $0.name == command }) else { fail("Unknown command '\(command)'. Run 'monitorctl help'.") }
    let current = read(s.code)
    guard args.count >= 2 else {
        print("\(s.label): \(current.current)" + (current.max > 0 ? " of \(current.max)" : ""))
        break
    }
    let raw = args[1]
    var target: Int
    if raw.hasPrefix("+") || raw.hasPrefix("-") {
        guard let step = Int(raw) else { fail("'\(raw)' is not a number.") }
        target = current.current + step
    } else {
        guard let v = Int(raw) else { fail("'\(raw)' is not a number.") }
        target = v
    }
    if current.max > 0 { target = min(max(target, 0), current.max) }
    write(s.code, target, label: s.label)
}
