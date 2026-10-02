import Foundation

/// 从 UU 远程的日志判断有没有被控会话：onPeerConnectionState 的 state 为 5 表示已连接，0 表示断开。
/// 连入的设备取自 device_info_changed 推送里的 participants_info（设备 ID、名称、平台）。
/// 依赖 UU 4.38 的日志格式；UU 升级后自动识别失效时，先看日志里是否还有这些字段。
final class UUWatcher {
    private(set) var connected = false
    private var participants: [String: [String: String]] = [:] // 被控设备 ID → [连入设备 ID: 名称]
    /// 当前连入的设备（不含 Mac），设备 ID → 名称
    var controllers: [String: String] { participants.values.reduce(into: [:]) { $0.merge($1) { a, _ in a } } }
    var onPoll: (() -> Void)?
    private let dir: URL
    private var file: URL?
    private var offset: UInt64 = 0
    private var timer: Timer?

    init(dir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.netease.uuremote/Logs")) {
        self.dir = dir
    }

    static func state<S: StringProtocol>(fromLine line: S) -> Int? {
        guard line.contains("\"onPeerConnectionState\""), let key = line.range(of: "\"state\":") else { return nil }
        return Int(String(line[key.upperBound...].prefix(while: \.isNumber)))
    }

    /// 解析 device_info_changed 推送，返回被控设备 ID 和连入设备（排除平台 4，即 macOS）
    static func participants<S: StringProtocol>(fromLine line: S) -> (host: String, controllers: [String: String])? {
        guard line.contains("device_info_changed"), let start = line.range(of: "{\"data\"") else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: Data(String(line[start.lowerBound...]).utf8)) as? [String: Any],
              let data = json["data"] as? [String: Any], let host = data["device_id"] as? String,
              let list = data["participants_info"] as? [[String: Any]] else { return nil }
        var controllers: [String: String] = [:]
        for item in list where (item["platform"] as? Int) != 4 {
            if let id = item["device_id"] as? String { controllers[id] = item["alias"] as? String ?? id }
        }
        return (host, controllers)
    }

    func start(interval: TimeInterval = 2) {
        // 启动时从新到旧找最后一条状态
        let files = logFiles()
        file = files.last
        for url in files.reversed() {
            let result = read(url, from: 0, trackParticipants: url == file) // 旧文件里的连入设备已过时
            if url == file { offset = result.end }
            if let state = result.state { connected = state == 5; break }
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        if let newest = logFiles().last, newest != file { file = newest; offset = 0 } // 日志按天换新文件
        if let file {
            let result = read(file, from: offset)
            offset = result.end
            if let state = result.state { connected = state == 5 }
        }
        onPoll?()
    }

    /// 文件名带日期时间，按名字排序就是按时间排序
    private func logFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("UURemoteMac_") && $0.hasSuffix(".log") }.sorted().map { dir.appendingPathComponent($0) }
    }

    /// 读 offset 之后的完整行，更新连入设备，返回最后一条状态和下次的起点；没写完的末行留到下次
    private func read(_ url: URL, from offset: UInt64, trackParticipants: Bool = true) -> (state: Int?, end: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, offset) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return (nil, offset) }
        let text = String(decoding: data[..<lastNewline], as: UTF8.self)
        let lines = text.split(separator: "\n")
        for line in lines where trackParticipants && line.contains("device_info_changed") {
            if let push = Self.participants(fromLine: line) { participants[push.host] = push.controllers }
        }
        let state = lines.reversed().lazy.compactMap { Self.state(fromLine: $0) }.first
        return (state, offset + UInt64(lastNewline - data.startIndex + 1))
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
