import CoreGraphics
import Foundation
import CGPrivate

/// 本 App 创建的虚拟屏：对象存活期间显示器存在，释放即消失
final class VirtualScreen {
    private static let callbackQueue = DispatchQueue(label: "sidelinker.virtual-display")
    private let display: CGVirtualDisplay
    var id: CGDirectDisplayID { display.displayID }

    init?(name: String, width: UInt32, height: UInt32, ppi: Double, productID: UInt32) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(Self.callbackQueue)
        descriptor.name = name
        descriptor.maxPixelsWide = width
        descriptor.maxPixelsHigh = height
        descriptor.sizeInMillimeters = CGSize(width: Double(width) / ppi * 25.4, height: Double(height) / ppi * 25.4)
        descriptor.vendorID = 0x5344
        descriptor.productID = productID
        descriptor.serialNum = 1
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        // 同时给出原始像素和一半尺寸，系统才会提供「像素不变、界面放大一倍」的 HiDPI 模式
        settings.modes = [CGVirtualDisplayMode(width: width, height: height, refreshRate: 60),
                          CGVirtualDisplayMode(width: width / 2, height: height / 2, refreshRate: 60)]
        guard display.apply(settings) else { return nil }
        self.display = display
    }
}

enum Session {
    /// 锁屏时 macOS 拒绝修改显示器配置（CGCompleteDisplayConfiguration 返回 1014）
    static var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// 立即锁屏（私有接口 login.framework）
    static func lock() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return }
        _ = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)()
    }
}

/// 显示器配置。enterSingleScreen、restore、mirror 会轮询等待配置生效，只能在后台队列调用
enum Displays {
    private static let savedKey = "savedLayout" // [[displayID, x, y]]，非空表示有显示器被本 App 关闭

    static var hasSavedLayout: Bool { UserDefaults.standard.array(forKey: savedKey) != nil }
    static func online() -> [CGDirectDisplayID] { list(CGGetOnlineDisplayList) }
    static func active() -> [CGDirectDisplayID] { list(CGGetActiveDisplayList) }

    /// 各显示器当前分辨率模式的 ID
    static func modeIDs(of ids: [CGDirectDisplayID]) -> [CGDirectDisplayID: Int32] {
        var result: [CGDirectDisplayID: Int32] = [:]
        for id in ids { result[id] = CGDisplayCopyDisplayMode(id)?.ioDisplayModeID }
        return result
    }

    /// 远程单屏：虚拟屏切到 HiDPI 模式并设为主屏，关闭其余所有显示器；关不掉的改为镜像虚拟屏。返回是否全部关闭。
    /// modes 是连接前稳定的分辨率：UU 连入时会先改主屏分辨率，恢复时要用之前的
    static func enterSingleScreen(_ screen: VirtualScreen, modes: [CGDirectDisplayID: Int32]) -> Bool {
        wait(5) { active().contains(screen.id) }
        let others = online().filter { $0 != screen.id }
        // App 崩溃后重新进入时，物理屏还关着，保留原来记录的布局
        if !hasSavedLayout {
            let layout = others.map { id -> [Int] in
                let origin = CGDisplayBounds(id).origin
                let mode = modes[id] ?? CGDisplayCopyDisplayMode(id)?.ioDisplayModeID ?? -1
                return [Int(id), Int(origin.x), Int(origin.y), Int(mode)]
            }
            UserDefaults.standard.set(layout, forKey: savedKey)
        }

        configure { config in
            if let mode = largestHiDPIMode(of: screen.id) { CGConfigureDisplayWithDisplayMode(config, screen.id, mode, nil) }
            CGConfigureDisplayOrigin(config, screen.id, 0, 0) // 坐标 (0,0) 的显示器即主屏
        }
        // 每块单独一个事务：一块失败会让整个事务作废。关闭的显示器会从 online 列表消失，外接屏要几秒
        others.forEach { id in configure { _ = CGSConfigureDisplayEnabled($0, id, false) } }
        wait(15) { online() == [screen.id] }

        let remaining = online().filter { $0 != screen.id }
        guard !remaining.isEmpty else { return true }
        configure { config in remaining.forEach { CGConfigureDisplayMirrorOfDisplay(config, $0, screen.id) } }
        return false
    }

    /// 打开被关闭的显示器、取消镜像、恢复原排列，再释放虚拟屏。
    /// 返回 false 表示锁屏挡住了恢复：此时保留虚拟屏和记录的布局，解锁后再调用
    static func restore(releasing screen: inout VirtualScreen?) -> Bool {
        let saved = UserDefaults.standard.array(forKey: savedKey) as? [[Int]] ?? []
        let ids = saved.map { CGDirectDisplayID($0[0]) }
        if !ids.isEmpty {
            // 只打开当前不在线的：对已打开的显示器再打开会让事务失败
            ids.filter { !online().contains($0) }.forEach { id in configure { _ = CGSConfigureDisplayEnabled($0, id, true) } }
            // 外接屏重新点亮可能要 10 秒以上；亮起后再释放虚拟屏，避免出现一块显示器都没有的瞬间
            wait(20) { Set(ids).isSubset(of: online()) }
            // 一块都没回来且处于锁屏：不能释放虚拟屏。未锁屏时一块都没回来，说明显示器已被拔掉
            if !ids.contains(where: online().contains) && Session.isLocked { return false }
            let mirrored = ids.filter { CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay }
            if !mirrored.isEmpty {
                configure { config in mirrored.forEach { CGConfigureDisplayMirrorOfDisplay(config, $0, kCGNullDirectDisplay) } }
            }
        }
        if let id = screen?.id {
            screen = nil
            wait(5) { !online().contains(id) }
        }
        guard !saved.isEmpty else { return true }
        let present = saved.filter { online().contains(CGDirectDisplayID($0[0])) }
        // 分辨率和位置一起设：只设位置时，系统会把 UU 在会话中改过的分辨率重新套用回来。设完核对一次，不对再设
        for _ in 0..<2 {
            configure { config in
                for row in present {
                    let id = CGDirectDisplayID(row[0])
                    if row.count > 3, let mode = mode(of: id, withID: Int32(row[3])) {
                        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
                    }
                    CGConfigureDisplayOrigin(config, id, Int32(row[1]), Int32(row[2]))
                }
            }
            Thread.sleep(forTimeInterval: 3)
            let modesMatch = present.allSatisfy {
                $0.count <= 3 || $0[3] < 0 || CGDisplayCopyDisplayMode(CGDirectDisplayID($0[0]))?.ioDisplayModeID == Int32($0[3])
            }
            if modesMatch { break }
        }
        UserDefaults.standard.removeObject(forKey: savedKey)
        return true
    }

    /// 把 display 设为 master 的镜像；master 传 kCGNullDirectDisplay 取消镜像
    static func mirror(_ display: CGDirectDisplayID, of master: CGDirectDisplayID) {
        configure { CGConfigureDisplayMirrorOfDisplay($0, display, master) }
    }

    private static func largestHiDPIMode(of id: CGDirectDisplayID) -> CGDisplayMode? {
        allModes(of: id).filter { $0.pixelWidth == $0.width * 2 }.max { $0.pixelWidth < $1.pixelWidth }
    }

    private static func mode(of id: CGDirectDisplayID, withID modeID: Int32) -> CGDisplayMode? {
        allModes(of: id).first { $0.ioDisplayModeID == modeID }
    }

    private static func allModes(of id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
    }

    private static func configure(_ body: (CGDisplayConfigRef) -> Void) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        body(config)
        let error = CGCompleteDisplayConfiguration(config, .forSession) // 只在本次登录有效，注销或重启即还原
        if error != .success { NSLog("SideLinker: 显示配置失败 %d", error.rawValue) }
    }

    private static func list(_ get: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        _ = get(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// 显示配置是异步生效的，轮询等待
    private static func wait(_ seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date() + seconds
        while !done() && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    }
}
