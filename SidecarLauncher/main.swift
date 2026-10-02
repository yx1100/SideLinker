//
//  SidecarLauncher
//  (Auto-Wire Detect Version)
//  新增功能：不输入名称时，自动遍历设备，先试有线再试无线
//

import Foundation

// ---------------- 配置区域 ----------------
let MAX_RETRIES = 10        // 最大重试次数
let RETRY_INTERVAL = 3.0    // 失败休息时间 (秒)
let CONNECT_TIMEOUT = 20.0  // 单次连接超时 (秒)，无线连接常超过 5 秒
let NOTIFICATION_TITLE = "Sidecar 连接器"
// ----------------------------------------

func flushLog() { fflush(stdout) }
func log(_ msg: String) { print(msg); flushLog() }

enum Command : String {
    case Devices    = "devices"
    case Connect    = "connect"
    case Disconnect = "disconnect"
}

// 发送系统通知（文本作为参数传入，设备名里的引号不会破坏 AppleScript）
func sendNotification(message: String) {
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title (item 2 of argv)", "-e", "end run",
                      message, NOTIFICATION_TITLE]
    task.launch()
    task.waitUntilExit()
}

func printHelp() {
    print("""
    用法:
      ./SidecarLauncher devices
         列出设备。
    
      ./SidecarLauncher connect "设备名"
         【指定模式】：循环重试，优先有线，失败转无线。
    
      ./SidecarLauncher connect
         【盲连模式】：不指定名字。
         自动遍历所有设备，先全部试有线，再全部试无线。
         适合无头 Mac 开机自动连接的场景。
    """)
    flushLog()
}

// --- 初始化框架 ---
if CommandLine.arguments.count < 2 { printHelp(); exit(1) }
let cmdArg = CommandLine.arguments[1].lowercased()
guard let cmd = Command(rawValue: cmdArg) else { log("无效命令"); exit(1) }

guard let _ = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY) else {
    log("❌ 无法加载 SidecarCore"); exit(1)
}
guard let cSidecarDisplayManager = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
      let manager = cSidecarDisplayManager.perform(Selector(("sharedManager")))?.takeUnretainedValue() else {
    log("❌ 无法初始化 Manager"); exit(1)
}

// --- 核心连接函数 (底层) ---
// 直接对设备对象发起连接
func performConnection(to targetDevice: NSObject, wired: Bool) -> Bool {
    let dispatchGroup = DispatchGroup()
    var connectSuccess = false
    
    dispatchGroup.enter()
    let completion: @convention(block) (_ e: NSError?) -> Void = { e in
        if e == nil { connectSuccess = true }
        dispatchGroup.leave()
    }
    
    if wired {
        guard let cSidecarDisplayConfig = NSClassFromString("SidecarDisplayConfig") as? NSObject.Type else { return false }
        let deviceConfig = cSidecarDisplayConfig.init()
        let setTransport = unsafeBitCast(deviceConfig.method(for: Selector(("setTransport:"))), to:(@convention(c)(Any?, Selector, Int64)->Void).self)
        setTransport(deviceConfig, Selector(("setTransport:")), 2) // 2 = Wired
        
        let connect = unsafeBitCast(manager.method(for: Selector(("connectToDevice:withConfig:completion:"))), to:(@convention(c)(Any?,Selector,Any?,Any?,Any?)->Void).self)
        connect(manager, Selector(("connectToDevice:withConfig:completion:")), targetDevice, deviceConfig, completion)
    } else {
        _ = manager.perform(Selector(("connectToDevice:completion:")), with: targetDevice, with: completion)
    }
    
    // 等待结果。超时后系统可能仍在连接：以 connectedDevices 为准，并等旧请求返回，避免和下一次请求叠加
    if dispatchGroup.wait(timeout: .now() + CONNECT_TIMEOUT) == .success { return connectSuccess }
    if isConnected(targetDevice) { return true }
    _ = dispatchGroup.wait(timeout: .now() + CONNECT_TIMEOUT)
    return isConnected(targetDevice)
}

func isConnected(_ device: NSObject) -> Bool {
    let connected = manager.perform(Selector(("connectedDevices")))?.takeUnretainedValue() as? [NSObject] ?? []
    return connected.contains(device)
}

// Vision Pro 也会出现在设备列表里，盲连时跳过
func isRealityDevice(_ device: NSObject) -> Bool {
    device.responds(to: Selector(("isRealityDevice"))) && (device.value(forKey: "isRealityDevice") as? Bool ?? false)
}

// --- 业务逻辑函数 ---

// 1. 指定名称连接 (旧逻辑：有线 -> 无线)
func connectByName(targetName: String) -> Bool {
    guard let devices = manager.perform(Selector(("devices")))?.takeUnretainedValue() as? [NSObject],
          let targetDevice = devices.first(where: {
              let name = $0.perform(Selector(("name")))?.takeUnretainedValue() as? String
              return name?.lowercased() == targetName.lowercased()
          }) else {
        return false // 没找到设备
    }
    
    log("   尝试有线...")
    if performConnection(to: targetDevice, wired: true) {
        log("✅ 有线连接成功！"); sendNotification(message: "有线连接成功"); return true
    }
    
    log("   尝试无线...")
    if performConnection(to: targetDevice, wired: false) {
        log("✅ 无线连接成功！"); sendNotification(message: "无线连接成功"); return true
    }
    
    return false
}

// 2. 盲连模式 (遍历所有设备：先全部试有线，再全部试无线)
func connectAuto() -> Bool {
    guard let devices = (manager.perform(Selector(("devices")))?.takeUnretainedValue() as? [NSObject])?.filter({ !isRealityDevice($0) }),
          !devices.isEmpty else {
        return false // 列表为空
    }

    log("   🔍 扫描到 \(devices.count) 个设备...")

    for wired in [true, false] {
        for device in devices {
            let name = device.perform(Selector(("name")))?.takeUnretainedValue() as? String ?? "Unknown"
            if performConnection(to: device, wired: wired) {
                log("✅ 成功连接到: [\(name)] (\(wired ? "有线" : "无线"))")
                sendNotification(message: "已连接: \(name)")
                return true
            }
        }
    }
    return false
}

// --- 主循环 ---

if cmd == .Connect {
    // 判断是否有参数：有参数=指定模式，无参数=盲连模式
    let targetName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
    
    if let name = targetName {
        log("🚀 启动 [指定连接] 模式: \(name)")
    } else {
        log("🚀 启动 [自动盲连] 模式: 寻找任意可连接设备...")
    }
    
    for i in 1...MAX_RETRIES {
        print("----------------------------------------")
        log("🔄 第 \(i)/\(MAX_RETRIES) 次尝试...")
        
        let success = (targetName != nil) ? connectByName(targetName: targetName!) : connectAuto()
        
        if success { exit(0) }
        
        log("❌ 尝试失败，等待 \(RETRY_INTERVAL) 秒...")
        if i < MAX_RETRIES { Thread.sleep(forTimeInterval: RETRY_INTERVAL) }
    }
    
    log("⚠️ 超时放弃")
    sendNotification(message: "连接超时 (未发现设备)")
    exit(1)
}

// 其他命令保持不变
if cmd == .Devices {
    if let devices = manager.perform(Selector(("devices")))?.takeUnretainedValue() as? [NSObject] {
        print("发现 \(devices.count) 个设备:")
        for d in devices {
            let name = d.perform(Selector(("name")))?.takeUnretainedValue() as? String ?? "Unknown"
            print(" - [\(name)]")
        }
    }
    exit(0)
}

if cmd == .Disconnect {
    if CommandLine.arguments.count < 3 { log("需指定设备名"); exit(1) }
    let targetName = CommandLine.arguments[2]
    guard let devices = manager.perform(Selector(("devices")))?.takeUnretainedValue() as? [NSObject],
          let target = devices.first(where: { ($0.perform(Selector(("name")))?.takeUnretainedValue() as? String)?.lowercased() == targetName.lowercased() })
    else { log("未找到设备"); exit(1) }
    
    let group = DispatchGroup()
    group.enter()
    // 回调必须是 ObjC block，普通 Swift 闭包传进去会在框架回调时崩溃
    let completion: @convention(block) (_ e: NSError?) -> Void = { _ in group.leave() }
    _ = manager.perform(Selector(("disconnectFromDevice:completion:")), with: target, with: completion)
    if group.wait(timeout: .now() + CONNECT_TIMEOUT) == .timedOut { log("⚠️ 断开超时"); exit(1) }
    log("✅ 已断开")
    exit(0)
}