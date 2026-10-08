import Foundation

/// 判断 UU 远程有没有被控会话：被控端的串流日志 streamer_log_controlled.slog 只在会话期间持续写入
/// （实测每 3～8 秒一次，空闲时不动），内容加密，只看修改时间。
/// 连入的设备取自明文日志里 device_info_changed 推送的 participants_info（设备 ID、名称、平台）。
/// UU 4.42 起明文日志改为加密格式，此后无法识别连入的是哪台设备。
final class UUWatcher {
    private(set) var connected = false
    private var participants: [String: [String: String]] = [:] // 被控设备 ID → [连入设备 ID: 名称]
    /// 当前连入的设备（不含 Mac），设备 ID → 名称
    var controllers: [String: String] { participants.values.reduce(into: [:]) { $0.merge($1) { a, _ in a } } }
    /// 日志里见过的所有连入设备：设备 ID → 名称、平台（1 Windows，3 iOS/iPadOS，4 macOS，按日志推断）
    private(set) var known: [String: (name: String, platform: Int)] = [:]
    var onPoll: (() -> Void)?
    private let dir: URL
    private let streamerLog: URL
    private var file: URL?
    private var offset: UInt64 = 0
    private var timer: Timer?

    init(dir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.netease.uuremote/Logs"),
         streamerLog: URL = URL(fileURLWithPath: "/Users/Shared/UURemote/\(getuid())/com.netease.uuremote.server/Logs/Streamer/streamer_log_controlled.slog")) {
        self.dir = dir
        self.streamerLog = streamerLog
    }

    /// 串流日志 15 秒内写过就算会话中
    static func sessionActive(modified: Date?, now: Date) -> Bool {
        guard let modified else { return false }
        return now.timeIntervalSince(modified) < 15
    }

    /// 解析 device_info_changed 推送，返回被控设备 ID 和连入设备（排除平台 4，即 macOS）
    static func participants<S: StringProtocol>(fromLine line: S) -> (host: String, controllers: [String: String], platforms: [String: Int])? {
        guard line.contains("device_info_changed"), let start = line.range(of: "{\"data\"") else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: Data(String(line[start.lowerBound...]).utf8)) as? [String: Any],
              let data = json["data"] as? [String: Any], let host = data["device_id"] as? String,
              let list = data["participants_info"] as? [[String: Any]] else { return nil }
        var controllers: [String: String] = [:]
        var platforms: [String: Int] = [:]
        for item in list where (item["platform"] as? Int) != 4 {
            guard let id = item["device_id"] as? String else { continue }
            controllers[id] = item["alias"] as? String ?? id
            platforms[id] = item["platform"] as? Int ?? 0
        }
        return (host, controllers, platforms)
    }

    func start(interval: TimeInterval = 2) {
        // 从全部日志里收集见过的设备名称和平台，用于显示已记住的设备
        for url in logFiles() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("participants_info\":[{") {
                if let push = Self.participants(fromLine: line) { remember(push) }
            }
        }
        file = logFiles().last
        offset = (try? FileManager.default.attributesOfItem(atPath: file?.path ?? "")[.size] as? UInt64) ?? 0 // 只跟踪之后的推送
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        if let newest = logFiles().last, newest != file { file = newest; offset = 0 } // 日志按天换新文件
        if let file { offset = read(file, from: offset) }
        let modified = (try? FileManager.default.attributesOfItem(atPath: streamerLog.path))?[.modificationDate] as? Date
        connected = Self.sessionActive(modified: modified, now: Date())
        // 断开时清掉连入设备：device_info_changed 只在会话期间推送，被控离线后旧记录会残留
        if !connected { participants = [:] }
        onPoll?()
    }

    private func remember(_ push: (host: String, controllers: [String: String], platforms: [String: Int])) {
        for (id, name) in push.controllers { known[id] = (name, push.platforms[id] ?? 0) }
    }

    /// 文件名带日期时间，按名字排序就是按时间排序
    private func logFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("UURemoteMac_") && $0.hasSuffix(".log") }.sorted().map { dir.appendingPathComponent($0) }
    }

    /// 读 offset 之后的完整行，更新连入设备，返回下次的起点；没写完的末行留到下次
    private func read(_ url: URL, from offset: UInt64) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return offset }
        let text = String(decoding: data[..<lastNewline], as: UTF8.self)
        for line in text.split(separator: "\n") where line.contains("device_info_changed") {
            if let push = Self.participants(fromLine: line) {
                participants[push.host] = push.controllers
                remember(push)
            }
        }
        return offset + UInt64(lastNewline - data.startIndex + 1)
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
