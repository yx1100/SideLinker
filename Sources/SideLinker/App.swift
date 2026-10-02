import AppKit
import ServiceManagement
import UserNotifications

/// 菜单栏 App：无屏时自动连随航；UU 远程时手动切到 iPad 单屏，断开后自动恢复
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let work = DispatchQueue(label: "sidelinker.work") // 显示配置和随航连接都会阻塞等待，串行放在这里
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let agent = SMAppService.agent(plistName: "com.yx1100.sidelinker.plist")
    private let uu = UUWatcher()
    private var gate = RemoteGate(grace: 30) // UU 日志里见过断开 22 秒后又连上，30 秒内重连不来回切换
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
        refreshIcon()
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
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.evaluatePortable()
            self?.refreshIcon()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        var screen = remoteScreen
        remoteScreen = nil
        work.sync {
            if Displays.hasSavedLayout || screen != nil { _ = Displays.restore(releasing: &screen) }
        }
    }

    // MARK: 远程单屏

    /// 每 2 秒对齐一次：单屏只能手动进入，UU 断开后由 gate 决定退出；锁屏时 macOS 不允许改显示配置，等解锁后再补做
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
        _ = gate.update(session: uu.connected, now: Date())
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
            gate.exit()
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
                self.refreshIcon()
                if !allOff { self.notify("部分显示器无法关闭，已改为镜像 iPad 单屏，这些显示器仍会显示画面") }
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
                self.refreshIcon()
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
                    self.refreshIcon()
                } else if device != nil {
                    self.notify("随航连接失败")
                }
            }
        }
    }

    // MARK: 菜单

    private enum State { case remote, restoring, sidecar(String), connecting, waiting, idle }

    private func currentState() -> State {
        if remoteApplied { return gate.active ? .remote : .restoring }
        if let device = Sidecar.connected().first { return .sidecar(Sidecar.name(device)) }
        if connecting { return .connecting }
        return portable ? .waiting : .idle
    }

    private func refreshIcon() {
        let name: String
        switch currentState() {
        case .remote, .restoring: name = "rectangle.inset.filled"
        case .sidecar: name = "ipad.landscape.badge.play"
        case .connecting, .waiting: name = "ipad.and.arrow.forward"
        case .idle: name = "ipad.landscape"
        }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "SideLinker")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshIcon()

        let (title, detail): (String, String)
        switch currentState() {
        case .remote: (title, detail) = ("iPad 单屏中", uu.connected ? "UU 断开 30 秒后自动恢复并锁屏" : "未检测到 UU 连接，30 秒后自动恢复")
        case .restoring: (title, detail) = ("正在恢复物理显示器", Session.isLocked ? "解锁后继续" : "请稍候")
        case .sidecar(let name): (title, detail) = ("随航已连接", name)
        case .connecting: (title, detail) = ("正在连接随航…", "先试有线，再试无线")
        case .waiting: (title, detail) = ("等待 iPad", "没有显示器，正在自动连接随航")
        case .idle: (title, detail) = ("就绪", "")
        }
        let status = item(title, nil, symbol: nil, detail: detail)
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "随航"))
        let connected = Sidecar.connected()
        let devices = Sidecar.devices()
        for device in devices {
            let isOn = connected.contains(device)
            let deviceItem = item(Sidecar.name(device), connecting || busy ? nil : #selector(toggleDevice(_:)),
                                  symbol: "ipad.landscape", detail: isOn ? "已连接，点按断开" : "点按连接")
            deviceItem.state = isOn ? .on : .off
            deviceItem.representedObject = device
            menu.addItem(deviceItem)
        }
        if devices.isEmpty {
            let none = item("附近没有可用的 iPad", nil, symbol: "ipad.landscape", detail: "确认 iPad 已解锁，并登录同一 Apple 账户")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(item("没有显示器时自动连接", #selector(toggleAuto), symbol: nil, detail: "适合带 Mac mini 出门", checked: autoEnabled))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: uu.connected ? "UU 远程 · 已连接" : "UU 远程 · 未连接"))
        let remote = gate.active
            ? item("恢复物理显示器", busy ? nil : #selector(toggleRemote), symbol: "display.2", detail: "退出单屏，不锁屏")
            : item("切换到 iPad 单屏", busy || remoteApplied ? nil : #selector(toggleRemote), symbol: "rectangle.inset.filled",
                   detail: "只保留一块 2752×2064 的屏幕，关闭其他显示器")
        menu.addItem(remote)

        menu.addItem(.separator())
        menu.addItem(item("登录时启动", #selector(toggleLogin), symbol: nil, detail: "", checked: agent.status == .enabled))
        let quit = NSMenuItem(title: "退出 SideLinker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector?, symbol: String?, detail: String, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if #available(macOS 14.4, *), !detail.isEmpty { item.subtitle = detail }
        return item
    }

    @objc private func toggleAuto() {
        autoEnabled.toggle()
        if !autoEnabled { leavePortable() }
    }

    /// 点已连接的设备即断开。便携场景下手动断开后不再自动重连；在 iPad 上直接断开会在 10 秒后重连
    @objc private func toggleDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? NSObject else { return }
        if Sidecar.connected().contains(device) {
            if portable { reconnectPaused = true }
            work.async {
                _ = Sidecar.disconnect(device)
                DispatchQueue.main.async { self.refreshIcon() }
            }
        } else {
            reconnectPaused = false
            connectSidecar(device)
            refreshIcon()
        }
    }

    @objc private func toggleRemote() {
        if gate.active {
            gate.exit()
            lockAfterRestore = false
        } else {
            gate.enter()
        }
        tickRemote()
        refreshIcon()
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
