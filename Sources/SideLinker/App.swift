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
    private var previousApp: NSRunningApplication? // 打开菜单前处于前台的 App

    /// 虚拟屏的尺寸，在设置窗口里选
    private var screenSize: ScreenSize {
        get { ScreenSize.from(id: defaults.string(forKey: "screenSize")) }
        set { defaults.set(newValue.id, forKey: "screenSize") }
    }
    private var activeSize: ScreenSize? // 只用 iPad 显示时虚拟屏的尺寸

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
        let size = screenSize
        guard let screen = VirtualScreen(name: "SideLinker iPad", width: UInt32(size.width), height: UInt32(size.height),
                                         ppi: 264, productID: 1) else {
            gate.exit()
            notify("虚拟显示器创建失败")
            return
        }
        remoteScreen = screen
        activeSize = size
        busy = true
        let modes = stableModes
        work.async {
            let allOff = Displays.enterSingleScreen(screen, modes: modes)
            DispatchQueue.main.async {
                self.busy = false
                self.refreshIcon()
                if !allOff { self.notify("部分显示器无法停用，已改为镜像显示") }
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
                self.activeSize = nil
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

    /// 第一组列出当前已建立的连接；随航和远程连接两组未连接时只显示标题，已连接时展开详情。
    /// 可点的是「使用 iPad 单屏显示」「设置…」和「退出」
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshIcon()
        publish()

        let sidecar = model.sidecarDevices.filter(\.connected)
        var status: [NSMenuItem] = []
        if !sidecar.isEmpty { status.append(info("随航已连接", symbol: "ipad.landscape.badge.play")) }
        if remoteApplied {
            status.append(info(gate.active ? "正在使用 iPad 单屏显示" : "正在恢复物理显示器",
                               detail: Session.isLocked && !gate.active ? "将在解锁后继续" : "",
                               symbol: "rectangle.inset.filled"))
        } else if uu.connected {
            status.append(info("远程连接已建立", symbol: "display"))
        }
        if status.isEmpty {
            status.append(info(connecting ? "正在连接随航…" : portable ? "正在等待 iPad" : "未建立连接"))
        }
        status.forEach(menu.addItem)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: sidecar.isEmpty ? "随航 · 未连接" : "随航 · 已连接"))
        for device in sidecar { menu.addItem(info(device.name, symbol: "ipad.landscape.badge.play")) }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: uu.connected ? "远程连接 · 已连接" : "远程连接 · 未连接"))
        // 与设置窗口中的开关条件一致：UU 已连接，或单屏仍在开启中时可以操作
        if uu.connected || gate.active {
            let toggle = NSMenuItem()
            toggle.view = SwitchRow(title: "使用 iPad 单屏显示", detail: (activeSize ?? screenSize).summary,
                                    symbol: "rectangle.inset.filled", on: gate.active, enabled: !model.busy,
                                    target: self, action: #selector(toggleRemote))
            menu.addItem(toggle)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "退出 SideLinker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// 和控制中心一样，拨动开关后菜单保持打开，原地刷新内容
    /// 菜单栏 App 不在前台时，菜单里的开关按非活跃窗口绘制成灰色。打开菜单时临时切到前台，关闭后还给原来的 App
    func menuWillOpen(_ menu: NSMenu) {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == .current ? nil : front
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuDidClose(_ menu: NSMenu) {
        let app = previousApp
        previousApp = nil
        // 菜单项的动作在关闭后才执行：点了「设置…」时保持在前台
        DispatchQueue.main.async { if self.settingsWindow?.isKeyWindow != true { app?.activate() } }
    }

    @objc private func toggleRemote() {
        model.toggleRemote()
        DispatchQueue.main.async { if let menu = self.statusItem.menu { self.menuNeedsUpdate(menu) } }
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
            window.setContentSize(NSSize(width: 700, height: 620))
            window.center()
            settingsWindow = window
        }
        publish()
        // LSUIElement 应用从菜单栏打开窗口时，需要显式置前，否则会被其他 App 的窗口挡住
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// 把当前状态写进设置窗口的模型
    private func publish() {
        // SidecarCore 每次调用 devices/connectedDevices 可能返回新对象实例，不能用引用比较，用 identifier 匹配
        let connectedIDs = Set(Sidecar.connected().map { Sidecar.identifier($0) })
        model.sidecarDevices = Sidecar.devices().map {
            .init(id: Sidecar.identifier($0), name: Sidecar.name($0), connected: connectedIDs.contains(Sidecar.identifier($0)))
        }
        model.autoConnect = autoEnabled
        model.uuConnected = uu.connected
        model.remoteActive = gate.active
        model.activeSize = activeSize
        model.busy = busy || (remoteApplied && !gate.active)
        model.screenSize = screenSize
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
            } else {
                gate.enter()
            }
            tickRemote()
            refreshIcon()
            publish()
        }
        model.setScreenSize = { [weak self] size in
            guard let self else { return }
            screenSize = size
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

/// 菜单里的开关行：图标、标题（可带副标题）和右侧的滑动开关，样式参照控制中心
private final class SwitchRow: NSView {
    init(title: String, detail: String?, symbol: String, on: Bool, enabled: Bool, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: detail == nil ? 28 : 40))
        autoresizingMask = .width // 跟随菜单宽度

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = enabled ? .labelColor : .disabledControlTextColor
        let name = NSTextField(labelWithString: title)
        name.font = .menuFont(ofSize: 0)
        name.textColor = enabled ? .labelColor : .disabledControlTextColor
        let texts = NSStackView(views: [name])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        if let detail {
            let sub = NSTextField(labelWithString: detail)
            sub.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            sub.textColor = .secondaryLabelColor
            texts.addArrangedSubview(sub)
        }
        let toggle = NSSwitch()
        toggle.controlSize = .mini
        toggle.state = on ? .on : .off
        toggle.isEnabled = enabled
        toggle.target = target
        toggle.action = action

        let row = NSStackView(views: [icon, texts, NSView(), toggle])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
        ])
        frame.size.width = max(frame.width, fittingSize.width) // 副标题较长时撑宽菜单，不截断
    }

    required init?(coder: NSCoder) { fatalError() }
}
