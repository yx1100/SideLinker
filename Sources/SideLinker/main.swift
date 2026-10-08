import AppKit

// 带命令时作为命令行工具运行（调试、排查用），否则启动菜单栏 App
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "devices":
    let connectedIDs = Set(Sidecar.connected().map { Sidecar.identifier($0) })
    let devices = Sidecar.devices()
    print("发现 \(devices.count) 个设备")
    devices.forEach { print(" - \(Sidecar.name($0))\(connectedIDs.contains(Sidecar.identifier($0)) ? "（已连接）" : "")") }
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

/// 会话判定、日志解析、远程单屏判定的自检
func selftest() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("✗ \(what)") }
    }
    let t0 = Date()
    check(UUWatcher.sessionActive(modified: t0 - 5, now: t0), "串流日志刚写过，会话中")
    check(!UUWatcher.sessionActive(modified: t0 - 20, now: t0), "串流日志 20 秒没写，已断开")
    check(!UUWatcher.sessionActive(modified: nil, now: t0), "没有串流日志，已断开")
    let push = #"[t] 被控-收到推送数据-{"data":{"device_id":"mac1","participants_info":[{"alias":"iPad","device_id":"pad1","platform":3},{"alias":"MacBook","device_id":"mac2","platform":4}],"platform":4},"type":"device_info_changed"}"#
    let parsed = UUWatcher.participants(fromLine: push)
    check(parsed?.host == "mac1" && parsed?.controllers == ["pad1": "iPad"], "解析连入设备并排除 Mac")
    check(UUWatcher.participants(fromLine: #"{"data":{"device_id":"mac1","participants_info":[]},"type":"device_info_changed"}"#)?.controllers.isEmpty == true, "断开后连入设备为空")

    let t = Date()
    var gate = RemoteGate(grace: 30)
    check(!gate.update(session: true, now: t) && !gate.active, "UU 连入不会自动进入")
    gate.enter()
    check(!gate.update(session: true, now: t + 1), "会话中保持")
    check(!gate.update(session: false, now: t + 2), "刚断开不退出")
    check(!gate.update(session: true, now: t + 24), "宽限期内重连保持")
    check(!gate.update(session: false, now: t + 40), "再次断开重新计时")
    check(!gate.update(session: false, now: t + 69), "未满 30 秒不退出")
    check(gate.update(session: false, now: t + 70) && !gate.active, "断开满 30 秒退出")
    gate.enter()
    check(!gate.update(session: false, now: t + 200), "没有会话时进入，开始计时")
    check(gate.update(session: false, now: t + 230), "没有会话时进入，30 秒后退出")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidelinker-selftest-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let slog = dir.appendingPathComponent("streamer_log_controlled.slog")
    let watcher = UUWatcher(dir: dir, streamerLog: slog)
    watcher.start(interval: 3600)
    watcher.poll()
    check(!watcher.connected, "启动时没有串流日志")
    try? Data([1]).write(to: slog)
    watcher.poll()
    check(watcher.connected, "串流日志写入后识别为已连接")
    try? FileManager.default.setAttributes([.modificationDate: Date() - 60], ofItemAtPath: slog.path)
    watcher.poll()
    check(!watcher.connected, "串流日志停写后识别为断开")

    print(failures == 0 ? "selftest 全部通过" : "selftest 失败 \(failures) 项")
    return failures == 0 ? 0 : 1
}
