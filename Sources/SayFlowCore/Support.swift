import Foundation

/// 多段语音按说话顺序交付：先说的先写入，即使后说的先识别完。
/// 每段语音开始录音时 `reserve()` 拿到序号，结束时必须 `resolve` 一次（value 为 nil 表示这段不写入）。
public final class OrderedDelivery<Value> {
    private var counter = 0
    private var next = 1
    private var pending: [Int: Value?] = [:]

    public init() {}

    public func reserve() -> Int {
        counter += 1
        return counter
    }

    /// 返回现在可以按顺序交付的结果
    public func resolve(_ sequence: Int, _ value: Value?) -> [Value] {
        pending[sequence] = .some(value)
        var ready: [Value] = []
        while let entry = pending[next] {
            pending[next] = nil
            next += 1
            if let value = entry { ready.append(value) }
        }
        return ready
    }
}

/// 专有名词：用户在设置里用逗号、顿号或换行分隔输入
public enum DictionaryParser {
    public static let maxItems = 50
    public static let maxItemLength = 40

    public static func parse(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;；\n")
        var seen = Set<String>()
        var result: [String] = []
        for part in text.components(separatedBy: separators) {
            var item = TextSanitizer.sanitize(part, singleLine: true)
            if item.unicodeScalars.count > maxItemLength {
                item = String(String.UnicodeScalarView(item.unicodeScalars.prefix(maxItemLength)))
            }
            guard !item.isEmpty, !seen.contains(item) else { continue }
            seen.insert(item)
            result.append(item)
            if result.count >= maxItems { break }
        }
        return result
    }

    public static func display(_ items: [String]) -> String {
        return items.joined(separator: ", ")
    }
}

/// 令牌格式校验：只允许字母、数字和 . _ -，长度 8–512
public enum APIKeyFormat {
    public static func isValid(_ key: String) -> Bool {
        let scalars = key.unicodeScalars
        guard scalars.count >= 8, scalars.count <= 512 else { return false }
        for s in scalars {
            switch s.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: continue   // 0-9 A-Z a-z
            case 0x2E, 0x5F, 0x2D: continue                        // . _ -
            default: return false
            }
        }
        return true
    }
}
