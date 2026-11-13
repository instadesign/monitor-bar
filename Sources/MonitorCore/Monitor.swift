// MonitorCore: talk to an external monitor's own settings over DDC/CI.
//
// Moved unchanged from the original monitorctl.swift (13 Nov 2026), which was tested against the
// UPERFECT 4K OLED portable monitor (Realtek controller). Apple Silicon only: it uses the display's
// USB-C/DisplayPort channel through three private IOKit functions.
//
// Everything here is blocking (each read or write takes 60-100 ms). Call it from one background
// thread at a time, never from the main thread of an app.
import Foundation
import IOKit

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32, _ outputBuffer: UnsafeMutableRawPointer, _ outputBufferSize: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32, _ inputBuffer: UnsafeMutableRawPointer, _ inputBufferSize: UInt32) -> IOReturn

private let chip: UInt32 = 0x37
private let host: UInt32 = 0x51

/// One reading of a setting. `supported` is false when the monitor says it doesn't have that code.
public struct VCPReading: Sendable, Equatable {
    public let supported: Bool
    public let max: Int
    public let current: Int
}

/// The setting codes this monitor answers to (see the brief for the full table).
public enum VCPCode {
    public static let brightness: UInt8 = 0x10
    public static let contrast: UInt8 = 0x12
    public static let colourPreset: UInt8 = 0x14
    public static let redGain: UInt8 = 0x16
    public static let greenGain: UInt8 = 0x18
    public static let blueGain: UInt8 = 0x1A
    public static let volume: UInt8 = 0x62
    public static let redBlackLevel: UInt8 = 0x6C
    public static let greenBlackLevel: UInt8 = 0x6E
    public static let blueBlackLevel: UInt8 = 0x70
    public static let sharpness: UInt8 = 0x87
    public static let menuState: UInt8 = 0xCA
    public static let menuLanguage: UInt8 = 0xCC
    public static let powerMode: UInt8 = 0xD6
}

/// The factory resets. Each is sent by writing 1 to its code.
public enum FactoryReset: String, CaseIterable, Sendable {
    case all, brightness, geometry, colour

    public var code: UInt8 {
        switch self {
        case .all: return 0x04
        case .brightness: return 0x05
        case .geometry: return 0x06
        case .colour: return 0x08
        }
    }

    /// What it restores, in words: "This restores the factory defaults for <what>."
    public var what: String {
        switch self {
        case .all: return "all settings"
        case .brightness: return "brightness and contrast"
        case .geometry: return "picture geometry"
        case .colour: return "colour"
        }
    }
}

/// One external monitor's control channel.
public final class Monitor {
    private let service: CFTypeRef

    private init(service: CFTypeRef) { self.service = service }

    /// Every external monitor with a control channel, found right now.
    public static func all() -> [Monitor] {
        var out: [Monitor] = []
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, s)?.takeRetainedValue() {
                out.append(Monitor(service: av))
            }
        }
        return out
    }

    /// Whether an external monitor's control channel exists right now. Cheap: it only looks in
    /// the I/O Registry and doesn't talk to the monitor.
    public static func isPresent() -> Bool {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            if IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String == "External" {
                return true
            }
        }
        return false
    }

    /// The control channel vanishes for a few seconds whenever the display reconnects or changes
    /// mode, so look again every half second for up to `timeout` seconds before giving up.
    public static func waitForAll(timeout: TimeInterval = 4) -> [Monitor] {
        var found = all()
        var waited: TimeInterval = 0
        while found.isEmpty && waited < timeout {
            usleep(500_000)
            waited += 0.5
            found = all()
        }
        return found
    }

    private func xor(_ seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 { bytes.reduce(seed) { $0 ^ $1 } }

    /// Send a DDC/CI request body (opcode + arguments). Reads `replyLen` bytes back when it is above zero.
    private func transact(body: [UInt8], replyLen: Int, quirkSeed: Bool = false, wait: useconds_t = 60000) -> [UInt8]? {
        var packet: [UInt8] = [UInt8(0x80 | body.count)] + body
        packet.append(xor(quirkSeed ? 0x6E : 0x6E ^ 0x51, packet[...]))
        for _ in 0..<2 {
            usleep(15000)
            if IOAVServiceWriteI2C(service, chip, host, &packet, UInt32(packet.count)) != 0 { return nil }
        }
        usleep(wait)
        if replyLen == 0 { return [] }
        var reply = [UInt8](repeating: 0, count: replyLen)
        if IOAVServiceReadI2C(service, chip, 0, &reply, UInt32(reply.count)) != 0 { return nil }
        return reply
    }

    /// Read one setting. Nil means the monitor didn't answer at all.
    public func read(_ code: UInt8) -> VCPReading? {
        for quirk in [true, false] {
            for _ in 0..<3 {
                guard let r = transact(body: [0x01, code], replyLen: 11, quirkSeed: quirk) else { continue }
                // Reply: 6E 88 02 result code type maxHi maxLo curHi curLo checksum
                guard r[1] == 0x88, r[2] == 0x02, r[4] == code, xor(0x50, r[0..<10]) == r[10] else { usleep(40000); continue }
                return VCPReading(supported: r[3] == 0, max: Int(r[6]) << 8 | Int(r[7]), current: Int(r[8]) << 8 | Int(r[9]))
            }
        }
        return nil
    }

    /// Write one setting. True means the packet went out (monitors don't confirm writes).
    @discardableResult
    public func write(_ code: UInt8, _ value: Int) -> Bool {
        transact(body: [0x03, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)], replyLen: 0) != nil
    }

    /// Ask the monitor to store its current settings.
    @discardableResult
    public func saveSettings() -> Bool {
        transact(body: [0x0C], replyLen: 0) != nil
    }
}
