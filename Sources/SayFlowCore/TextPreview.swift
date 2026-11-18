import Foundation

/// 列表、浮窗里显示的一行文字：过滤隐形字符、合并空白，过长截断
public enum TextPreview {
    public static func line(_ text: String, maxLength: Int = 60) -> String {
        let single = TextSanitizer.sanitize(text, singleLine: true).trimmingCharacters(in: .whitespaces)
        guard single.count > maxLength else { return single }
        return String(single.prefix(maxLength)) + "…"
    }
}
