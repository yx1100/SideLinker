import AppKit
import ServiceManagement
import UserNotifications

/// 菜单栏 App：无屏时自动连随航，UU 连入时切到 iPad 单屏
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let work = DispatchQueue(label: "sidelinker.work") // 显示配置和随航连接都会阻塞等待，串行放在这里
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let agent = SMAppService.agent(plistName: "com.yx1100.sidelinker.plist")
    private let uu = UUWatcher()
    private var gate = RemoteGate(grace: 60)
    private var remoteScreen: VirtualScreen?
    private var lockAfterRestore = false // UU 会话结束后恢复物理屏，再锁屏
    private var stableModes: [CGDirectDisplayID: Int32] = [:] // 持续 10 秒没变的分辨率，恢复时用
    private var pendingModes: [CGDirectDisplayID: Int32] = [:]
    private var pendingSince = Date()
    private var busy = false // 显示配置切换中，暂停自动判断
    private var sigterm: DispatchSourceSignal?

    /// 单屏是否在生效：虚拟屏还在，或物理屏还关着（例如 App 崩溃后重启）
    private var remoteApplied: Bool { remoteScreen != nil || Displays.hasSavedLayout }

    // 便携随航状态
    private var portable = false
    private var baseline: Set<CGDirectDisplayID> = [] // 进入时已有的显示器：真实无屏时为空，调试模式下是本机物理屏
    private var dummy: VirtualScreen?
    private var sidecarDisplay: CGDirectDisplayID?
    private var portableSince = Date()
    private var nextAttempt = Date.distantPast
    private var connecting = false
    private var reconnectPaused = false

    private var autoEnabled: Bool {
        get { !defaults.bool(forKey: "autoDisabled") }
        set { defaults.set(!newValue, forKey: "autoDisabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            exit(0)
        }
        statusItem.button?.image = NSImage(systemSymbolName: "ipad.landscape", accessibilityDescription: "SideLinker")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }

        // launchd 停止 App 时也先恢复显示器
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }
        sigterm?.resume()

        // 上次异常退出时物理屏可能还关着：remoteApplied 为真，tickRemote 会按当前 UU 状态恢复或重新进入
        uu.onPoll = { [weak self] in self?.tickRemote() }
        uu.start()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.evaluatePortable() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        var screen = remoteScreen
        remoteScreen = nil
        work.sync {
            if Displays.hasSavedLayout || screen != nil { _ = Displays.restore(releasing: &screen) }
        }
    }

    // MARK: 远程单屏

    /// 每 2 秒对齐一次：gate 决定要不要单屏，锁屏时 macOS 不允许改显示配置，等解锁后再补做
    private func tickRemote() {
        // UU 连入前约 1 秒会改主屏分辨率，断开时显示器还关着，它改不回去，所以平时记下稳定的分辨率
        if !gate.active && !remoteApplied && !uu.connected {
            let modes = Displays.modeIDs(of: Displays.online())
            if modes != pendingModes {
                pendingModes = modes
                pendingSince = Date()
            } else if Date().timeIntervalSince(pendingSince) >= 10 {
                stableModes = modes
            }
        }
        _ = gate.update(session: uu.connected, now: Date(), autoEnter: autoEnabled)
        if gate.active && uu.connected { lockAfterRestore = true }
        let locked = Session.isLocked
        if locked && !gate.active { lockAfterRestore = false } // 已被锁过（如 UU 自动锁屏），解锁后不再重复锁
        guard !busy, !locked else { return }
        if gate.active && remoteScreen == nil {
            enterRemote()
        } else if !gate.active && remoteApplied {
            exitRemote()
        }
    }

    private func enterRemote() {
        leavePortable()
        // 13 英寸 iPad Pro 横屏：2752×2064 像素，264 ppi
        guard let screen = VirtualScreen(name: "SideLinker iPad", width: 2752, height: 2064, ppi: 264, productID: 1) else {
            gate.manualExit(session: uu.connected)
            notify("虚拟屏创建失败")
            return
        }
        remoteScreen = screen
        busy = true
        let modes = stableModes
        work.async {
            let allOff = Displays.enterSingleScreen(screen, modes: modes)
            DispatchQueue.main.async {
                self.busy = false
                self.notify(allOff ? "已切换为 iPad 单屏" : "部分显示器无法关闭，已改为镜像 iPad 单屏")
            }
        }
    }

    private func exitRemote() {
        var screen = remoteScreen
        remoteScreen = nil
        busy = true
        work.async {
            let restored = Displays.restore(releasing: &screen)
            DispatchQueue.main.async {
                self.busy = false
                guard restored else {
                    self.remoteScreen = screen // 恢复途中被锁屏：留着虚拟屏，解锁后重试
                    return
                }
                self.notify("已恢复物理显示器")
                if self.lockAfterRestore { Session.lock() }
                self.lockAfterRestore = false
            }
        }
    }

    // MARK: 便携随航

    private func evaluatePortable() {
        // 远程单屏关掉的物理屏不算「没有显示器」
        guard !busy, !connecting, !gate.active, !remoteApplied else { return }
        let sidecarOn = !Sidecar.connected().isEmpty
        let displays = Set(Displays.online()).subtracting([dummy?.id, remoteScreen?.id].compactMap { $0 })

        guard portable else {
            // 随航未连接，且除本 App 的虚拟屏外没有任何显示器
            if autoEnabled, !sidecarOn, displays.isEmpty || defaults.bool(forKey: "debugForcePortable") {
                enterPortable(baseline: displays)
            }
            return
        }
        let extra = displays.subtracting(baseline).subtracting([sidecarDisplay].compactMap { $0 })
        if sidecarOn {
            if sidecarDisplay == nil, extra.count == 1, let id = extra.first {
                // 随航刚连上：占位屏改为它的镜像，iPad 成为唯一屏幕
                sidecarDisplay = id
                if let dummyID = dummy?.id { work.async { Displays.mirror(dummyID, of: id) } }
            } else if sidecarDisplay != nil, !extra.isEmpty {
                leavePortable() // 接上了物理显示器
            }
            return
        }
        if sidecarDisplay != nil {
            // 随航断开：占位屏顶上，10 秒后重连
            sidecarDisplay = nil
            nextAttempt = Date() + 10
            if let dummyID = dummy?.id { work.async { Displays.mirror(dummyID, of: kCGNullDirectDisplay) } }
        }
        if !extra.isEmpty {
            leavePortable()
        } else if !reconnectPaused, Date() >= nextAttempt {
            connectSidecar()
        }
    }

    private func enterPortable(baseline: Set<CGDirectDisplayID>) {
        portable = true
        self.baseline = baseline
        portableSince = Date()
        nextAttempt = .distantPast
        reconnectPaused = false
        // 原作者发现完全无屏时随航不稳定，先放一块占位屏；实测不需要可用 noDummy 关掉
        if !defaults.bool(forKey: "noDummy") {
            dummy = VirtualScreen(name: "SideLinker 占位屏", width: 1920, height: 1080, ppi: 92, productID: 2)
        }
        evaluatePortable()
    }

    private func leavePortable() {
        portable = false
        baseline = []
        sidecarDisplay = nil
        dummy = nil
    }

    /// device 为空时按「上次连上的设备优先」依次尝试
    private func connectSidecar(_ device: NSObject? = nil) {
        connecting = true
        let preferred = defaults.string(forKey: "preferredDevice")
        work.async {
            let all = device.map { [$0] } ?? Sidecar.devices()
            let ordered = all.filter { Sidecar.identifier($0) == preferred } + all.filter { Sidecar.identifier($0) != preferred }
            let connected = Sidecar.connectFirst(of: ordered)
            DispatchQueue.main.async {
                self.connecting = false
                // 前 2 分钟每 5 秒重试，之后每 30 秒
                self.nextAttempt = Date() + (Date().timeIntervalSince(self.portableSince) < 120 ? 5 : 30)
                if let connected {
                    self.defaults.set(Sidecar.identifier(connected), forKey: "preferredDevice")
                    self.notify("随航已连接：\(Sidecar.name(connected))")
                    self.evaluatePortable()
                } else if device != nil {
                    self.notify("随航连接失败")
                }
            }
        }
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let connected = Sidecar.connected()
        let status = remoteApplied ? (gate.active ? "远程单屏中" : "等待恢复物理屏")
            : connected.first.map { "随航已连接：\(Sidecar.name($0))" }
            ?? (connecting ? "正在连接随航…" : portable ? "等待连接随航" : "空闲")
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        addItem(to: menu, "自动处理", #selector(toggleAuto), checked: autoEnabled)
        menu.addItem(.separator())

        let devices = NSMenu()
        for device in Sidecar.devices() {
            let item = NSMenuItem(title: Sidecar.name(device), action: connecting ? nil : #selector(connectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            devices.addItem(item)
        }
        if devices.items.isEmpty { devices.addItem(withTitle: "未发现设备", action: nil, keyEquivalent: "").isEnabled = false }
        menu.addItem(withTitle: "连接随航", action: nil, keyEquivalent: "").submenu = devices
        addItem(to: menu, "断开随航", connected.isEmpty ? nil : #selector(disconnectSidecar))
        addItem(to: menu, gate.active ? "退出远程单屏" : "进入远程单屏", busy ? nil : #selector(toggleRemote))
        menu.addItem(.separator())
        addItem(to: menu, "登录时启动", #selector(toggleLogin), checked: agent.status == .enabled)
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector?, checked: Bool = false) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
    }

    @objc private func toggleAuto() {
        autoEnabled.toggle()
        if !autoEnabled { leavePortable() }
    }

    @objc private func connectDevice(_ item: NSMenuItem) {
        guard let device = item.representedObject as? NSObject else { return }
        reconnectPaused = false
        connectSidecar(device)
    }

    /// 便携场景下手动断开后不再自动重连；在 iPad 上直接断开会在 10 秒后重连
    @objc private func disconnectSidecar() {
        if portable { reconnectPaused = true }
        work.async { Sidecar.connected().forEach { _ = Sidecar.disconnect($0) } }
    }

    @objc private func toggleRemote() {
        if gate.active {
            gate.manualExit(session: uu.connected)
            lockAfterRestore = false
        } else {
            gate.manualEnter()
        }
        tickRemote()
    }

    @objc private func toggleLogin() {
        do {
            if agent.status == .enabled { try agent.unregister() } else { try agent.register() }
            if agent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            notify("设置登录时启动失败：\(error.localizedDescription)")
        }
    }

    private func notify(_ text: String) {
        guard Bundle.main.bundleIdentifier != nil else { print(text); return }
        let content = UNMutableNotificationContent()
        content.title = "SideLinker"
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
