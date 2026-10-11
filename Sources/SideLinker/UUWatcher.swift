import AppKit

/// 判断 UU 远程有没有被控会话，两个信号：
/// - 覆盖窗口：UURemoteServer 被控期间在每块屏幕上铺一层透明窗口，断开后立即消失。不需要权限，作为主信号
/// - 串流日志：streamer_log_controlled.slog 只在会话期间持续写入（实测每 3～8 秒一次），内容加密，只看修改时间。
///   断开后还要 15 秒才判断得出，只在覆盖窗口失效时备用
final class UUWatcher {
    private(set) var connected = false
    private(set) var detectable = false // UURemoteServer 没在运行，串流日志也不存在：UU 未安装或已退出
    var onPoll: (() -> Void)?
    private let streamerLog: URL
    private let overlayPresent: () -> Bool
    private let serverRunning: () -> Bool
    private var overlaySeen = Date.distantPast
    private var logOnlySince: Date? // 日志在写、覆盖窗口却不在的起始时间
    private var timer: Timer?

    init(streamerLog: URL = URL(fileURLWithPath: "/Users/Shared/UURemote/\(getuid())/com.netease.uuremote.server/Logs/Streamer/streamer_log_controlled.slog"),
         overlayPresent: @escaping () -> Bool = UUWatcher.overlayPresent,
         serverRunning: @escaping () -> Bool = UUWatcher.serverRunning) {
        self.streamerLog = streamerLog
        self.overlayPresent = overlayPresent
        self.serverRunning = serverRunning
    }

    static func overlayPresent() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { $0[kCGWindowOwnerName as String] as? String == "UURemoteServer" }
    }

    static func serverRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.executableURL?.lastPathComponent == "UURemoteServer" }
    }

    /// 串流日志 15 秒内写过就算会话中
    static func sessionActive(modified: Date?, now: Date) -> Bool {
        guard let modified else { return false }
        return now.timeIntervalSince(modified) < 15
    }

    /// 覆盖窗口 3 秒内出现过（切换显示器时它会短暂重建）就算连着；
    /// 只有日志在写时，持续 20 秒才算：断开后日志最多再「新鲜」15 秒，超过说明会话还在、覆盖窗口检测失效了
    static func connected(overlaySeen: Date, logOnlySince: Date?, now: Date) -> Bool {
        now.timeIntervalSince(overlaySeen) < 3 || logOnlySince.map { now.timeIntervalSince($0) >= 20 } ?? false
    }

    func start(interval: TimeInterval = 2) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        let now = Date()
        let overlay = overlayPresent()
        if overlay { overlaySeen = now }
        let modified = (try? FileManager.default.attributesOfItem(atPath: streamerLog.path))?[.modificationDate] as? Date
        logOnlySince = Self.sessionActive(modified: modified, now: now) && !overlay ? logOnlySince ?? now : nil
        connected = Self.connected(overlaySeen: overlaySeen, logOnlySince: logOnlySince, now: now)
        detectable = overlay || modified != nil || serverRunning()
        onPoll?()
    }
}

/// 远程单屏的自动退出判定：只能手动进入；UU 断开满 grace 秒后退出，避免掉线重连时来回切换。
/// 进入时没有 UU 会话也按断开计时，物理屏不会一直关着
struct RemoteGate {
    let grace: TimeInterval
    private(set) var active = false
    private var lostAt: Date?

    /// 返回 true 表示应退出
    mutating func update(session: Bool, now: Date) -> Bool {
        guard active else { return false }
        if session {
            lostAt = nil
            return false
        }
        let since = lostAt ?? now
        lostAt = since
        guard now.timeIntervalSince(since) >= grace else { return false }
        exit()
        return true
    }

    mutating func enter() {
        active = true
        lostAt = nil
    }

    mutating func exit() {
        active = false
        lostAt = nil
    }
}
