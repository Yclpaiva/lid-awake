import AppKit
import IOKit
import IOKit.ps

// Lid Awake: menu-bar switch that keeps the Mac running with the lid closed
// (`pmset -a disablesleep 1`). The display still turns off and the screen locks;
// battery, time and heat limits turn the mode off on their own.

let bundleID = "dev.yclpaiva.lid-awake"
let statusURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Lid Awake/status.json")

/// Localized text, keyed by its English form in Resources/*.lproj.
func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func tf(_ key: String, _ arguments: CVarArg...) -> String { String(format: t(key), arguments: arguments) }

extension StopReason {
    var label: String {
        switch self {
        case .battery(let percent): return tf("battery at %ld%%", percent)
        case .timeLimit: return t("time limit")
        case .heat: return t("Mac too hot")
        }
    }
}

func rootDomainBool(_ key: String) -> Bool? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool
}

func readBattery() -> (percent: Int?, onBattery: Bool) {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
        return (nil, false)
    }
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
        let current = description[kIOPSCurrentCapacityKey] as? Int
        let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
        return (current.map { max > 0 ? $0 * 100 / max : $0 },
                description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
    }
    return (nil, false)
}

/// Runs a command and returns whether it exited with status 0.
@discardableResult
func run(_ path: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// Needs the sudoers rule installed by `install.sh`.
func setSleepDisabled(_ on: Bool) -> Bool {
    run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
}

func duration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds / 60))
    return minutes >= 60 ? tf("%ld h %ld min", minutes / 60, minutes % 60) : tf("%ld min", minutes)
}

let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter
}()

final class LidAwake: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var termination: DispatchSourceSignal?
    private var enabled = false
    private var lidClosed = false
    private var reading = Reading(batteryPercent: nil, onBattery: false, thermal: .nominal, now: Date())
    private var error: String?
    private let store = UserDefaults.standard

    // 0 stored means "never" / "no limit".
    private var settings: Settings {
        let battery = store.object(forKey: "minBattery") as? Int ?? 20
        let hours = store.object(forKey: "maxHours") as? Int ?? 4
        return Settings(minBattery: battery > 0 ? battery : nil, maxHours: hours > 0 ? hours : nil,
                        stopWhenHot: store.object(forKey: "stopWhenHot") as? Bool ?? true)
    }
    private var lockOnLid: Bool {
        get { store.object(forKey: "lockOnLid") as? Bool ?? true }
        set { store.set(newValue, forKey: "lockOnLid") }
    }
    private var enabledAt: Date? {
        get { store.object(forKey: "enabledAt") as? Date }
        set { store.set(newValue, forKey: "enabledAt") }
    }
    private var lastStop: String? {
        get { store.string(forKey: "lastStop") }
        set { store.set(newValue, forKey: "lastStop") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        // launchctl bootout and logout send SIGTERM; never leave the Mac unable to sleep.
        signal(SIGTERM, SIG_IGN)
        termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination?.setEventHandler { NSApp.terminate(nil) }
        termination?.resume()
        tick()
        timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if enabled { _ = setSleepDisabled(false) }
        enabledAt = nil
        enabled = false
        writeStatus()
    }

    private func tick() {
        enabled = rootDomainBool("SleepDisabled") ?? false
        // Adopt a mode turned on outside the app (or before a restart) so limits still apply.
        if enabled && enabledAt == nil { enabledAt = Date() }
        if !enabled { enabledAt = nil }
        let battery = readBattery()
        reading = Reading(batteryPercent: battery.percent, onBattery: battery.onBattery,
                          thermal: ProcessInfo.processInfo.thermalState, now: Date())
        if enabled, let enabledAt, let reason = stopReason(reading, settings: settings, enabledAt: enabledAt) {
            setMode(false)
            lastStop = tf("Turned off on its own at %@: %@", clock.string(from: reading.now), reason.label)
        }
        let closed = rootDomainBool("AppleClamshellState") ?? false
        if closed && !lidClosed && enabled && lockOnLid {
            // With screen lock set to "immediately", display sleep locks the session.
            run("/usr/bin/pmset", ["displaysleepnow"])
        }
        lidClosed = closed
        updateIndicator()
        writeStatus()
    }

    private func setMode(_ on: Bool) {
        guard setSleepDisabled(on) else {
            error = t("Sleep permission is missing. Run ./install.sh again.")
            updateIndicator()
            return
        }
        error = nil
        enabled = rootDomainBool("SleepDisabled") ?? on
        enabledAt = enabled ? Date() : nil
        if on { lastStop = nil }
        updateIndicator()
    }

    private func updateIndicator() {
        let color: NSColor = error != nil ? .systemYellow : enabled ? .systemGreen : .systemRed
        item.button?.image = NSImage(size: NSSize(width: 12, height: 16), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 3, width: 10, height: 10)).fill()
            return true
        }
        item.button?.image?.isTemplate = false
        let label = enabled ? t("Lid closed: the Mac keeps running") : t("Lid closed: the Mac sleeps")
        item.button?.toolTip = label
        item.button?.setAccessibilityLabel(label)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        tick()
        menu.removeAllItems()
        func info(_ title: String, in target: NSMenu? = nil) {
            (target ?? menu).addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        }
        func action(_ title: String, _ selector: Selector, in target: NSMenu? = nil) -> NSMenuItem {
            let entry = (target ?? menu).addItem(withTitle: title, action: selector, keyEquivalent: "")
            entry.target = self
            return entry
        }
        func choices(_ title: String, _ options: [(String, Int)], current: Int, _ selector: Selector) {
            let submenu = NSMenu()
            for (label, value) in options {
                let entry = action(label, selector, in: submenu)
                entry.representedObject = value
                entry.state = value == current ? .on : .off
            }
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
        }

        let toggle = action(t("Keep running with the lid closed"), #selector(toggleMode))
        toggle.state = enabled ? .on : .off
        info(enabled ? t("Close the lid: the screen turns off and your work keeps going.")
             : t("Close the lid: the Mac sleeps as usual."))
        if let error { info(error) }
        if let lastStop, !enabled { info(lastStop) }
        menu.addItem(.separator())

        let battery = reading.batteryPercent.map { tf("%ld%%", $0) } ?? t("unavailable")
        info(tf("Battery: %@ · %@", battery, reading.onBattery ? t("on battery") : t("on power")))
        let thermal = [t("normal"), t("warm"), t("hot"), t("critical")][min(reading.thermal.rawValue, 3)]
        info(tf("Temperature: %@", thermal))
        if enabled, let enabledAt {
            if let end = deadline(enabledAt: enabledAt, settings: settings) {
                info(tf("Turns off at %@ (in %@)", clock.string(from: end), duration(end.timeIntervalSinceNow)))
            } else {
                info(tf("On for %@, no time limit", duration(-enabledAt.timeIntervalSinceNow)))
            }
        }
        menu.addItem(.separator())

        let current = settings
        choices(t("Turn off below battery"), [10, 20, 30].map { (tf("%ld%%", $0), $0) } + [(t("Never"), 0)],
                current: current.minBattery ?? 0, #selector(setMinBattery(_:)))
        choices(t("Turn off after"), [1, 2, 4, 8].map { (tf("%ld h", $0), $0) } + [(t("No limit"), 0)],
                current: current.maxHours ?? 0, #selector(setMaxHours(_:)))
        action(t("Turn off if the Mac gets too hot"), #selector(toggleHeat)).state = current.stopWhenHot ? .on : .off
        action(t("Lock the screen when the lid closes"), #selector(toggleLock)).state = lockOnLid ? .on : .off
        menu.addItem(.separator())
        _ = action(t("Quit (the Mac sleeps with the lid closed again)"), #selector(quit))
    }

    private func writeStatus() {
        var status: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "sleepDisabled": enabled, "lidClosed": lidClosed,
            "statusItemVisible": item?.isVisible ?? false,
            "thermalState": reading.thermal.rawValue, "onBattery": reading.onBattery
        ]
        status["batteryPercent"] = reading.batteryPercent
        status["error"] = error
        status["lastStop"] = lastStop
        if let enabledAt { status["enabledAt"] = ISO8601DateFormatter().string(from: enabledAt) }
        if let enabledAt, let end = deadline(enabledAt: enabledAt, settings: settings) {
            status["deadline"] = ISO8601DateFormatter().string(from: end)
        }
        do {
            try FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
                .write(to: statusURL, options: .atomic)
        } catch { NSLog("Could not write status: %@", error.localizedDescription) }
    }

    @objc private func toggleMode() { setMode(!enabled); writeStatus() }
    @objc private func setMinBattery(_ sender: NSMenuItem) { store.set(sender.representedObject as? Int ?? 0, forKey: "minBattery"); tick() }
    @objc private func setMaxHours(_ sender: NSMenuItem) { store.set(sender.representedObject as? Int ?? 0, forKey: "maxHours"); tick() }
    @objc private func toggleHeat() { store.set(!settings.stopWhenHot, forKey: "stopWhenHot"); tick() }
    @objc private func toggleLock() { lockOnLid.toggle(); writeStatus() }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = LidAwake()
app.delegate = delegate
app.run()
