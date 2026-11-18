import AppKit
import InputMethodKit
import SayFlowCore

typealias TextClient = IMKTextInput & NSObjectProtocol

/// 要写入文字的输入框。文字一律通过输入法接口写入，不经过剪贴板、不模拟按键。
@MainActor
final class TextTarget {
    let client: TextClient
    let bundleID: String?
    let appName: String?

    init(client: TextClient) {
        self.client = client
        // 只取当前 App 的 bundle ID 和名字（用来选整理风格、判断终端），不读取输入框内容
        let id = client.bundleIdentifier()
        self.bundleID = id
        if let id, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            self.appName = app.localizedName
        } else {
            self.appName = id
        }
    }

    var isTerminal: Bool { AppProfiles.isTerminal(bundleID) }

    /// 过滤控制字符和隐形字符后写入；终端去掉换行和 Tab；密码框不写入
    @discardableResult
    func insert(_ text: String, replacing range: NSRange? = nil) -> Bool {
        guard !Permissions.isSecureInputActive else { return false }
        let clean = TextSanitizer.sanitize(text, singleLine: isTerminal)
        guard !clean.isEmpty else { return false }
        client.insertText(clean, replacementRange: range ?? NSRange(location: NSNotFound, length: NSNotFound))
        return true
    }

    /// 光标位置（屏幕坐标），用来放候选窗和浮窗
    var caretRect: NSRect {
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        if rect.width == 0 && rect.height == 0 {
            let mouse = NSEvent.mouseLocation
            return NSRect(x: mouse.x, y: mouse.y - 20, width: 1, height: 20)
        }
        return rect
    }

    /// 改写用：只读取选中的那一段文字，不读输入框里的其他内容
    func selectedText(maxLength: Int) -> SelectionResult {
        let range = client.selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return .none }
        guard range.length <= maxLength else { return .tooLong }
        guard let text = client.attributedSubstring(from: range)?.string, !text.isEmpty else { return .unsupported }
        return .text(text, range)
    }

    enum SelectionResult {
        case none
        case tooLong
        case unsupported
        case text(String, NSRange)
    }
}
