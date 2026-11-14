import AppKit
import IOKit.hid
import CoreGraphics
import CoreBluetooth
import CryptoKit
import Darwin

// One identical app is installed locally and distributed. No event capture,
// vendor configuration, firmware writes, audio capture, or network requests.
enum Build {
    static let stamp = "1114-1823"
    static let a6Only = false
    static let title = "Bluetooth Mouse Keepalive"
    static let label = "local.bluetoothmouse.keepalive"
    static let version = "1.1"
}
enum Policy {
    static let descriptor = "05010902a10185010901a1000509190129101500250175019510810205010930093116008026ff7f75109502810609381581257f750895018106050c0a380295018106c0c0050c0901a101850275109501150126ff0319012aff038160c005010906a1018503050719e029e71500250175019508810295017508810195057501050819012905910295017503910195067508150025e70507190029e78100c0"
    static let reads = ["2A19", "2A24", "2A26", "2A28", "2A4A"]
    static func isA6(_ vendor: Int, _ product: Int, _ name: String, _ transport: String, _ descriptor: String, _ length: Int) -> Bool {
        vendor == 10007 && product == 12976 && name == "A6 Ultra" && transport == "Bluetooth Low Energy" && descriptor == Self.descriptor && length == 2
    }
    static func uniqueIndex(_ names: [String], _ target: String) -> Int? {
        let matches = names.indices.filter { names[$0] == target }
        return matches.count == 1 ? matches[0] : nil
    }
    static func retryDelay(_ attempts: Int) -> TimeInterval { min(30, 2 * pow(2, Double(min(max(attempts - 1, 0), 4)))) }
    static func validInterval(_ number: Int) -> Int { [5, 10, 15].contains(number) ? number : 10 }
    static func menuName(_ raw: String) -> String {
        let text = raw.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "鼠标" : String(text.prefix(12))
    }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}
func number(_ d: IOHIDDevice, _ key: String) -> Int { (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0 }
func string(_ d: IOHIDDevice, _ key: String) -> String { IOHIDDeviceGetProperty(d, key as CFString) as? String ?? "" }
struct Mouse {
    let key: String, name: String, transport: String
    let a6: Bool
}
func inventory(_ manager: IOHIDManager) -> [Mouse] {
    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    return devices.compactMap { d in
        let t = string(d, kIOHIDTransportKey)
        guard t.lowercased().contains("bluetooth") else { return nil }
        let n = string(d, kIOHIDProductKey), v = number(d, kIOHIDVendorIDKey), p = number(d, kIOHIDProductIDKey)
        let bytes = (IOHIDDeviceGetProperty(d, kIOHIDReportDescriptorKey as CFString) as? Data)?.map { String(format: "%02x", $0) }.joined() ?? ""
        let a6 = Policy.isA6(v, p, n, t, bytes, number(d, kIOHIDMaxOutputReportSizeKey))
        guard !Build.a6Only || a6 else { return nil }
        return Mouse(key: "\(v):\(p):\(n):\(string(d, kIOHIDSerialNumberKey)):\(number(d, kIOHIDLocationIDKey))", name: n.isEmpty ? "未命名鼠标" : n, transport: t, a6: a6)
    }.sorted { $0.name < $1.name }
}

// Locks are deliberately stable across releases; closing the descriptor (or a
// process exit) releases them. The child does not inherit them across exec.
final class FileLock {
    private var fd: Int32 = -1
    func acquire(_ name: String) -> Bool {
        if fd >= 0 { return true }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bluetooth Mouse Keepalive/Locks")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return false }
        let path = dir.appendingPathComponent(Policy.digest(name) + ".lock").path
        let candidate = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard candidate >= 0 else { return false }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(candidate); return false }
        fd = candidate; return true
    }
    func release() { if fd >= 0 { flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 } }
    deinit { release() }
}

// Run synchronous HID I/O in a persistent child of the same signed executable.
// A wedged driver call can be ended without reusing a pending report buffer.
// stdin EOF also ends the child if the menu app disappears.
func runHIDWorker() -> Never {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 10007, kIOHIDProductIDKey: 12976, kIOHIDProductKey: "A6 Ultra", kIOHIDTransportKey: "Bluetooth Low Energy"] as CFDictionary)
    var device: IOHIDDevice?
    defer { if let d = device { IOHIDDeviceClose(d, 0) } }
    while let line = readLine() {
        guard line == "send" else { continue }
        var result: IOReturn = kIOReturnNotFound
        if device == nil {
            let matches = ((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []).filter { d in
                let bytes = (IOHIDDeviceGetProperty(d, kIOHIDReportDescriptorKey as CFString) as? Data)?.map { String(format: "%02x", $0) }.joined() ?? ""
                return Policy.isA6(number(d, kIOHIDVendorIDKey), number(d, kIOHIDProductIDKey), string(d, kIOHIDProductKey), string(d, kIOHIDTransportKey), bytes, number(d, kIOHIDMaxOutputReportSizeKey))
            }
            if matches.count == 1, let d = matches.first {
                result = IOHIDDeviceOpen(d, 0)
                if result == kIOReturnSuccess { device = d }
            }
        }
        if let d = device {
            let report: [UInt8] = [3, CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) ? 2 : 0]
            result = report.withUnsafeBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 3, $0.baseAddress!, 2) }
            if result != kIOReturnSuccess { IOHIDDeviceClose(d, 0); device = nil }
        }
        print("\(result)"); fflush(stdout)
    }
    exit(0)
}
final class HIDWorker {
    var process: Process?
    private var input: Pipe?, output: Pipe?
    private var received = Data()
    private var completion: ((Bool, String) -> Void)?
    var pending: Bool { completion != nil }
    private var generation = 0
    private var stopping = false
    var arguments = ["--hid-worker"]
    func send(_ callback: @escaping (Bool, String) -> Void) {
        guard completion == nil else { return }
        guard !stopping else { callback(false, "worker_restarting"); return }
        if process == nil {
            let p = Process(), input = Pipe(), output = Pipe()
            p.executableURL = Bundle.main.executableURL; p.arguments = arguments
            p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
            self.input = input; self.output = output; received = Data()
            output.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
                let data = handle.availableData
                DispatchQueue.main.async {
                    guard let self = self, let p = p, self.process === p, !self.stopping, !data.isEmpty else { return }
                    self.received.append(data)
                    while let newline = self.received.firstIndex(of: 10) {
                        let line = String(data: self.received[..<newline], encoding: .utf8) ?? ""
                        self.received.removeSubrange(...newline)
                        let callback = self.completion; self.completion = nil
                        let code = Int32(line)
                        callback?(code == 0, code.map { String(format: "0x%08x", $0) } ?? "invalid_worker_reply")
                    }
                }
            }
            p.terminationHandler = { [weak self] ended in
                DispatchQueue.main.async {
                    guard let self = self, self.process === ended else { return }
                    self.output?.fileHandleForReading.readabilityHandler = nil
                    self.input = nil; self.output = nil; self.process = nil; self.stopping = false
                    let callback = self.completion; self.completion = nil
                    callback?(false, "worker_exited")
                }
            }
            do { try p.run(); process = p } catch {
                output.fileHandleForReading.readabilityHandler = nil
                self.input = nil; self.output = nil
                callback(false, "worker_launch_failed"); return
            }
        }
        guard let p = process, p.isRunning, let input = input else { callback(false, "worker_restarting"); return }
        completion = callback; generation += 1; let ticket = generation
        do { try input.fileHandleForWriting.write(contentsOf: Data("send\n".utf8)) } catch {
            completion = nil; stop(); callback(false, "worker_pipe_failed"); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.generation == ticket, let callback = self.completion else { return }
            self.completion = nil; self.stop(); callback(false, "hid_timeout")
        }
    }
    func stop() {
        generation += 1; completion = nil
        stopping = process != nil
        try? input?.fileHandleForWriting.close()
        if let p = process, p.isRunning {
            // SIGKILL is confined to our own stuck I/O helper, never the mouse
            // driver, another application, or the current menu process.
            kill(p.processIdentifier, SIGKILL)
        }
    }
    deinit { stop() }
}

final class Keepalive: NSObject, NSApplicationDelegate, NSMenuDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    var item: NSStatusItem!
    let menu = NSMenu(), mouseMenu = NSMenu(), timingMenu = NSMenu()
    let status = NSMenuItem(title: "正在连接", action: nil, keyEquivalent: "")
    var pauseItem: NSMenuItem!, loginItem: NSMenuItem!, testItem: NSMenuItem!
    let instanceLock = FileLock(), deviceLock = FileLock(), worker = HIDWorker()
    var mice: [Mouse] = [], selected: Mouse?
    var desiredKey = UserDefaults.standard.string(forKey: "mouseKey") ?? ""
    var interval: TimeInterval = 10, nextSend = Date.distantPast, lastScan = Date.distantPast
    var paused = false, sleeping = false, blocked = false, quitting = false
    var menuName = Policy.menuName(UserDefaults.standard.string(forKey: "menuBarName") ?? "鼠标")
    var state = "starting", message = "正在连接", errorText = ""
    var reports = 0, failures = 0, retryAttempts = 0
    var lastSuccess: Date?, timer: Timer?
    var lastPersist = Date.distantPast
    var lockedKey: String?
    var central: CBCentralManager?, peripheral: CBPeripheral?, characteristic: CBCharacteristic?
    var blePending = false, connecting = false, servicesPending = 0
    var readable: [CBCharacteristic] = []
    var generation = 0
    var loginConfigured = false, loginLoaded = false
    var testStart: Date?, testKey = "", testInterval = 10, testFailures = 0, testReports = 0
    var testNeedsResult = false
    var observers: [NSObjectProtocol] = []
    var support: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/" + (Build.a6Only ? "A6 Ultra" : "Bluetooth Mouse Keepalive")) }
    var statusURL: URL { support.appendingPathComponent("status.json") }
    var agent: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(Build.label).plist") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Build.label).filter { $0.processIdentifier != getpid() }
        guard existing.isEmpty else { existing.first?.activate(options: [.activateIgnoringOtherApps]); NSApp.terminate(nil); return }
        guard instanceLock.acquire("instance:\(Build.label)") else { NSApp.terminate(nil); return }
        signal(SIGPIPE, SIG_IGN)
        let key = Build.a6Only ? "keepaliveIntervalSeconds" : "interval"
        interval = TimeInterval(Policy.validInterval(UserDefaults.standard.integer(forKey: key)))
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self; menu.addItem(status)
        if !Build.a6Only { let e = NSMenuItem(title: "选择鼠标", action: nil, keyEquivalent: ""); e.submenu = mouseMenu; menu.addItem(e) }
        for n in [5, 10, 15] { let e = entry("\(n) 秒", #selector(changeInterval(_:))); e.tag = n; timingMenu.addItem(e) }
        let timing = NSMenuItem(title: "间隔", action: nil, keyEquivalent: ""); timing.submenu = timingMenu; menu.addItem(timing)
        pauseItem = entry("暂停", #selector(togglePause)); menu.addItem(pauseItem)
        loginItem = entry("登录时启动", #selector(toggleLogin)); menu.addItem(loginItem)
        let more = NSMenu(), moreItem = NSMenuItem(title: "更多", action: nil, keyEquivalent: "")
        moreItem.submenu = more; menu.addItem(moreItem)
        testItem = entry("开始静置测试…", #selector(testAction)); more.addItem(testItem)
        more.addItem(entry("状态详情…", #selector(details)))
        more.addItem(entry("菜单栏名称…", #selector(renameMenu)))
        more.addItem(entry("授权…", #selector(authorize)))
        more.addItem(entry("重新连接", #selector(retry)))
        menu.addItem(.separator()); menu.addItem(entry("退出", #selector(quit))); item.menu = menu
        let notifications = NSWorkspace.shared.notificationCenter
        observers.append(notifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.willSleep() })
        observers.append(notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.didWake() })
        refreshLogin(); refresh(); schedule()
    }
    func entry(_ title: String, _ action: Selector) -> NSMenuItem { let e = NSMenuItem(title: title, action: action, keyEquivalent: ""); e.target = self; return e }
    // A single one-shot timer sleeps until the next report/retry, instead of
    // polling every second. Device enumeration occurs at most every 30 seconds.
    func schedule(_ after: TimeInterval? = nil) {
        timer?.invalidate()
        guard !quitting, !sleeping else { return }
        let delay = after ?? max(0.1, nextSend.timeIntervalSinceNow)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    func refresh() {
        lastScan = Date()
        // A fresh manager avoids stale snapshots without opening every mouse.
        let scan = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(scan, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2] as CFDictionary)
        mice = inventory(scan)
        if let old = selected, !mice.contains(where: { $0.key == old.key }) { closeConnections(); selected = nil; blocked = false; releaseDevice(); schedule(0.1) }
        if selected == nil {
            let matches = Build.a6Only ? mice : mice.filter { $0.key == desiredKey }
            if matches.count == 1 { selected = matches[0]; desiredKey = matches[0].key; restoreInterval(); blocked = false }
        }
        updateMenu()
    }
    func updateMenu() {
        mouseMenu.removeAllItems()
        for (i, m) in mice.enumerated() { let e = entry(m.name, #selector(choose(_:))); e.tag = i; e.state = m.key == selected?.key ? .on : .off; mouseMenu.addItem(e) }
        if mice.isEmpty { mouseMenu.addItem(NSMenuItem(title: "没有已连接的鼠标", action: nil, keyEquivalent: "")) }
        for e in timingMenu.items { e.state = e.tag == Int(interval) ? .on : .off }
        loginItem.state = loginConfigured && loginLoaded ? .on : (loginConfigured ? .mixed : .off)
        pauseItem.title = paused ? "继续" : "暂停"
        testItem.title = testStart == nil ? "开始静置测试…" : (testNeedsResult ? "记录测试结果…" : "查看静置测试…")
    }
    func menuWillOpen(_ menu: NSMenu) { if menu === self.menu { refreshLogin(); refresh(); persist(force: true) } }
    func settingsKey(_ name: String) -> String { "mouse.\(Policy.digest(desiredKey)).\(name)" }
    func restoreInterval() {
        let stored = UserDefaults.standard.integer(forKey: settingsKey("interval"))
        if [5, 10, 15].contains(stored) { interval = TimeInterval(stored) }
    }
    @objc func choose(_ sender: NSMenuItem) {
        guard mice.indices.contains(sender.tag) else { return }
        cancelTest("鼠标已切换"); closeConnections(); releaseDevice()
        selected = mice[sender.tag]; desiredKey = selected!.key
        UserDefaults.standard.set(desiredKey, forKey: "mouseKey")
        interval = 10; restoreInterval(); blocked = false; retryAttempts = 0
        reports = 0; failures = 0; lastSuccess = nil; paused = false; nextSend = .distantPast
        updateMenu(); schedule()
    }
    @objc func changeInterval(_ sender: NSMenuItem) {
        guard [5, 10, 15].contains(sender.tag) else { return }
        cancelTest("间隔已修改"); interval = TimeInterval(sender.tag)
        UserDefaults.standard.set(sender.tag, forKey: Build.a6Only ? "keepaliveIntervalSeconds" : "interval")
        if !desiredKey.isEmpty { UserDefaults.standard.set(sender.tag, forKey: settingsKey("interval")) }
        nextSend = Date().addingTimeInterval(interval); updateMenu(); persist(force: true); schedule()
    }
    @objc func togglePause() {
        paused.toggle(); cancelTest("保活已暂停"); closeConnections(); releaseDevice()
        if paused { show("paused", "已暂停") }
        else { blocked = false; nextSend = .distantPast }
        updateMenu(); schedule()
    }
    @objc func retry() { closeConnections(); blocked = false; retryAttempts = 0; refresh(); nextSend = .distantPast; schedule() }
    func willSleep() { sleeping = true; cancelTest("Mac 已睡眠"); timer?.invalidate(); closeConnections(); releaseDevice(); show("sleeping", "Mac 睡眠中") }
    func didWake() { sleeping = false; blocked = false; retryAttempts = 0; lastScan = .distantPast; nextSend = Date().addingTimeInterval(2); schedule() }
    func releaseDevice() { deviceLock.release(); lockedKey = nil }
    func claimDevice(_ mouse: Mouse) -> Bool {
        if lockedKey == mouse.key { return true }
        // Older A6 builds have no lock. Detect their separate app before using
        // the A6 profile from the generic build (and vice versa).
        let otherID = Build.a6Only ? "local.bluetoothmouse.keepalive" : "local.a6ultra.keepalive"
        if mouse.a6 && !NSRunningApplication.runningApplications(withBundleIdentifier: otherID).isEmpty {
            show("other_app", "请先退出另一款保活程序"); return false
        }
        guard deviceLock.acquire("device:\(mouse.key)") else { show("device_in_use", "此鼠标已有保活程序"); return false }
        lockedKey = mouse.key; return true
    }
    func tick() {
        guard !quitting, !sleeping else { return }
        checkTest()
        guard !paused else { schedule(30); return }
        if Date().timeIntervalSince(lastScan) >= 30 { refresh() }
        guard !blocked else { schedule(30); return }
        guard let mouse = selected else {
            show("waiting", Build.a6Only || !desiredKey.isEmpty ? "等待鼠标连接蓝牙" : "请选择鼠标"); schedule(5); return
        }
        guard claimDevice(mouse) else { schedule(5); return }
        if mouse.a6 {
            guard CGPreflightListenEventAccess() else { releaseDevice(); show("permission_required", "请授权输入监控"); schedule(5); return }
            guard !worker.pending else { return }
            let token = generation
            worker.send { [weak self] ok, error in
                guard let self = self, self.generation == token, !self.paused, !self.sleeping else { return }
                self.completed(ok, generic: false, error: error)
            }
        } else { readGeneric(mouse) }
    }
    func completed(_ success: Bool, generic: Bool, error: String) {
        if success {
            reports += 1; lastSuccess = Date(); errorText = ""; retryAttempts = 0
            show(generic ? "generic_reading" : "sending", generic ? "读取正常 · 效果待测试" : "保活中")
            nextSend = Date().addingTimeInterval(interval); schedule()
        } else { transient(error) }
    }
    func transient(_ error: String) {
        failures += 1; retryAttempts += 1; errorText = error
        cancelTest("通信中断"); closeConnections(); releaseDevice()
        show("retrying", "连接中断，正在重试")
        nextSend = Date().addingTimeInterval(Policy.retryDelay(retryAttempts)); schedule()
    }
    func unsupported() { blocked = true; cancelTest("缺少兼容接口"); closeConnections(); releaseDevice(); show("unsupported", "此设备暂无兼容方法"); schedule(30) }
    func closeConnections() {
        generation += 1; worker.stop()
        if let p = peripheral { p.delegate = nil; central?.cancelPeripheralConnection(p) }
        central?.delegate = nil; central = nil; peripheral = nil; characteristic = nil
        connecting = false; blePending = false; servicesPending = 0; readable = []
    }
    func timeout(_ seconds: Double, _ state: String) {
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.generation == token, self.connecting || self.blePending else { return }
            self.transient(state)
        }
    }
    func readGeneric(_ mouse: Mouse) {
        guard mouse.transport == "Bluetooth Low Energy" else { unsupported(); return }
        if central == nil {
            show("connecting", "正在准备蓝牙")
            central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false]); schedule(5); return
        }
        guard let central = central, central.state == .poweredOn else {
            show("bluetooth_unavailable", "请开启蓝牙并授权"); schedule(5); return
        }
        if let p = peripheral, let c = characteristic {
            guard !blePending else { return }
            blePending = true; generation += 1; timeout(5, "ble_read_timeout"); p.readValue(for: c); return
        }
        guard !connecting else { return }
        let known = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1812"), CBUUID(string: "180F"), CBUUID(string: "180A")])
        guard let i = Policy.uniqueIndex(known.map { $0.name ?? "" }, mouse.name) else {
            show("waiting", "请连接鼠标，避免同名设备"); schedule(5); return
        }
        let p = known[i]; peripheral = p; p.delegate = self; connecting = true
        generation += 1; timeout(12, "ble_connect_timeout"); show("connecting", "正在连接")
        central.connect(p, options: nil)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central, !sleeping, !paused else { return }
        if central.state == .poweredOn { nextSend = .distantPast; schedule() }
        else {
            cancelTest("蓝牙不可用"); peripheral?.delegate = nil; peripheral = nil; characteristic = nil
            generation += 1; connecting = false; blePending = false
            show("bluetooth_unavailable", central.state == .unauthorized ? "请授权蓝牙访问" : "等待蓝牙开启"); schedule(5)
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central, self.peripheral === peripheral else { return }
        peripheral.discoverServices([CBUUID(string: "1812"), CBUUID(string: "180F"), CBUUID(string: "180A")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { if self.central === central, self.peripheral === peripheral { transient(error?.localizedDescription ?? "connect_failed") } }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { if self.central === central, self.peripheral === peripheral { transient(error?.localizedDescription ?? "disconnected") } }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error = error { transient(error.localizedDescription); return }
        let services = peripheral.services ?? []; guard !services.isEmpty else { unsupported(); return }
        servicesPending = services.count; readable = []
        for s in services { peripheral.discoverCharacteristics(Policy.reads.map { CBUUID(string: $0) }, for: s) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error = error { transient(error.localizedDescription); return }
        readable += (service.characteristics ?? []).filter { $0.properties.contains(.read) && Policy.reads.contains($0.uuid.uuidString) }
        servicesPending -= 1; guard servicesPending == 0 else { return }
        guard let c = readable.sorted(by: { Policy.reads.firstIndex(of: $0.uuid.uuidString)! < Policy.reads.firstIndex(of: $1.uuid.uuidString)! }).first else { unsupported(); return }
        characteristic = c; connecting = false; generation += 1; nextSend = .distantPast; schedule()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, self.characteristic === characteristic, blePending else { return }
        blePending = false; generation += 1
        completed(error == nil && characteristic.value != nil, generic: true, error: error?.localizedDescription ?? "empty_read")
    }
    func show(_ state: String, _ text: String) {
        let changed = self.state != state
        self.state = state; message = text; status.title = text
        let ok = state == "sending" || state == "generic_reading"
        item?.button?.title = menuName + " " + (ok ? "●" : "○")
        item?.button?.toolTip = selected.map { "\($0.name) · \(Int(interval)) 秒\n\(text)" } ?? text
        persist(force: changed)
    }
    func persist(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPersist) >= 60 else { return }
        lastPersist = Date()
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var data: [String: Any] = ["version": Build.version, "build": Build.stamp, "state": state, "pid": getpid(), "app_path": Bundle.main.bundlePath, "interval_seconds": interval, "successful_reports": reports, "failures": failures, "error": errorText, "updated_at": ISO8601DateFormatter().string(from: Date()), "autostart_configured": loginConfigured, "autostart_loaded": loginLoaded, "input_monitoring_authorized": CGPreflightListenEventAccess(), "input_capture": false, "firmware_write_commands": 0]
        if let m = selected { data["mouse_name"] = m.name; data["method"] = m.a6 ? "a6_matched_standard_hid_led" : "experimental_standard_ble_read" }
        if let date = lastSuccess { data["last_success_at"] = ISO8601DateFormatter().string(from: date) }
        if let test = UserDefaults.standard.dictionary(forKey: settingsKey("test")) { data["user_reported_idle_test"] = test }
        if let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) { try? encoded.write(to: statusURL, options: .atomic) }
    }
    @objc func authorize() {
        if Build.a6Only || selected?.a6 == true {
            if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        } else {
            if central == nil { central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
        }
    }
    func alert(_ title: String, _ text: String) { let a = NSAlert(); a.messageText = title; a.informativeText = text; a.addButton(withTitle: "好"); NSApp.activate(ignoringOtherApps: true); a.runModal() }
    @objc func renameMenu() {
        let a = NSAlert(); a.messageText = "菜单栏名称"; a.informativeText = "最多 12 个字符；留空恢复为“鼠标”。只修改菜单栏文字。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.stringValue = menuName
        a.accessoryView = field; a.addButton(withTitle: "保存"); a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = field; NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        menuName = Policy.menuName(field.stringValue); UserDefaults.standard.set(menuName, forKey: "menuBarName")
        show(state, message)
    }
    @objc func details() {
        let method = selected?.a6 == true ? "A6 精确匹配：标准 HID 状态报告" : "兼容尝试：只读取标准蓝牙服务"
        let success = lastSuccess.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? "尚无"
        let test = UserDefaults.standard.dictionary(forKey: settingsKey("test"))
        let testText = test.map { "\($0["result"] ?? "")，\($0["minutes"] ?? 0) 分钟，\($0["interval_seconds"] ?? 0) 秒间隔（用户反馈）" } ?? "尚未测试"
        alert("\(Build.title) \(Build.version)", "\(selected?.name ?? "未选择鼠标") · \(message)\n间隔：\(Int(interval)) 秒\n方式：\(method)\n成功：\(reports) 次；失败：\(failures) 次\n最近通信：\(success)\n登录启动：\(loginConfigured && loginLoaded ? "已配置并加载" : "未启用或需重新设置")\n静置测试：\(testText)\n\(errorText.isEmpty ? "" : "最近错误：\(errorText)\n")\nMac 须保持唤醒。读取成功不代表已阻止深度休眠。15 秒接近 A6 的闲置边界，建议先用 10 秒测试。")
    }
    @objc func testAction() {
        if let start = testStart {
            let minutes = Int(Date().timeIntervalSince(start) / 60)
            if !testNeedsResult { alert("静置测试进行中", "已计时 \(minutes) 分钟，目标 25 分钟。期间请用触控板，不操作鼠标，并保持 Mac 唤醒。完成后先移动鼠标，再在这里记录结果。"); return }
            let a = NSAlert(); a.messageText = "鼠标移动后能立即响应吗？"; a.informativeText = "已计时 \(minutes) 分钟。请先移动、不点击。程序不监听鼠标动作，实际静置时长需要你确认；若中途操作过鼠标，请取消后重测。"
            for title in ["移动立即响应", "必须点击唤醒", "取消本次测试"] { a.addButton(withTitle: title) }
            let answer = a.runModal()
            if answer == .alertFirstButtonReturn || answer == .alertSecondButtonReturn {
                let good = answer == .alertFirstButtonReturn
                let record: [String: Any] = ["result": good ? "移动立即响应" : "仍需点击", "minutes": minutes, "interval_seconds": testInterval, "reported_at": ISO8601DateFormatter().string(from: Date()), "source": "user_report", "successful_reports_during_test": reports - testReports]
                UserDefaults.standard.set(record, forKey: settingsKey("test"))
                if good { UserDefaults.standard.set(testInterval, forKey: settingsKey("lastEffectiveInterval")) }
            }
            testStart = nil; testNeedsResult = false; updateMenu(); persist(force: true); return
        }
        guard !paused, !sleeping, state == "sending" || state == "generic_reading", let selected = selected else { alert("暂时不能测试", "请先确认保活通信正常。"); return }
        let a = NSAlert(); a.messageText = "开始 25 分钟静置测试？"; a.informativeText = "点击开始后，请用触控板，并保持 Mac 唤醒。计时完成后先移动鼠标，不要点击，再到此菜单记录结果。程序不监听鼠标动作；若中途操作鼠标，本次结果无效。"
        a.addButton(withTitle: "开始"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        testStart = Date(); testKey = selected.key; testInterval = Int(interval); testFailures = failures; testReports = reports; testNeedsResult = false; updateMenu()
    }
    func checkTest() {
        guard let start = testStart else { return }
        if selected?.key != testKey || Int(interval) != testInterval || failures != testFailures { cancelTest("测试条件已改变"); return }
        if Date().timeIntervalSince(start) >= 25 * 60 { testNeedsResult = true; updateMenu() }
    }
    func cancelTest(_ reason: String) { if testStart != nil { testStart = nil; testNeedsResult = false; updateMenu() } }
    func launchctl(_ args: [String]) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }
    func refreshLogin() {
        loginConfigured = false
        if let data = try? Data(contentsOf: agent), let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any], let args = p["ProgramArguments"] as? [String] {
            loginConfigured = p["Label"] as? String == Build.label && p["RunAtLoad"] as? Bool == true && args.contains(Bundle.main.bundlePath)
        }
        loginLoaded = loginConfigured && launchctl(["print", "gui/\(getuid())/\(Build.label)"])
        if loginLoaded {
            let p = Process(), output = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["print-disabled", "gui/\(getuid())"]
            p.standardOutput = output; p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                if text.split(separator: "\n").contains(where: { $0.contains("\"\(Build.label)\"") && ($0.contains("=> true") || $0.contains("=> disabled")) }) { loginLoaded = false }
            } catch { loginLoaded = false }
        }
        loginItem?.state = loginConfigured && loginLoaded ? .on : (loginConfigured ? .mixed : .off)
    }
    @objc func toggleLogin() {
        refreshLogin()
        do {
            if loginConfigured && loginLoaded {
                guard launchctl(["bootout", "gui/\(getuid())/\(Build.label)"]) else { alert("无法取消启动", "系统没有移除启动项，请稍后重试。"); return }
                try FileManager.default.removeItem(at: agent)
            } else {
                let allowed = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path, "/Applications"]
                guard allowed.contains(Bundle.main.bundleURL.deletingLastPathComponent().path) else { alert("请先安装", "请先把应用放入 Applications 文件夹。"); return }
                let dir = agent.deletingLastPathComponent(); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for file in files where file != agent && file.pathExtension == "plist" {
                    if let data = try? Data(contentsOf: file), let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any], p["Label"] as? String == Build.label {
                        alert("已有旧版启动项", "请先用旧版关闭登录启动，再为新版启用，避免两个版本重复启动。"); return
                    }
                }
                if FileManager.default.fileExists(atPath: agent.path) && !loginConfigured { alert("启动项不匹配", "同名文件属于其他安装位置，请先检查旧版启动项。"); return }
                let plist: [String: Any] = ["Label": Build.label, "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath], "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agent, options: .atomic)
                guard launchctl(["enable", "gui/\(getuid())/\(Build.label)"]) && launchctl(["bootstrap", "gui/\(getuid())", agent.path]) else { alert("尚未启用登录启动", "配置已保存，但系统加载失败，请重新点击尝试。"); refreshLogin(); return }
            }
            refreshLogin(); persist(force: true)
        } catch { alert("启动项设置失败", error.localizedDescription) }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        quitting = true; timer?.invalidate(); closeConnections(); releaseDevice()
        if item != nil { show("stopped", "已停止"); persist(force: true) }
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}

func selfTest() -> Never {
    var count = 0
    func check(_ condition: Bool, _ name: String) { guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }; count += 1 }
    check(Policy.isA6(10007, 12976, "A6 Ultra", "Bluetooth Low Energy", Policy.descriptor, 2), "A6 routing")
    check(!Policy.isA6(10007, 12976, "A6 Ultra", "USB", Policy.descriptor, 2), "reject USB")
    check(!Policy.isA6(10007, 12976, "Other", "Bluetooth Low Energy", Policy.descriptor, 2), "reject other mouse")
    check(!Policy.isA6(10007, 12976, "A6 Ultra", "Bluetooth Low Energy", "bad", 2), "reject descriptor")
    check(!Policy.isA6(10007, 12976, "A6 Ultra", "Bluetooth Low Energy", Policy.descriptor, 3), "reject length")
    check(Policy.uniqueIndex(["Mouse", "Other"], "Mouse") == 0, "unique BLE")
    check(Policy.uniqueIndex(["Mouse", "Mouse"], "Mouse") == nil, "ambiguous BLE")
    check(Policy.uniqueIndex(["Other"], "Mouse") == nil, "missing BLE")
    check(!Policy.reads.contains("FF01"), "no vendor characteristics")
    check([1, 2, 3, 4, 5, 20].map(Policy.retryDelay) == [2, 4, 8, 16, 30, 30], "bounded retry")
    check(Policy.validInterval(0) == 10 && Policy.validInterval(15) == 15, "interval migration")
    check(Policy.menuName("  ") == "鼠标", "empty menu name fallback")
    check(Policy.menuName("A6\nMouse") == "A6 Mouse", "single-line menu name")
    check(Policy.menuName("abcdefghijklmnop").count == 12, "menu name length")
    let a = FileLock(), b = FileLock(), key = "selftest:\(UUID().uuidString)"
    check(a.acquire(key), "first lock"); check(!b.acquire(key), "exclusive lock")
    a.release(); check(b.acquire(key), "lock release"); b.release()
    print("PASS: \(count) offline checks; no mouse opened."); exit(0)
}
if CommandLine.arguments.contains("--self-test") { selfTest() }
if CommandLine.arguments.contains("--list-mice") {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2] as CFDictionary)
    let data = inventory(manager).map { ["key": $0.key, "name": $0.name, "a6": $0.a6] as [String: Any] }
    let json = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
    print(String(data: json, encoding: .utf8)!); exit(0)
}
if CommandLine.arguments.contains("--mock-hid-ok") { while readLine() != nil { print("0"); fflush(stdout) }; exit(0) }
if CommandLine.arguments.contains("--mock-hid-hang") { while readLine() != nil { sleep(30) }; exit(0) }
if CommandLine.arguments.contains("--mock-hid-exit") { exit(9) }
if CommandLine.arguments.contains("--worker-self-test") {
    signal(SIGPIPE, SIG_IGN)
    let worker = HIDWorker()
    func wait(_ condition: () -> Bool, _ seconds: Double = 6) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        if !condition() { fputs("FAIL: worker deadline\n", stderr); exit(1) }
    }
    var answer: (Bool, String)?
    worker.arguments = ["--mock-hid-ok"]; worker.send { answer = ($0, $1) }
    wait { answer != nil }
    guard answer!.0 else { exit(1) }
    let pid = worker.process!.processIdentifier
    answer = nil; worker.send { answer = ($0, $1) }; wait { answer != nil }
    guard answer!.0, worker.process?.processIdentifier == pid else { exit(1) }
    worker.stop(); wait { worker.process == nil }
    worker.arguments = ["--mock-hid-hang"]; answer = nil; worker.send { answer = ($0, $1) }
    wait { answer != nil }
    guard answer!.1 == "hid_timeout" else { exit(1) }
    wait { worker.process == nil }
    worker.arguments = ["--mock-hid-exit"]; answer = nil; worker.send { answer = ($0, $1) }
    wait { answer != nil }; guard !answer!.0 else { exit(1) }
    wait { worker.process == nil }
    worker.arguments = ["--mock-hid-ok"]; answer = nil; worker.send { answer = ($0, $1) }
    wait { answer != nil }; guard answer!.0 else { exit(1) }
    worker.stop(); wait { worker.process == nil }
    print("PASS: persistent worker, timeout termination, unexpected exit, recovery; no mouse opened."); exit(0)
}
if CommandLine.arguments.contains("--hid-worker") { runHIDWorker() }
let app = NSApplication.shared
let delegate = Keepalive(); app.delegate = delegate
app.setActivationPolicy(.accessory); app.run()
