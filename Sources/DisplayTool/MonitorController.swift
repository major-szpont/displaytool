import AppKit
import CoreGraphics

/// One external display that answers DDC/CI.
///
/// Threading: hardware calls run on `ioQueue`, one at a time. All state is read and changed on the main thread.
///
/// Safety rules:
/// - Nothing is written until the monitor's brightness range has been read successfully.
/// - Every value is limited by `Safety` (minimum floor, monitor maximum) before it is sent.
/// - At most one write is in flight. Slider movement while a write is running is coalesced into the next write.
/// - A failed write is not retried in a loop. The next slider movement tries again.
/// - Opening the menu only reads. It never writes.
final class MonitorController {
    let name: String
    private let channel: DDCChannel
    private let ioQueue: DispatchQueue

    /// True only after a successful read of this monitor's brightness range.
    private(set) var isReady = false
    private(set) var maximumRaw = 0
    /// Slider position, as a percentage of the monitor's range.
    private(set) var percent = 0
    /// Last percentage known to be on the monitor, from a read or a confirmed write.
    private var confirmedPercent: Int?
    private var writeInFlight = false
    /// Message shown under the slider when something is wrong.
    private(set) var statusText: String?
    /// Technical detail (the I2C error) for the tooltip.
    private(set) var statusDetail: String?

    /// Set by the view so it can redraw when this controller's state changes.
    var onChange: (() -> Void)?

    init(name: String, channel: DDCChannel) {
        self.name = name
        self.channel = channel
        self.ioQueue = DispatchQueue(label: "displaytool.ddc.\(name)")
    }

    /// Reads the monitor's current brightness. Read-only.
    func refresh() {
        guard !writeInFlight else { return }
        ioQueue.async { [channel, weak self] in
            let outcome = Result { try channel.readBrightness() }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.writeInFlight else { return }
                switch outcome {
                case .success(let brightness):
                    self.isReady = true
                    self.maximumRaw = brightness.maximum
                    self.percent = Safety.percent(raw: brightness.current, maximum: brightness.maximum)
                    self.confirmedPercent = self.percent
                    self.statusText = nil
                    self.statusDetail = nil
                case .failure(let error):
                    self.isReady = false
                    self.statusText = "No reply. Enable DDC/CI in the monitor's menu."
                    self.statusDetail = "\(error)"
                }
                self.onChange?()
            }
        }
    }

    /// Called when the slider moves. The request is limited before anything is sent.
    func request(percent requested: Int) {
        guard isReady else { return }
        percent = Safety.clampedPercent(requested, minimum: Settings.minimumPercent)
        onChange?()
        sendIfNeeded()
    }

    private func sendIfNeeded() {
        guard isReady, !writeInFlight, percent != confirmedPercent else { return }

        writeInFlight = true
        let target = percent
        let raw = Safety.rawValue(percent: target, minimum: Settings.minimumPercent, maximum: maximumRaw)

        ioQueue.async { [channel, weak self] in
            let outcome = Result { try channel.writeBrightness(UInt16(raw)) }
            usleep(50_000)  // leave the monitor's controller time between commands
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.writeInFlight = false
                switch outcome {
                case .success:
                    self.confirmedPercent = target
                    self.statusText = nil
                    self.statusDetail = nil
                    self.onChange?()
                    self.sendIfNeeded()  // send any movement that happened while this write ran
                case .failure(let error):
                    // Stop here. The next slider movement tries again, so there is no retry loop.
                    self.statusText = "Brightness not changed. Move the slider to retry."
                    self.statusDetail = "\(error)"
                    self.onChange?()
                }
            }
        }
    }
}

/// A screen as AppKit reports it. Must be built on the main thread.
struct ScreenInfo {
    let displayID: CGDirectDisplayID
    let name: String

    static func externalScreens() -> [ScreenInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard CGDisplayIsBuiltin(displayID) == 0 else { return nil }
            return ScreenInfo(displayID: displayID, name: screen.localizedName)
        }
    }
}

enum MonitorDiscovery {
    /// Finds DDC-capable external displays and gives each one its screen name where it can be matched.
    /// Sends I2C reads, so call it off the main thread.
    static func discover(screens: [ScreenInfo]) -> [MonitorController] {
        let channels = DDCChannel.externalChannels()
        return channels.enumerated().map { index, channel in
            // With exactly one external screen and one channel, pairing is unambiguous.
            var name = channels.count == 1 && screens.count == 1
                ? screens[0].name
                : "External display \(index + 1)"

            if let identity = edidIdentity(of: channel),
               let screen = screens.first(where: { matches($0.displayID, identity) }) {
                name = screen.name
            }
            return MonitorController(name: name, channel: channel)
        }
    }

    private static func edidIdentity(of channel: DDCChannel) -> EDIDIdentity? {
        guard let edid = try? channel.readEDID() else { return nil }
        return EDIDIdentity(edid: edid)
    }

    private static func matches(_ displayID: CGDirectDisplayID, _ identity: EDIDIdentity) -> Bool {
        CGDisplayVendorNumber(displayID) == identity.manufacturerID
            && CGDisplayModelNumber(displayID) == identity.productCode
            && (identity.serialNumber == 0 || CGDisplaySerialNumber(displayID) == identity.serialNumber)
    }
}
