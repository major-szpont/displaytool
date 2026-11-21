import AppKit

/// One monitor's row in the menu: name, percentage, slider and a status line.
final class MonitorRowView: NSView {
    private let controller: MonitorController
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)

    init(controller: MonitorController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 290, height: 66))

        nameLabel.stringValue = controller.name
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: 14, y: 42, width: 196, height: 17)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 214, y: 42, width: 62, height: 17)

        slider.frame = NSRect(x: 14, y: 18, width: 262, height: 22)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved(_:))

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 14, y: 2, width: 262, height: 14)

        [nameLabel, valueLabel, slider, statusLabel].forEach(addSubview)

        controller.onChange = { [weak self] in self?.update() }
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("MonitorRowView is built in code only")
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        controller.request(percent: Int(sender.doubleValue.rounded()))
    }

    /// Redraws from the controller. Setting `doubleValue` does not fire the slider's action.
    func update() {
        let ready = controller.isReady
        slider.isEnabled = ready
        slider.doubleValue = Double(controller.percent)
        valueLabel.stringValue = ready ? "\(controller.percent)%" : "–"

        statusLabel.toolTip = controller.statusDetail
        if let status = controller.statusText {
            statusLabel.stringValue = status
        } else if ready {
            statusLabel.stringValue = "Minimum \(Settings.minimumPercent)%. Lower values are not sent."
        } else {
            statusLabel.stringValue = "Reading…"
        }
    }
}
