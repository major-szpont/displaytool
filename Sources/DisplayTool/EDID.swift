import Foundation

/// Identity fields from a display's EDID, in the same form CoreGraphics reports them
/// (`CGDisplayVendorNumber`, `CGDisplayModelNumber`, `CGDisplaySerialNumber`).
/// Used to tell which AppKit screen a DDC channel belongs to.
struct EDIDIdentity: Equatable {
    let manufacturerID: UInt32
    let productCode: UInt32
    let serialNumber: UInt32

    /// Returns nil unless the block has the standard EDID header and a valid checksum.
    init?(edid: [UInt8]) {
        let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        guard edid.count >= 128,
              edid[0..<8].elementsEqual(header),
              edid[0..<128].reduce(0, { $0 + Int($1) }) % 256 == 0
        else { return nil }

        manufacturerID = UInt32(edid[8]) << 8 | UInt32(edid[9])
        productCode = UInt32(edid[10]) | UInt32(edid[11]) << 8
        serialNumber = UInt32(edid[12])
            | UInt32(edid[13]) << 8
            | UInt32(edid[14]) << 16
            | UInt32(edid[15]) << 24
    }
}
