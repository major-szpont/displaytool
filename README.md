# DisplayTool

A small menu bar app that controls the brightness of external displays over DDC/CI, with guard rails so a slider cannot blank a screen or send anything other than brightness.

## Build and run

Requires Apple Silicon and macOS 13 or later. Only Command Line Tools are needed.

```sh
scripts/build-app.sh          # builds build/DisplayTool.app
ditto build/DisplayTool.app /Applications/DisplayTool.app   # install
open /Applications/DisplayTool.app
scripts/run-checks.sh         # safety, packet and EDID self-checks
```

The app has no Dock icon. Its sun icon is in the menu bar. Quit from the menu.

## How it works

- Finds each external display's DDC/CI channel through the `DCPAVServiceProxy` nodes in the IORegistry.
- Matches each channel to its screen with the display's EDID identity (vendor, product, serial), so the row shows the real monitor name.
- Reads brightness (VCP `0x10`) when the menu opens. Opening the menu never writes.
- Sends brightness only when you move a slider.

## Safety rules

- **Only brightness is ever sent.** The DDC layer has one feature code, `0x10`. Factory reset, colour gains and other settings codes cannot be reached from the code.
- **Minimum brightness.** Values below the floor are never sent. The default is 10%, and the menu offers 5, 10, 20 or 30%. Zero is not offered, so a screen cannot be blanked by the slider.
- **Monitor's own maximum.** Values are scaled to the range the monitor reports and never exceed it.
- **No write until read.** A monitor whose range has not been read successfully stays disabled.
- **Paced writes.** One write is in flight at a time, with a 50 ms gap. Slider movement during a write is merged into the next one.
- **No retry loop.** A failed write stops. The next slider movement tries again.
- **No writes on launch, wake or menu open.** Only your slider changes brightness.

## Verification status

Tested on an LG UltraGear+ (4K) on an M4 Mac, macOS 27:

- **Confirmed:** the display's DDC channel is found; its EDID reads and validates; its EDID identity matches the CoreGraphics display (vendor, model and serial).
- **Confirmed:** the packet bytes match the DDC/CI layout (checked by the self-checks), the app builds, launches and draws the menu row.
- **Not confirmed:** any brightness read or write. The monitor did not answer DDC/CI requests (I2C error `0xe0114000` on every attempt), so the reply offset, reply parsing and write path are untested against hardware. The likely cause is DDC/CI being off in the monitor's on-screen menu.

Once DDC/CI is on in the monitor, check that the menu row reads the current brightness, then move the slider once and confirm the monitor changes. Use the tooltip on the status line for the raw I2C error if anything fails.

## Limits

- **DDC/CI must be on.** Turn on DDC/CI in the monitor's on-screen menu. Some docks and adapters block DDC/CI, so a direct connection works best.
- **Apple Silicon only.** Intel Macs use a different interface, which is not implemented.
- **Hardware brightness only.** Monitors that lack DDC/CI will show "No reply". BetterDisplay also dims those through software gamma, which this app does not do.
- **Private API.** The app uses the undocumented `IOAVService` interface, which other open-source tools also use. It is looked up at runtime, so if a future macOS removes it, the app shows "not controllable" instead of crashing.
- **Launch at login** is a menu item. It registers the app with `SMAppService`. The first time, macOS may ask you to allow it under System Settings → General → Login Items. The app should be in /Applications for this to work reliably.

## Layout

```
Sources/DisplayTool/
  DDC.swift               IOAVService access, DDC/CI framing, brightness read/write
  EDID.swift              EDID identity, used to match a channel to a screen
  Safety.swift            minimum floor and range arithmetic, stored preference
  MonitorController.swift per-monitor state, paced writes, discovery
  MonitorRowView.swift    the slider row in the menu
  AppDelegate.swift       status item, menu, wake and hot-plug handling
  main.swift              entry point
Tests/SelfChecks/main.swift  plain-Swift checks, run by scripts/run-checks.sh
scripts/build-app.sh         builds and ad-hoc signs the .app
Resources/Info.plist         bundle metadata (LSUIElement = menu bar only)
```
