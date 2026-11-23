// LidLLM — keeps the Mac awake with the lid closed, and puts it to sleep
// (and pings you on Slack) when it gets too hot or the battery runs low.

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

    /// Seconds since the last keyboard/mouse/trackpad input.
    static var userIdleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private static let probeSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Checks real internet access (not just Wi-Fi) using Apple's connectivity-check page.
    static func checkInternet(_ done: @escaping (Bool) -> Void) {
        var req = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!)
        req.httpMethod = "HEAD"
        probeSession.dataTask(with: req) { _, response, error in
            let ok = error == nil && ((response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false)
            DispatchQueue.main.async { done(ok) }
        }.resume()
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
            "slackWebhook": "",    // Slack Incoming Webhook URL
            "slackMention": "",    // member ID (U0123ABC) or "here"; mentioned on urgent alerts
            "cpuLimit": 105.0,      // °C, SoC die (Apple Silicon runs ~90-100 under heavy load)
            "batteryLimit": 45.0,   // °C, battery — the best "it's cooking in a bag" signal
            "sustainSeconds": 60.0, // must stay over the limit this long before acting
            "action": "sleep",      // "sleep" or "notify"
            "lowBattery": 10,       // % on battery; 0 = off
            "offlineMinutes": 15,   // sleep after this long without internet; 0 = off
        ])
    }
    static var keepAwake: Bool { get { d.bool(forKey: "keepAwake") } set { d.set(newValue, forKey: "keepAwake") } }
    static var slackWebhook: String { get { d.string(forKey: "slackWebhook") ?? "" } set { d.set(newValue, forKey: "slackWebhook") } }
    static var slackMention: String { get { d.string(forKey: "slackMention") ?? "" } set { d.set(newValue, forKey: "slackMention") } }
    static var cpuLimit: Double { get { d.double(forKey: "cpuLimit") } set { d.set(newValue, forKey: "cpuLimit") } }
    static var batteryLimit: Double { get { d.double(forKey: "batteryLimit") } set { d.set(newValue, forKey: "batteryLimit") } }
    static var sustain: Double { d.double(forKey: "sustainSeconds") }
    static var action: String { get { d.string(forKey: "action") ?? "sleep" } set { d.set(newValue, forKey: "action") } }
    static var lowBattery: Int { get { d.integer(forKey: "lowBattery") } set { d.set(newValue, forKey: "lowBattery") } }
    static var offlineMinutes: Int { get { d.integer(forKey: "offlineMinutes") } set { d.set(newValue, forKey: "offlineMinutes") } }
}

// MARK: - Slack notifications (Incoming Webhook)

enum Push {
    /// Posts to the configured Slack webhook. `tags` are Slack emoji names; the first one prefixes the message.
    /// Priority 4+ mentions `Prefs.slackMention`, so the Slack app sends a push notification.
    /// `done` runs on the main thread: nil on success, otherwise the problem.
    static func send(_ title: String, _ message: String, priority: Int = 3, tags: String = "", done: ((String?) -> Void)? = nil) {
        let finish = { (p: String?) in DispatchQueue.main.async { done?(p) } }
        let hook = Prefs.slackWebhook.trimmingCharacters(in: .whitespaces)
        guard !hook.isEmpty else { finish("Slack isn't set up"); return }
        guard let url = URL(string: hook), url.scheme == "https" else { finish("Invalid Slack webhook URL"); return }

        var text = ""
        if let emoji = tags.split(separator: ",").first { text += ":\(emoji): " }
        text += "*\(title)*\n\(message)"
        let mention = Prefs.slackMention.trimmingCharacters(in: .whitespaces)
        if priority >= 4, !mention.isEmpty {
            let tag = ["here", "channel", "@here", "@channel"].contains(mention.lowercased())
                ? "<!\(mention.lowercased().replacingOccurrences(of: "@", with: ""))>" : "<@\(mention)>"
            text = "\(tag) " + text
        }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { finish(error.localizedDescription); return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                finish("HTTP \(http.statusCode): " + (data.flatMap { String(data: $0, encoding: .utf8) } ?? ""))
                return
            }
            finish(nil)
        }.resume()
    }
}

// MARK: - App

/// NSButton that runs a closure; used for buttons inside alerts that shouldn't close them.
final class ActionButton: NSButton {
    private let handler: (NSButton) -> Void
    init(title: String, handler: @escaping (NSButton) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler(self) }
}

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
    private var warmSince: Date?

    /// Lid open and keyboard/trackpad used in the last 5 minutes: you're at the Mac,
    /// so Slack alerts would just be noise.
    private var userPresent: Bool { !lidClosed && Sys.userIdleSeconds < 5 * 60 }
    private var lastWarning = Date.distantPast
    private var lastHotAlert = Date.distantPast
    private var sleepingForSafety = false
    private var lastTrigger: String?
    private var offlineSince: Date?
    private var lastProbe = Date.distantPast

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
        if Date().timeIntervalSince(lastProbe) >= 60 {
            lastProbe = Date()
            Sys.checkInternet { [weak self] ok in
                guard let self else { return }
                if ok { self.offlineSince = nil } else if self.offlineSince == nil { self.offlineSince = Date() }
            }
        }
        guard Prefs.keepAwake, !sleepingForSafety else { hotSince = nil; warmSince = nil; return }

        // Offline: agents can't do anything without internet. Sleep once offline long enough,
        // if the lid is closed or nobody has touched the Mac for that long either.
        if Prefs.offlineMinutes > 0, let since = offlineSince {
            let limit = TimeInterval(Prefs.offlineMinutes * 60)
            if Date().timeIntervalSince(since) >= limit, lidClosed || Sys.userIdleSeconds >= limit {
                safetySleep("No internet for \(Int(Date().timeIntervalSince(since) / 60)) min")
                return
            }
        }

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
        guard !warmReasons.isEmpty else { warmSince = nil; return }
        let since = warmSince ?? Date()
        warmSince = since
        // Short spikes are normal under load, so it must stay warm for 2 minutes.
        if !userPresent, Date().timeIntervalSince(since) >= 120, Date().timeIntervalSince(lastWarning) > 15 * 60 {
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
            if userPresent { NSSound(named: "Sosumi")?.play(); return }  // you're right here; no Slack
            Push.send("Mac is HOT", reason + (lidClosed ? "" : " (lid open, not sleeping)"),
                      priority: 5, tags: "rotating_light,fire")
            NSSound(named: "Sosumi")?.play()
            return
        }
        safetySleep(reason)
    }

    /// Notify Slack (best effort, max 6 s), turn keep-awake off and sleep now.
    private func safetySleep(_ reason: String) {
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
                  tags: "rotating_light,zzz", done: { _ in goToSleep() })
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: goToSleep)  // don't wait on a slow network
    }

    @objc private func didWake() {
        if sleepingForSafety {
            sleepingForSafety = false
            hotSince = nil
            warmSince = nil
            offlineSince = nil
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
        if let since = offlineSince { info("⚠︎ No internet for \(Int(Date().timeIntervalSince(since) / 60)) min") }
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
        sub("Sleep when offline for: \(Prefs.offlineMinutes == 0 ? "off" : "\(Prefs.offlineMinutes) min")") { m in
            for v in [0, 5, 15, 30, 60] { item(v == 0 ? "Off" : "\(v) min", #selector(setOffline), checked: Prefs.offlineMinutes == v, tag: v, in: m) }
        }
        sub("Sleep on battery below: \(Prefs.lowBattery == 0 ? "off" : "\(Prefs.lowBattery)%")") { m in
            for v in [0, 5, 10, 20, 30] { item(v == 0 ? "Off" : "\(v)%", #selector(setLow), checked: Prefs.lowBattery == v, tag: v, in: m) }
        }
        info("Warns at limit −10°C (CPU) / −5°C (battery); acts after \(Int(Prefs.sustain))s over limit")
        menu.addItem(.separator())

        item(Prefs.slackWebhook.isEmpty ? "Set up Slack alerts…" : "Slack alerts: on", #selector(setSlack))
        if !Prefs.slackWebhook.isEmpty { item("Send test message", #selector(testPush)) }
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
    @objc private func setOffline(_ s: NSMenuItem) { Prefs.offlineMinutes = s.tag }
    @objc private func testPush() {
        let c = cpu.map { "\(Int($0))°C" } ?? "?"
        // Priority 4 so the mention (and therefore the phone push) is exercised too.
        Push.send("LidLLM test", "Slack alerts work. CPU is \(c).", priority: 4, tags: "white_check_mark") { [weak self] problem in
            if let problem { self?.alert("Test message failed", problem) }
            else { self?.alert("Test message sent", "Check Slack on your phone.") }
        }
    }

    @objc private func setSlack() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Slack alerts"
        a.informativeText = """
        1. Click “Copy Manifest”, then “Open Slack Apps”.
        2. Create New App → From a manifest → pick your workspace → paste.
        3. Install to Workspace → pick the channel for alerts.
        4. Features → Incoming Webhooks → copy the URL and paste it below.
        5. Optional: your member ID (Slack → your profile → ⋮ → Copy member ID), or "here". Urgent alerts mention it, so your phone gets a push.

        Leave the URL empty to turn Slack alerts off.
        """
        let width: CGFloat = 440

        // Read-only, selectable manifest
        let manifest = Self.slackManifest
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.string = manifest
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true

        let copyButton = ActionButton(title: "Copy Manifest") { button in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(manifest, forType: .string)
            button.title = "Copied ✓"
        }
        let openButton = ActionButton(title: "Open Slack Apps") { _ in
            NSWorkspace.shared.open(URL(string: "https://api.slack.com/apps?new_app=1")!)
        }
        let buttons = NSStackView(views: [copyButton, openButton])
        buttons.orientation = .horizontal

        func field(_ placeholder: String, _ value: String) -> NSTextField {
            let f = NSTextField()
            f.placeholderString = placeholder; f.stringValue = value
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: width).isActive = true
            return f
        }
        let hook = field("Webhook URL: https://hooks.slack.com/services/…", Prefs.slackWebhook)
        let mention = field("Member ID, e.g. U0123ABCD (optional)", Prefs.slackMention)

        let stack = NSStackView(views: [scroll, buttons, hook, mention])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setFrameSize(stack.fittingSize)
        a.accessoryView = stack
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = hook
        if a.runModal() == .alertFirstButtonReturn {
            Prefs.slackWebhook = hook.stringValue.trimmingCharacters(in: .whitespaces)
            Prefs.slackMention = mention.stringValue.trimmingCharacters(in: .whitespaces)
        }
    }

    /// The bundled Slack app manifest, without its comment header.
    static var slackManifest: String {
        guard let path = Bundle.main.path(forResource: "slack-app-manifest", ofType: "yml"),
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return "slack-app-manifest.yml is missing from the app bundle" }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .drop { $0.hasPrefix("#") }
            .joined(separator: "\n")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn't change login item", "\(error.localizedDescription)\n\nMove LidLLM.app to /Applications and try again, or add it in System Settings → General → Login Items.")
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
