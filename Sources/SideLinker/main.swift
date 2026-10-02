import AppKit

// 带命令时作为命令行工具运行（调试、排查用），否则启动菜单栏 App
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "devices":
    let connected = Sidecar.connected()
    let devices = Sidecar.devices()
    print("发现 \(devices.count) 个设备")
    devices.forEach { print(" - \(Sidecar.name($0))\(connected.contains($0) ? "（已连接）" : "")") }
    exit(0)
case "connect":
    let name = arguments.dropFirst().first?.lowercased()
    let targets = Sidecar.devices().filter { name == nil || Sidecar.name($0).lowercased() == name }
    guard !targets.isEmpty else { print("未找到设备"); exit(1) }
    if let device = Sidecar.connectFirst(of: targets, log: { print($0) }) {
        print("✅ 已连接 \(Sidecar.name(device))")
        exit(0)
    }
    print("❌ 连接失败")
    exit(1)
case "disconnect":
    let name = arguments.dropFirst().first?.lowercased()
    let targets = Sidecar.connected().filter { name == nil || Sidecar.name($0).lowercased() == name }
    guard !targets.isEmpty else { print("没有已连接的设备"); exit(1) }
    let ok = targets.allSatisfy { Sidecar.disconnect($0) }
    print(ok ? "✅ 已断开" : "⚠️ 断开超时")
    exit(ok ? 0 : 1)
case "selftest":
    exit(selftest())
default:
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}

/// 日志解析、远程单屏判定、日志轮转的自检
func selftest() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("✗ \(what)") }
    }
    let line = { (state: Int) in "[t] XPC Server: {\"onPeerConnectionState\":{\"_0\":{\"handle\":1,\"state\":\(state)}}}\n" }

    check(UUWatcher.state(fromLine: line(5)) == 5, "解析已连接")
    check(UUWatcher.state(fromLine: #"{"onPeerConnectionState":{"_0":{"state":0,"handle":1}}}"#) == 0, "键顺序不同也能解析")
    check(UUWatcher.state(fromLine: #"{"onRoomState":{"_0":{"handle":1,"state":1,"error_code":9000}}}"#) == nil, "忽略 onRoomState")
    check(UUWatcher.state(fromLine: #"{"heartbeat":{"timestamp":1}}"#) == nil, "忽略心跳")

    let t = Date()
    var gate = RemoteGate(grace: 60)
    check(gate.update(session: true, now: t) == true, "会话开始即进入")
    check(gate.update(session: false, now: t + 1) == nil, "刚断开不退出")
    check(gate.update(session: true, now: t + 30) == nil, "宽限期内重连保持")
    check(gate.update(session: false, now: t + 40) == nil, "再次断开重新计时")
    check(gate.update(session: false, now: t + 99) == nil, "未满 60 秒不退出")
    check(gate.update(session: false, now: t + 100) == false, "断开满 60 秒退出")
    gate.manualEnter()
    check(gate.update(session: false, now: t + 200) == nil, "手动进入后开始计时")
    check(gate.update(session: false, now: t + 260) == false, "没有会话时手动进入，60 秒后退出")
    check(gate.update(session: true, now: t + 300) == true, "新会话进入")
    gate.manualExit(session: true)
    check(gate.update(session: true, now: t + 301) == nil, "会话中手动退出后不再自动进入")
    check(gate.update(session: false, now: t + 302) == nil, "会话结束")
    check(gate.update(session: true, now: t + 303) == true, "下一次会话恢复自动进入")
    var manualOnly = RemoteGate(grace: 60)
    check(manualOnly.update(session: true, now: t, autoEnter: false) == nil, "关闭自动处理时不进入")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidelinker-selftest-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func append(_ name: String, _ text: String) {
        let url = dir.appendingPathComponent(name)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
    let first = "UURemoteMac_2026-01-01_00:00:00.log"
    append(first, line(5) + "[t] XPC Server: {\"heartbeat\":{}}\n")
    let watcher = UUWatcher(dir: dir)
    watcher.start(interval: 3600)
    check(watcher.connected, "启动时读到已连接")
    append(first, String(line(0).dropLast()))
    watcher.poll()
    check(watcher.connected, "没写完的行先不处理")
    append(first, "\n")
    watcher.poll()
    check(!watcher.connected, "行写完后读到断开")
    append("UURemoteMac_2026-01-02_00:00:00.log", line(5))
    watcher.poll()
    check(watcher.connected, "切换到新的日志文件")

    print(failures == 0 ? "selftest 全部通过" : "selftest 失败 \(failures) 项")
    return failures == 0 ? 0 : 1
}
