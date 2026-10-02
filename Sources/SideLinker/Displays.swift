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

/// 显示器配置。会轮询等待配置生效，只能在后台队列调用
enum Displays {
    private static let savedKey = "savedLayout" // [[displayID, x, y]]，非空表示有显示器被本 App 关闭

    static var hasSavedLayout: Bool { UserDefaults.standard.array(forKey: savedKey) != nil }
    static func online() -> [CGDirectDisplayID] { list(CGGetOnlineDisplayList) }
    static func active() -> [CGDirectDisplayID] { list(CGGetActiveDisplayList) }

    /// 远程单屏：虚拟屏切到 HiDPI 模式并设为主屏，关闭其余所有显示器；关不掉的改为镜像虚拟屏。返回是否全部关闭
    static func enterSingleScreen(_ screen: VirtualScreen) -> Bool {
        wait(5) { active().contains(screen.id) }
        let others = online().filter { $0 != screen.id }
        let layout = others.map { id -> [Int] in
            let origin = CGDisplayBounds(id).origin
            return [Int(id), Int(origin.x), Int(origin.y)]
        }
        UserDefaults.standard.set(layout, forKey: savedKey)

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

    /// 打开被关闭的显示器、取消镜像、恢复原排列，再释放虚拟屏。App 异常退出后重新启动时也会调用
    static func restore(releasing screen: inout VirtualScreen?) {
        let saved = UserDefaults.standard.array(forKey: savedKey) as? [[Int]] ?? []
        let ids = saved.map { CGDirectDisplayID($0[0]) }
        if !ids.isEmpty {
            // 只打开当前不在线的：对已打开的显示器再打开会让事务失败
            ids.filter { !online().contains($0) }.forEach { id in configure { _ = CGSConfigureDisplayEnabled($0, id, true) } }
            // 外接屏重新点亮可能要 10 秒以上；亮起后再释放虚拟屏，避免出现一块显示器都没有的瞬间
            wait(20) { Set(ids).isSubset(of: online()) }
            let mirrored = ids.filter { CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay }
            if !mirrored.isEmpty {
                configure { config in mirrored.forEach { CGConfigureDisplayMirrorOfDisplay(config, $0, kCGNullDirectDisplay) } }
            }
        }
        if let id = screen?.id {
            screen = nil
            wait(5) { !online().contains(id) }
        }
        guard !saved.isEmpty else { return }
        let present = saved.filter { online().contains(CGDirectDisplayID($0[0])) }
        configure { config in
            present.forEach { CGConfigureDisplayOrigin(config, CGDirectDisplayID($0[0]), Int32($0[1]), Int32($0[2])) }
        }
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// 把 display 设为 master 的镜像；master 传 kCGNullDirectDisplay 取消镜像
    static func mirror(_ display: CGDirectDisplayID, of master: CGDirectDisplayID) {
        configure { CGConfigureDisplayMirrorOfDisplay($0, display, master) }
    }

    private static func largestHiDPIMode(of id: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        return modes.filter { $0.pixelWidth == $0.width * 2 }.max { $0.pixelWidth < $1.pixelWidth }
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
