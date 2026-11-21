import Foundation
import IOKit

// MARK: - Private IOAVService interface (Apple Silicon)
//
// IOAVService is an undocumented IOKit interface that Apple Silicon Macs use to send DDC/CI
// commands to external displays. Other open-source tools use it too (MonitorControl, for one).
//
// The symbols are looked up with dlsym rather than linked directly. If a future macOS removes
// them, the app reports the display as "not controllable" instead of failing to launch.

typealias CreateWithServiceFunction = @convention(c) (UnsafeRawPointer?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias ReadI2CFunction = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
typealias WriteI2CFunction = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn

enum IOAVService {
    private static let defaultScope = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT on Darwin
    private static let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    private static func lookup(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(defaultScope, name) ?? dlsym(ioKit, name)
    }

    static let createWithService: CreateWithServiceFunction? =
        lookup("IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateWithServiceFunction.self) }
    static let readI2C: ReadI2CFunction? =
        lookup("IOAVServiceReadI2C").map { unsafeBitCast($0, to: ReadI2CFunction.self) }
    static let writeI2C: WriteI2CFunction? =
        lookup("IOAVServiceWriteI2C").map { unsafeBitCast($0, to: WriteI2CFunction.self) }
}

// MARK: - DDC/CI packet framing

enum DDCFrame {
    /// 0x37 shifted left by one: the display's address as used in checksums.
    static let displayAddress: UInt8 = 0x6E
    /// The host's source address. IOAVService takes it as the I2C data offset.
    static let hostAddress: UInt8 = 0x51

    /// Builds the bytes that follow the offset: a length byte (0x80 | payload size), the payload,
    /// then an XOR checksum over the destination address, the source address and all of the above.
    static func write(_ payload: [UInt8]) -> [UInt8] {
        var bytes = [0x80 | UInt8(payload.count)] + payload
        var checksum = displayAddress ^ hostAddress
        for byte in bytes {
            checksum ^= byte
        }
        bytes.append(checksum)
        return bytes
    }
}

// MARK: - Channel

/// A DDC/CI channel to one external display. It reads and writes brightness (VCP 0x10) and nothing else.
/// Each method is blocking and must run off the main thread.
final class DDCChannel {
    /// The only VCP feature this app reads or writes: luminance (brightness).
    /// Other codes, such as factory reset or colour gains, are deliberately unreachable from this type.
    static let brightnessCode: UInt8 = 0x10

    /// Display's DDC/CI I2C address (0x37).
    static let displayChip: UInt32 = 0x37
    /// EDID EEPROM I2C address (0x50).
    static let edidChip: UInt32 = 0x50
    /// Offset used when reading a reply. Not yet confirmed on hardware: no reply has been received
    /// from the test monitor (see README, "Verification status").
    static let replyOffset: UInt32 = 0x51

    enum Failure: Error, CustomStringConvertible {
        case apiUnavailable
        case ioReturn(IOReturn)
        case badReply(String)

        var description: String {
            switch self {
            case .apiUnavailable:
                return "DDC interface not available on this macOS version"
            case .ioReturn(let code):
                return "I2C error 0x" + String(UInt32(bitPattern: code), radix: 16)
            case .badReply(let reason):
                return "invalid reply (\(reason))"
            }
        }
    }

    struct Brightness: Equatable {
        let current: Int
        let maximum: Int
    }

    /// Opaque IOAVService handle. Retained for the life of this channel.
    let service: CFTypeRef

    private init(service: CFTypeRef) {
        self.service = service
    }

    /// Lists the AV services of external displays. This is a read-only registry lookup.
    static func externalChannels() -> [DDCChannel] {
        guard let create = IOAVService.createWithService else { return [] }

        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var channels: [DDCChannel] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let current = entry
            defer { IOObjectRelease(current) }

            let location = IORegistryEntryCreateCFProperty(current, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == "External", let service = create(nil, current)?.takeRetainedValue() {
                channels.append(DDCChannel(service: service))
            }
            entry = IOIteratorNext(iterator)
        }
        return channels
    }

    /// Reads the 128-byte base EDID block. Read-only.
    func readEDID() throws -> [UInt8] {
        guard let read = IOAVService.readI2C else { throw Failure.apiUnavailable }
        var edid = [UInt8](repeating: 0, count: 128)
        let status = edid.withUnsafeMutableBytes {
            read(service, Self.edidChip, 0, $0.baseAddress!, 128)
        }
        guard status == kIOReturnSuccess else { throw Failure.ioReturn(status) }
        return edid
    }

    /// Reads the current and maximum brightness. Read-only; retries a few times because DDC replies are unreliable.
    func readBrightness() throws -> Brightness {
        var lastFailure = Failure.badReply("no attempt made")
        for _ in 0..<3 {
            do {
                try send(DDCFrame.write([0x01, Self.brightnessCode]))  // "get VCP feature" request
                usleep(40_000)                                         // the display needs up to 40 ms to build the reply
                return try Self.parseBrightnessReply(try receive(count: 11))
            } catch let failure as Failure {
                lastFailure = failure
                usleep(20_000)
            }
        }
        throw lastFailure
    }

    /// Sets brightness to a raw value. Callers must pass a value already limited by `Safety.rawValue`.
    func writeBrightness(_ raw: UInt16) throws {
        try send(DDCFrame.write([0x03, Self.brightnessCode, UInt8(raw >> 8), UInt8(raw & 0xFF)]))  // "set VCP feature"
    }

    // MARK: Private transport

    private func send(_ packet: [UInt8]) throws {
        guard let write = IOAVService.writeI2C else { throw Failure.apiUnavailable }
        let status = packet.withUnsafeBufferPointer {
            write(service, Self.displayChip, UInt32(DDCFrame.hostAddress), $0.baseAddress!, UInt32($0.count))
        }
        guard status == kIOReturnSuccess else { throw Failure.ioReturn(status) }
    }

    private func receive(count: Int) throws -> [UInt8] {
        guard let read = IOAVService.readI2C else { throw Failure.apiUnavailable }
        var buffer = [UInt8](repeating: 0, count: count)
        let status = buffer.withUnsafeMutableBytes {
            read(service, Self.displayChip, Self.replyOffset, $0.baseAddress!, UInt32(count))
        }
        guard status == kIOReturnSuccess else { throw Failure.ioReturn(status) }
        return buffer
    }

    /// Parses an 11-byte "VCP feature reply" for brightness.
    /// Layout: [0] source, [1] length, [2] reply opcode 0x02, [3] result, [4] VCP code,
    /// [5] type, [6..7] maximum, [8..9] present value, [10] checksum.
    static func parseBrightnessReply(_ reply: [UInt8]) throws -> Brightness {
        guard reply.count == 11 else { throw Failure.badReply("length \(reply.count)") }
        guard reply[2] == 0x02 else { throw Failure.badReply("not a VCP reply") }
        guard reply[3] == 0x00 else { throw Failure.badReply("display returned result \(reply[3])") }
        guard reply[4] == brightnessCode else { throw Failure.badReply("reply is for VCP \(reply[4])") }
        let maximum = Int(reply[6]) << 8 | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        guard maximum > 0, current <= maximum else {
            throw Failure.badReply("implausible range \(current) of \(maximum)")
        }
        return Brightness(current: current, maximum: maximum)
    }
}
