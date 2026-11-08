import Foundation

/// 全局文件日志。
/// 正式运行的 App 里 `NSLog` 很难从 `log show` 抓出来，
/// 而「按了没反应」这类问题必须能看到链路，否则只能靠猜。
enum Diag {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/better-macOS.log")
    }

    static func log(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}
