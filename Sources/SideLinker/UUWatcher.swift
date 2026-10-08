import Foundation

/// 判断 UU 远程有没有被控会话：被控端的串流日志 streamer_log_controlled.slog 只在会话期间持续写入
/// （实测每 3～8 秒一次，空闲时不动），内容加密，只看修改时间。
/// UU 4.42 起日志全部加密，无法识别连入的是哪台设备。
final class UUWatcher {
    private(set) var connected = false
    var onPoll: (() -> Void)?
    private let streamerLog: URL
    private var timer: Timer?

    init(streamerLog: URL = URL(fileURLWithPath: "/Users/Shared/UURemote/\(getuid())/com.netease.uuremote.server/Logs/Streamer/streamer_log_controlled.slog")) {
        self.streamerLog = streamerLog
    }

    /// 串流日志 15 秒内写过就算会话中
    static func sessionActive(modified: Date?, now: Date) -> Bool {
        guard let modified else { return false }
        return now.timeIntervalSince(modified) < 15
    }

    func start(interval: TimeInterval = 2) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: streamerLog.path))?[.modificationDate] as? Date
        connected = Self.sessionActive(modified: modified, now: Date())
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
