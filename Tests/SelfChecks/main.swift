// Plain-Swift checks for the safety arithmetic, DDC packet layout, reply parsing and EDID parsing.
// Run with scripts/run-checks.sh. Uses no test framework, so it works with Command Line Tools alone.
import Foundation

var passed = 0
var failed = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        print("FAIL: \(name)")
    }
}

func throwsError(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch {
        return true
    }
}

// MARK: Safety

check(Safety.rawValue(percent: 0, minimum: 10, maximum: 100) == 10, "zero request is raised to the minimum")
check(Safety.rawValue(percent: 3, minimum: 10, maximum: 200) == 20, "request below minimum uses minimum on a 200 scale")
check(Safety.rawValue(percent: 250, minimum: 5, maximum: 100) == 100, "request above 100 is capped at the monitor maximum")
check(Safety.rawValue(percent: 100, minimum: 5, maximum: 255) == 255, "100% maps to the monitor's own maximum")
check(Safety.rawValue(percent: 0, minimum: 5, maximum: 1) == 1, "raw value is never zero")
check(Safety.rawValue(percent: 50, minimum: 5, maximum: 200) == 100, "50% scales proportionally")
check(Safety.clampedPercent(-5, minimum: 10) == 10, "negative request is raised to the minimum")
check(Safety.clampedPercent(42, minimum: 10) == 42, "in-range request is unchanged")
check(Safety.clampedPercent(140, minimum: 10) == 100, "over-range request is capped at 100")
check(Safety.percent(raw: 50, maximum: 100) == 50, "raw 50 of 100 is 50%")
check(Safety.percent(raw: 0, maximum: 0) == 0, "zero maximum reports 0% instead of dividing by zero")
check(Safety.minimumPresets.allSatisfy { $0 >= 5 }, "no minimum preset allows a fully dark panel")

let minimumKey = "minimumBrightnessPercent"
let savedMinimum = UserDefaults.standard.object(forKey: minimumKey)
UserDefaults.standard.set(0, forKey: minimumKey)
check(Settings.minimumPercent == Safety.defaultMinimum, "stored 0% (not a preset) falls back to the default")
Settings.minimumPercent = 20
check(Settings.minimumPercent == 20, "a preset minimum is stored and read back")
if let savedMinimum = savedMinimum {
    UserDefaults.standard.set(savedMinimum, forKey: minimumKey)
} else {
    UserDefaults.standard.removeObject(forKey: minimumKey)
}

// MARK: DDC packet layout

// Set VCP 0x10 to 0x0032: length 0x84, opcode 0x03, code 0x10, value 0x00 0x32, checksum 0x9A.
check(DDCFrame.write([0x03, 0x10, 0x00, 0x32]) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A], "set-brightness packet bytes")
check(DDCFrame.write([0x01, 0x10]) == [0x82, 0x01, 0x10, 0xAC], "get-brightness request bytes")

// MARK: Reply parsing

func brightnessReply(result: UInt8 = 0x00, code: UInt8 = 0x10, maximum: UInt16 = 100, current: UInt16) -> [UInt8] {
    [0x6E, 0x88, 0x02, result, code, 0x00,
     UInt8(maximum >> 8), UInt8(maximum & 0xFF),
     UInt8(current >> 8), UInt8(current & 0xFF), 0x00]
}

check((try? DDCChannel.parseBrightnessReply(brightnessReply(maximum: 100, current: 50))) == DDCChannel.Brightness(current: 50, maximum: 100), "parses current 50 of 100")
check((try? DDCChannel.parseBrightnessReply(brightnessReply(maximum: 400, current: 257))) == DDCChannel.Brightness(current: 257, maximum: 400), "parses a 16-bit range")
check(throwsError { _ = try DDCChannel.parseBrightnessReply(brightnessReply(result: 0x01, current: 50)) }, "rejects a non-zero result code")
check(throwsError { _ = try DDCChannel.parseBrightnessReply(brightnessReply(code: 0x12, current: 50)) }, "rejects a reply for another VCP code")
check(throwsError { _ = try DDCChannel.parseBrightnessReply(brightnessReply(maximum: 0, current: 0)) }, "rejects a zero maximum")
check(throwsError { _ = try DDCChannel.parseBrightnessReply(brightnessReply(maximum: 100, current: 101)) }, "rejects current above maximum")
check(throwsError { _ = try DDCChannel.parseBrightnessReply([0x6E, 0x88, 0x02]) }, "rejects a short reply")

// MARK: EDID identity

func makeEDID(header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00],
              manufacturer: (UInt8, UInt8) = (0x1E, 0x6D),
              product: UInt16 = 0x7857,
              serial: UInt32 = 0x000BBE87) -> [UInt8] {
    var block = [UInt8](repeating: 0, count: 128)
    block.replaceSubrange(0..<8, with: header)
    block[8] = manufacturer.0
    block[9] = manufacturer.1
    block[10] = UInt8(product & 0xFF)
    block[11] = UInt8(product >> 8)
    block[12] = UInt8(serial & 0xFF)
    block[13] = UInt8((serial >> 8) & 0xFF)
    block[14] = UInt8((serial >> 16) & 0xFF)
    block[15] = UInt8(serial >> 24)
    let sum = block[0..<127].reduce(0) { $0 + Int($1) }
    block[127] = UInt8((256 - sum % 256) % 256)
    return block
}

let identity = EDIDIdentity(edid: makeEDID())
check(identity?.manufacturerID == 7789, "manufacturer ID matches CGDisplayVendorNumber form")
check(identity?.productCode == 30807, "product code matches CGDisplayModelNumber form")
check(identity?.serialNumber == 769671, "serial matches CGDisplaySerialNumber form")

var badChecksum = makeEDID()
badChecksum[127] = badChecksum[127] &+ 1
check(EDIDIdentity(edid: badChecksum) == nil, "EDID with a bad checksum is rejected")
check(EDIDIdentity(edid: makeEDID(header: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])) == nil, "EDID without the header is rejected")
check(EDIDIdentity(edid: [0x00, 0xFF]) == nil, "short EDID block is rejected")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
