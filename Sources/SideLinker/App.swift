import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

/// 菜单栏 App：无屏时自动连随航；UU 远程时手动切到 iPad 单屏，断开后自动恢复
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let work = DispatchQueue(label: "sidelinker.work") // 显示配置和随航连接都会阻塞等待，串行放在这里
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let agent = SMAppService.agent(plistName: "com.yx1100.sidelinker.plist")
    private let uu = UUWatcher()
    private var gate = RemoteGate(grace: 30) // UU 日志里见过断开 22 秒后又连上，30 秒内重连不来回切换
    private var remoteScreen: VirtualScreen?
    private var lockAfterRestore = false // UU 会话结束后恢复物理屏，再锁屏
    private var autoSuppressed = false // 本次会话中手动恢复过，不再自动切换
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

    private let model = SettingsModel()
    private var settingsWindow: NSWindow?

    /// 连入时自动切换单屏的设备：ID → 名称（兼容旧版只存 ID 的数组）
    private var autoDevices: [String: String] {
        get {
            if let names = defaults.dictionary(forKey: "autoDevices") as? [String: String] { return names }
            return Dictionary(uniqueKeysWithValues: (defaults.stringArray(forKey: "autoDevices") ?? []).map { ($0, $0) })
        }
        set { defaults.set(newValue, forKey: "autoDevices") }
    }

    private var autoEnabled: Bool {
        get { !defaults.bool(forKey: "autoDisabled") }
        set { defaults.set(!newValue, forKey: "autoDisabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            exit(0)
        }
        bindModel()
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
            self?.publish()
        }
    }

    /// 在启动台或「应用程序」里再次打开 SideLinker 时显示设置窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
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
        // 记住的设备连入时自动切换；电脑、手机等其他设备连入时不动
        if !uu.connected { autoSuppressed = false }
        if uu.connected, !gate.active, !remoteApplied, !autoSuppressed, !Set(autoDevices.keys).isDisjoint(with: uu.controllers.keys) {
            gate.enter()
        }
        if gate.active && uu.connected { lockAfterRestore = true }
        let locked = Session.isLocked
        if locked && !gate.active { lockAfterRestore = false } // 已被锁过（如 UU 自动锁屏），解锁后不再重复锁
        if settingsWindow?.isVisible == true { publish() }
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
                if !allOff { self.notify("部分显示器无法关闭，已改为镜像") }
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
        } else if Date() >= nextAttempt {
            connectSidecar()
        }
    }

    private func enterPortable(baseline: Set<CGDirectDisplayID>) {
        portable = true
        self.baseline = baseline
        portableSince = Date()
        nextAttempt = .distantPast
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

    /// 按「上次连上的设备优先」依次尝试
    private func connectSidecar() {
        connecting = true
        let preferred = defaults.string(forKey: "preferredDevice")
        work.async {
            let all = Sidecar.devices()
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
        // SF Symbol 的外框带留白，按 17pt 字号、中等粗细绘制，和菜单栏其他图标观感一致
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: "SideLinker")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium)) else { return }
        image.isTemplate = true
        statusItem.button?.image = image
    }

    /// 菜单栏只呈现信息，可点的只有「设置…」和「退出」
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshIcon()
        publish()

        menu.addItem(info(model.stateTitle, detail: stateDetail()))
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "随航"))
        if model.sidecarDevices.isEmpty { menu.addItem(info("附近没有 iPad")) }
        for device in model.sidecarDevices {
            menu.addItem(info(device.name, detail: device.connected ? "已连接" : "未连接",
                              symbol: device.connected ? "ipad.landscape.badge.play" : "ipad.landscape"))
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: uu.connected ? "UU 远程 · 已连接" : "UU 远程 · 未连接"))
        menu.addItem(info(model.remoteActive ? "iPad 单屏已开启" : "iPad 单屏未开启", symbol: "rectangle.inset.filled"))
        for name in uu.controllers.values.sorted() { menu.addItem(info(name, detail: "已连入", symbol: "ipad.landscape")) }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "退出 SideLinker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func stateDetail() -> String {
        switch currentState() {
        case .restoring: Session.isLocked ? "解锁后继续" : ""
        case .sidecar(let name): name
        default: ""
        }
    }

    /// 不可点的信息行
    private func info(_ title: String, detail: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if #available(macOS 14.4, *), !detail.isEmpty { item.subtitle = detail }
        return item
    }

    // MARK: 设置窗口

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "SideLinker 设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 680, height: 460))
            window.center()
            settingsWindow = window
        }
        publish()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// 把当前状态写进设置窗口的模型
    private func publish() {
        switch currentState() {
        case .remote: model.stateTitle = "iPad 单屏中"
        case .restoring: model.stateTitle = "正在恢复物理显示器"
        case .sidecar: model.stateTitle = "随航已连接"
        case .connecting: model.stateTitle = "正在连接随航…"
        case .waiting: model.stateTitle = "等待 iPad"
        case .idle: model.stateTitle = "就绪"
        }
        let connected = Sidecar.connected()
        model.sidecarDevices = Sidecar.devices().map {
            .init(id: Sidecar.identifier($0), name: Sidecar.name($0), connected: connected.contains($0))
        }
        model.autoConnect = autoEnabled
        model.uuConnected = uu.connected
        model.remoteActive = gate.active
        model.busy = busy || (remoteApplied && !gate.active)
        model.controllers = uu.connected ? uu.controllers : [:]
        // 名称跟随 UU：设备每次连入，UU 都会在日志里写下它当前的名称，这里取最新的一条
        for (id, name) in autoDevices { if let seen = uu.known[id], seen.name != name { autoDevices[id] = seen.name } }
        model.autoDevices = autoDevices
        let labels = [1: "Windows", 3: "iOS / iPadOS", 4: "macOS"]
        var details: [String: String] = [:]
        for id in Set(autoDevices.keys).union(uu.controllers.keys) {
            details[id] = ([uu.known[id].flatMap { labels[$0.platform] }].compactMap { $0 } + [id]).joined(separator: " · ")
        }
        model.details = details
        model.launchAtLogin = agent.status == .enabled
    }

    private func bindModel() {
        model.setAutoConnect = { [weak self] on in
            guard let self else { return }
            autoEnabled = on
            if !on { leavePortable() }
            publish()
        }
        model.toggleRemote = { [weak self] in
            guard let self else { return }
            if gate.active {
                gate.exit()
                lockAfterRestore = false
                autoSuppressed = uu.connected
            } else {
                gate.enter()
            }
            tickRemote()
            refreshIcon()
            publish()
        }
        model.setAutoDevice = { [weak self] id, on in
            guard let self else { return }
            autoDevices[id] = on ? (uu.controllers[id] ?? autoDevices[id] ?? id) : nil
            publish()
        }
        model.setLaunchAtLogin = { [weak self] on in
            guard let self else { return }
            do {
                if on { try agent.register() } else { try agent.unregister() }
                if agent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch {
                notify("设置登录时启动失败：\(error.localizedDescription)")
            }
            publish()
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
