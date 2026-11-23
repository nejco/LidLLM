// LidLLM — keeps the Mac awake with the lid closed, and puts it to sleep
// (and pings your phone via ntfy) when it gets too hot or the battery runs low.

import Cocoa
import IOKit
import IOKit.ps
import ServiceManagement

// MARK: - Temperature sensors (IOKit HID, no root needed on Apple Silicon)

typealias HIDRef = OpaquePointer
@_silgen_name("IOHIDEventSystemClientCreate") func IOHIDEventSystemClientCreate(_ a: CFAllocator?) -> HIDRef?
@_silgen_name("IOHIDEventSystemClientSetMatching") func IOHIDEventSystemClientSetMatching(_ c: HIDRef, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") func IOHIDEventSystemClientCopyServices(_ c: HIDRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") func IOHIDServiceClientCopyProperty(_ s: HIDRef, _ k: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent") func IOHIDServiceClientCopyEvent(_ s: HIDRef, _ t: Int64, _ a: Int32, _ b: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue") func IOHIDEventGetFloatValue(_ e: HIDRef, _ f: Int32) -> Double

final class Sensors {
    private let client: HIDRef?

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        if let client {
            _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        }
    }

    /// Hottest SoC die sensor and hottest battery sensor, in °C.
    func read() -> (cpu: Double?, battery: Double?) {
        guard let client,
              let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject]
        else { return (nil, nil) }
        var cpu: Double?, battery: Double?
        for service in services {
            let s = HIDRef(Unmanaged.passUnretained(service).toOpaque())
            guard let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = IOHIDServiceClientCopyEvent(s, 15, 0, 0)?.takeRetainedValue()
            else { continue }
            let t = IOHIDEventGetFloatValue(HIDRef(Unmanaged.passUnretained(event).toOpaque()), 15 << 16)
            guard t > 0, t < 150 else { continue }  // drop bogus readings
            if name.contains("tdie") { cpu = max(cpu ?? 0, t) }
            else if name.lowercased().contains("battery") { battery = max(battery ?? 0, t) }
        }
        return (cpu, battery)
    }
}

// MARK: - System helpers

enum Sys {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func pmsetAsRoot(_ args: [String]) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + args).status == 0
    }

    static var canControlSleep: Bool {
        // `sudo -l <cmd>` also succeeds for password-protected "(ALL) ALL", so look for a NOPASSWD rule.
        FileManager.default.fileExists(atPath: "/etc/sudoers.d/lidllm")
            || run("/usr/bin/sudo", ["-n", "-l"]).output.split(separator: "\n")
                .contains { $0.contains("NOPASSWD") && $0.contains("pmset -a disablesleep 1") }
    }

    static var sleepDisabled: Bool {
        run("/usr/bin/pmset", ["-g"]).output
            .split(separator: "\n")
            .contains { $0.contains("SleepDisabled") && $0.trimmingCharacters(in: .whitespaces).hasSuffix("1") }
    }

    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        return v ?? false
    }

    static func battery() -> (percent: Int, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let maxCap = d[kIOPSMaxCapacityKey] as? Int, maxCap > 0
            else { continue }
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (cur * 100 / maxCap, onAC)
        }
        return nil
    }
}

// MARK: - Preferences

enum Prefs {
    static let d = UserDefaults.standard
    static func register() {
        d.register(defaults: [
            "keepAwake": false,
            "topic": "",
            "cpuLimit": 105.0,      // °C, SoC die (Apple Silicon runs ~90-100 under heavy load)
            "batteryLimit": 45.0,   // °C, battery — the best "it's cooking in a bag" signal
            "sustainSeconds": 60.0, // must stay over the limit this long before acting
            "action": "sleep",      // "sleep" or "notify"
            "lowBattery": 10,       // % on battery; 0 = off
        ])
    }
    static var keepAwake: Bool { get { d.bool(forKey: "keepAwake") } set { d.set(newValue, forKey: "keepAwake") } }
    static var topic: String { get { d.string(forKey: "topic") ?? "" } set { d.set(newValue, forKey: "topic") } }
    static var cpuLimit: Double { get { d.double(forKey: "cpuLimit") } set { d.set(newValue, forKey: "cpuLimit") } }
    static var batteryLimit: Double { get { d.double(forKey: "batteryLimit") } set { d.set(newValue, forKey: "batteryLimit") } }
    static var sustain: Double { d.double(forKey: "sustainSeconds") }
    static var action: String { get { d.string(forKey: "action") ?? "sleep" } set { d.set(newValue, forKey: "action") } }
    static var lowBattery: Int { get { d.integer(forKey: "lowBattery") } set { d.set(newValue, forKey: "lowBattery") } }
}

// MARK: - Phone notifications (ntfy.sh — free, no account; install the ntfy app and subscribe to your topic)

enum Push {
    static func send(_ title: String, _ message: String, priority: Int = 3, tags: String = "", done: (() -> Void)? = nil) {
        let topic = Prefs.topic.trimmingCharacters(in: .whitespaces)
        let urlString = topic.contains("://") ? topic : "https://ntfy.sh/\(topic)"
        guard !topic.isEmpty, let url = URL(string: urlString) else { done?(); return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.httpBody = message.data(using: .utf8)
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue(String(priority), forHTTPHeaderField: "Priority")
        if !tags.isEmpty { req.setValue(tags, forHTTPHeaderField: "Tags") }
        URLSession.shared.dataTask(with: req) { _, _, _ in DispatchQueue.main.async { done?() } }.resume()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sensors = Sensors()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    private var cpu: Double?, batteryTemp: Double?
    private var thermal: ProcessInfo.ThermalState = .nominal
    private var power: (percent: Int, onAC: Bool)?
    private var lidClosed = false
    private var canControl = false

    private var hotSince: Date?
    private var lastWarning = Date.distantPast
    private var lastHotAlert = Date.distantPast
    private var sleepingForSafety = false
    private var lastTrigger: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        Prefs.register()
        // Keep the app itself from being napped so the guard keeps ticking.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "LidLLM thermal monitor")

        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        canControl = Sys.canControlSleep
        if Prefs.keepAwake {
            setKeepAwake(true)
        } else if Sys.sleepDisabled && canControl {
            _ = Sys.pmsetAsRoot(["-a", "disablesleep", "0"])  // recover from an earlier crash
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 1
    }

    func applicationWillTerminate(_ note: Notification) {
        if Prefs.keepAwake { _ = Sys.pmsetAsRoot(["-a", "disablesleep", "0"]) }
    }

    // MARK: Keep awake

    private var idleActivity: NSObjectProtocol?

    private func setKeepAwake(_ on: Bool) {
        if on {
            guard Sys.pmsetAsRoot(["-a", "disablesleep", "1"]) else {
                canControl = false
                Prefs.keepAwake = false
                askForSetup()
                return
            }
            if idleActivity == nil {
                idleActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .userInitiated], reason: "Running Claude agents")
            }
            Prefs.keepAwake = true
        } else {
            _ = Sys.pmsetAsRoot(["-a", "disablesleep", "0"])
            if let a = idleActivity { ProcessInfo.processInfo.endActivity(a); idleActivity = nil }
            Prefs.keepAwake = false
        }
        updateTitle()
    }

    // MARK: Monitoring loop

    private func tick() {
        (cpu, batteryTemp) = sensors.read()
        thermal = ProcessInfo.processInfo.thermalState
        power = Sys.battery()
        lidClosed = Sys.lidClosed
        updateTitle()
        guard Prefs.keepAwake, !sleepingForSafety else { hotSince = nil; return }

        // Low battery
        if Prefs.lowBattery > 0, let p = power, !p.onAC, p.percent <= Prefs.lowBattery {
            emergency("Battery at \(p.percent)%")
            return
        }

        let hotReasons = reasons(cpuLimit: Prefs.cpuLimit, battLimit: Prefs.batteryLimit, critical: true)
        if !hotReasons.isEmpty {
            let since = hotSince ?? Date()
            hotSince = since
            if Date().timeIntervalSince(since) >= Prefs.sustain || thermal == .critical {
                emergency(hotReasons.joined(separator: ", "))
            }
            return
        }
        hotSince = nil

        let warmReasons = reasons(cpuLimit: Prefs.cpuLimit - 10, battLimit: Prefs.batteryLimit - 5, critical: false)
        if !warmReasons.isEmpty, Date().timeIntervalSince(lastWarning) > 15 * 60 {
            lastWarning = Date()
            Push.send("Mac is getting warm", warmReasons.joined(separator: ", ") + (lidClosed ? " (lid closed)" : ""),
                      priority: 4, tags: "warning")
        }
    }

    private func reasons(cpuLimit: Double, battLimit: Double, critical: Bool) -> [String] {
        var r: [String] = []
        if let c = cpu, c >= cpuLimit { r.append("CPU \(Int(c))°C") }
        if let b = batteryTemp, b >= battLimit { r.append("battery \(Int(b))°C") }
        if critical ? thermal == .critical : thermal == .serious { r.append("thermal state \(name(thermal))") }
        return r
    }

    /// Too hot / battery low: notify the phone, then sleep — unless the lid is open
    /// (someone is probably using it) or the user chose notify-only.
    private func emergency(_ reason: String) {
        let shouldSleep = Prefs.action == "sleep" && lidClosed
        if !shouldSleep {
            guard Date().timeIntervalSince(lastHotAlert) > 10 * 60 else { return }
            lastHotAlert = Date()
            Push.send("Mac is HOT", reason + (lidClosed ? "" : " (lid open, not sleeping)"),
                      priority: 5, tags: "rotating_light,fire")
            NSSound(named: "Sosumi")?.play()
            return
        }
        sleepingForSafety = true
        lastTrigger = reason
        var finished = false
        let goToSleep = { [weak self] in
            guard let self, !finished else { return }
            finished = true
            self.setKeepAwake(false)  // keep-awake stays OFF after a safety sleep
            Sys.run("/usr/bin/pmset", ["sleepnow"])
        }
        Push.send("Mac put to sleep", "\(reason). Keep-awake turned off.", priority: 5,
                  tags: "rotating_light,zzz", done: goToSleep)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: goToSleep)  // don't wait on a slow network
    }

    @objc private func didWake() {
        if sleepingForSafety {
            sleepingForSafety = false
            hotSince = nil
            Push.send("Mac woke up", "It was put to sleep earlier (\(lastTrigger ?? "?")). Keep-awake is off.",
                      priority: 3, tags: "sunrise")
        }
    }

    // MARK: UI

    private func name(_ s: ProcessInfo.ThermalState) -> String {
        switch s { case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; case .critical: "critical"; @unknown default: "?" }
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let symbol = Prefs.keepAwake ? "cup.and.saucer.fill" : "moon.zzz"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LidLLM")
        button.imagePosition = .imageLeading
        let warm = !reasons(cpuLimit: Prefs.cpuLimit - 10, battLimit: Prefs.batteryLimit - 5, critical: false).isEmpty
            || !reasons(cpuLimit: Prefs.cpuLimit, battLimit: Prefs.batteryLimit, critical: true).isEmpty
        let text = cpu.map { " \(Int($0))°" } ?? ""
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: warm ? [.foregroundColor: NSColor.systemRed] : [:])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        canControl = Sys.canControlSleep

        func info(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func item(_ title: String, _ sel: Selector, checked: Bool = false, tag: Int = 0, in m: NSMenu? = nil) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self; i.state = checked ? .on : .off; i.tag = tag
            (m ?? menu).addItem(i)
        }
        func sub(_ title: String, _ build: (NSMenu) -> Void) {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let m = NSMenu(); build(m); i.submenu = m; menu.addItem(i)
        }

        let c = cpu.map { "\(Int($0))°C" } ?? "–", b = batteryTemp.map { "\(Int($0))°C" } ?? "–"
        info("CPU \(c)  ·  Battery \(b)  ·  \(name(thermal))")
        if let p = power { info("Battery \(p.percent)% \(p.onAC ? "(plugged in)" : "(on battery)")  ·  Lid \(lidClosed ? "closed" : "open")") }
        if sleepingForSafety, let t = lastTrigger { info("Last safety sleep: \(t)") }
        menu.addItem(.separator())

        item("Keep awake with lid closed", #selector(toggleKeepAwake), checked: Prefs.keepAwake)
        if !canControl { item("⚠︎ One-time setup needed (allow sleep control)…", #selector(runSetup)) }
        menu.addItem(.separator())

        sub("When too hot (lid closed)") { m in
            item("Notify phone, then sleep", #selector(setAction), checked: Prefs.action == "sleep", tag: 1, in: m)
            item("Notify phone only", #selector(setAction), checked: Prefs.action == "notify", tag: 0, in: m)
        }
        sub("CPU limit: \(Int(Prefs.cpuLimit))°C") { m in
            for v in [90, 95, 100, 105, 110] { item("\(v)°C", #selector(setCpu), checked: Int(Prefs.cpuLimit) == v, tag: v, in: m) }
        }
        sub("Battery temp limit: \(Int(Prefs.batteryLimit))°C") { m in
            for v in [38, 40, 42, 45, 48] { item("\(v)°C", #selector(setBatt), checked: Int(Prefs.batteryLimit) == v, tag: v, in: m) }
        }
        sub("Sleep on battery below: \(Prefs.lowBattery == 0 ? "off" : "\(Prefs.lowBattery)%")") { m in
            for v in [0, 5, 10, 20, 30] { item(v == 0 ? "Off" : "\(v)%", #selector(setLow), checked: Prefs.lowBattery == v, tag: v, in: m) }
        }
        info("Warns at limit −10°C (CPU) / −5°C (battery); acts after \(Int(Prefs.sustain))s over limit")
        menu.addItem(.separator())

        item(Prefs.topic.isEmpty ? "Set up phone notifications…" : "Phone notifications: \(Prefs.topic)", #selector(setTopic))
        if !Prefs.topic.isEmpty { item("Send test notification", #selector(testPush)) }
        item("Launch at login", #selector(toggleLogin), checked: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit (restores normal sleep)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)
    }

    @objc private func toggleKeepAwake() { setKeepAwake(!Prefs.keepAwake) }
    @objc private func setAction(_ s: NSMenuItem) { Prefs.action = s.tag == 1 ? "sleep" : "notify" }
    @objc private func setCpu(_ s: NSMenuItem) { Prefs.cpuLimit = Double(s.tag); updateTitle() }
    @objc private func setBatt(_ s: NSMenuItem) { Prefs.batteryLimit = Double(s.tag); updateTitle() }
    @objc private func setLow(_ s: NSMenuItem) { Prefs.lowBattery = s.tag }
    @objc private func testPush() {
        let c = cpu.map { "\(Int($0))°C" } ?? "?"
        Push.send("LidLLM test", "Notifications work. CPU is \(c).", priority: 3, tags: "white_check_mark")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn't change login item", "\(error.localizedDescription)\n\nMove LidLLM.app to /Applications and try again, or add it in System Settings → General → Login Items.")
        }
    }

    @objc private func setTopic() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Phone notifications (ntfy)"
        a.informativeText = """
        1. Install the free “ntfy” app on your phone.
        2. Subscribe to a topic name that's hard to guess (anyone who knows it can read it).
        3. Enter the same topic here. A full URL works too, for a self-hosted server.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = Prefs.topic.isEmpty ? "lidllm-\(UUID().uuidString.prefix(8).lowercased())" : Prefs.topic
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Copy Topic & Save")  // Universal Clipboard → paste straight into ntfy on the phone
        a.window.initialFirstResponder = field
        let response = a.runModal()
        guard response != .alertSecondButtonReturn else { return }
        let topic = field.stringValue.trimmingCharacters(in: .whitespaces)
        Prefs.topic = topic
        if response == .alertThirdButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(topic, forType: .string)
        }
    }

    /// Accessory (menu-bar-only) apps have no main menu, so ⌘C/⌘V/⌘X/⌘A do nothing in
    /// text fields. A main menu with an Edit submenu wires up those shortcuts; it's never shown.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func askForSetup() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "One-time setup needed"
        a.informativeText = "To keep the Mac awake with the lid closed — and to put it back to sleep when it gets hot, even while you're away — LidLLM needs permission to run exactly these commands as admin without a password:\n\npmset -a disablesleep 0/1\npmset sleepnow\n\nYou'll be asked for your password once."
        a.addButton(withTitle: "Set Up…"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { runSetup() }
    }

    @objc private func runSetup() {
        guard let script = Bundle.main.path(forResource: "setup-sudo", ofType: "sh") else { return }
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let src = "do shell script \"/bin/sh \" & quoted form of \"\(esc(script))\" & \" \" & quoted form of \"\(esc(NSUserName()))\" with administrator privileges"
        let r = Sys.run("/usr/bin/osascript", ["-e", src])
        canControl = Sys.canControlSleep
        if canControl { setKeepAwake(true) }
        else if !r.output.contains("User canceled") { alert("Setup failed", r.output) }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
