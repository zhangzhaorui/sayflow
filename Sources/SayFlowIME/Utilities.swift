import Foundation

/// 在主线程执行（从网络回调、系统回调里回到主线程用）
func onMain(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { work() }
    }
}

/// 延迟一段时间后在主线程执行
@MainActor
func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) {
        MainActor.assumeIsolated { work() }
    }
}

/// App 自己的临时目录（沙盒里在 App 容器内，权限 700），启动时清空；录音文件用完立即删除
enum TempFiles {
    static let folderName = "com.sayflow.inputmethod.SayFlow"

    static func directory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    static func newRecordingURL() throws -> URL {
        return try directory().appendingPathComponent("rec-" + UUID().uuidString + ".wav")
    }

    static func cleanAll() {
        guard let dir = try? directory(),
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items { try? FileManager.default.removeItem(at: item) }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func size(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}

/// App 自己的数据目录（沙盒容器内的 Application Support/SayFlow）
enum DataFiles {
    static func directory(_ name: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("SayFlow", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }
}

extension DataFiles {
    /// Rime 的用户目录。路径里不能有空格（Rime 遇到带空格的用户目录会查不到词），
    /// 所以不用「Application Support」，放在 App 沙盒容器的 Library/SayFlowRime 下。
    static func rimeUserDirectory() -> URL? {
        let dir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("SayFlowRime", isDirectory: true)
        guard !dir.path.contains(" ") else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }
}
