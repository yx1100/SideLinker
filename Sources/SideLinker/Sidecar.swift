import Foundation

/// SidecarCore 私有框架的封装。connect/disconnect 会阻塞等待结果，App 里要放在后台队列调用。
enum Sidecar {
    private static let manager: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY) != nil,
              let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else { return nil }
        return cls.perform(Selector(("sharedManager")))?.takeUnretainedValue() as? NSObject
    }()

    /// 可连接的设备，排除同样出现在列表里的 Vision Pro
    static func devices() -> [NSObject] { list("devices").filter { !isRealityDevice($0) } }
    static func connected() -> [NSObject] { list("connectedDevices") }
    static func name(_ device: NSObject) -> String { device.value(forKey: "name") as? String ?? "未知设备" }
    static func identifier(_ device: NSObject) -> String { device.value(forKey: "identifier").map { "\($0)" } ?? name(device) }

    /// 先对全部设备试有线，再全部试无线，返回连上的设备
    static func connectFirst(of devices: [NSObject], log: (String) -> Void = { _ in }) -> NSObject? {
        for wired in [true, false] {
            for device in devices {
                log("尝试\(wired ? "有线" : "无线")连接 \(name(device))…")
                if connect(device, wired: wired) { return device }
            }
        }
        return nil
    }

    static func connect(_ device: NSObject, wired: Bool, timeout: TimeInterval = 20) -> Bool {
        guard let manager else { return false }
        let group = DispatchGroup()
        var succeeded = false
        group.enter()
        let completion: @convention(block) (NSError?) -> Void = { error in
            succeeded = error == nil
            group.leave()
        }
        let block = unsafeBitCast(completion, to: AnyObject.self)
        if wired {
            guard let configClass = NSClassFromString("SidecarDisplayConfig") as? NSObject.Type else { return false }
            let config = configClass.init()
            let setTransport = unsafeBitCast(config.method(for: Selector(("setTransport:"))),
                                             to: (@convention(c) (NSObject, Selector, Int64) -> Void).self)
            setTransport(config, Selector(("setTransport:")), 2) // 2 = 有线
            let sel = Selector(("connectToDevice:withConfig:completion:"))
            let connect = unsafeBitCast(manager.method(for: sel),
                                        to: (@convention(c) (NSObject, Selector, NSObject, NSObject, AnyObject) -> Void).self)
            connect(manager, sel, device, config, block)
        } else {
            let sel = Selector(("connectToDevice:completion:"))
            let connect = unsafeBitCast(manager.method(for: sel),
                                        to: (@convention(c) (NSObject, Selector, NSObject, AnyObject) -> Void).self)
            connect(manager, sel, device, block)
        }
        if group.wait(timeout: .now() + timeout) == .success { return succeeded }
        // 超时后系统可能仍在连接：以 connectedDevices 为准，并等旧请求返回，避免和下一次请求叠加
        if connected().contains(device) { return true }
        _ = group.wait(timeout: .now() + timeout)
        return connected().contains(device)
    }

    static func disconnect(_ device: NSObject, timeout: TimeInterval = 10) -> Bool {
        guard let manager else { return false }
        let group = DispatchGroup()
        group.enter()
        let completion: @convention(block) (NSError?) -> Void = { _ in group.leave() }
        let sel = Selector(("disconnectFromDevice:completion:"))
        let disconnect = unsafeBitCast(manager.method(for: sel),
                                       to: (@convention(c) (NSObject, Selector, NSObject, AnyObject) -> Void).self)
        disconnect(manager, sel, device, unsafeBitCast(completion, to: AnyObject.self))
        return group.wait(timeout: .now() + timeout) == .success
    }

    private static func list(_ selector: String) -> [NSObject] {
        manager?.perform(Selector((selector)))?.takeUnretainedValue() as? [NSObject] ?? []
    }

    private static func isRealityDevice(_ device: NSObject) -> Bool {
        device.responds(to: Selector(("isRealityDevice"))) && (device.value(forKey: "isRealityDevice") as? Bool ?? false)
    }
}
