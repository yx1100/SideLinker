import Foundation

/// 从 UU 远程的日志判断有没有被控会话：onPeerConnectionState 的 state 为 5 表示已连接，0 表示断开。
/// 依赖 UU 4.38 的日志格式；UU 升级后自动识别失效时，先看日志里是否还有这一行。
final class UUWatcher {
    private(set) var connected = false
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

    func start(interval: TimeInterval = 2) {
        // 启动时从新到旧找最后一条状态
        let files = logFiles()
        file = files.last
        for url in files.reversed() {
            let result = read(url, from: 0)
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

    /// 读 offset 之后的完整行，返回最后一条状态和下次的起点；没写完的末行留到下次
    private func read(_ url: URL, from offset: UInt64) -> (state: Int?, end: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, offset) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return (nil, offset) }
        let text = String(decoding: data[..<lastNewline], as: UTF8.self)
        let state = text.split(separator: "\n").reversed().lazy.compactMap { Self.state(fromLine: $0) }.first
        return (state, offset + UInt64(lastNewline - data.startIndex + 1))
    }
}

/// 远程单屏的进入/退出判定：会话开始就进入；断开满 grace 秒才退出，避免掉线重连时来回切换
struct RemoteGate {
    let grace: TimeInterval
    private(set) var active = false
    private var lostAt: Date?
    private var suppressed = false // 会话中手动退出后，本次会话内不再自动进入

    /// 返回 true 表示应进入，false 表示应退出，nil 表示不变
    mutating func update(session: Bool, now: Date, autoEnter: Bool = true) -> Bool? {
        if session {
            lostAt = nil
            guard autoEnter, !active, !suppressed else { return nil }
            active = true
            return true
        }
        suppressed = false
        guard active else { return nil }
        let since = lostAt ?? now
        lostAt = since
        guard now.timeIntervalSince(since) >= grace else { return nil }
        active = false
        lostAt = nil
        return false
    }

    /// 手动进入。没有会话时同样在 grace 秒后退出，物理屏不会一直关着
    mutating func manualEnter() {
        active = true
        lostAt = nil
        suppressed = false
    }

    mutating func manualExit(session: Bool) {
        active = false
        lostAt = nil
        suppressed = session
    }
}
