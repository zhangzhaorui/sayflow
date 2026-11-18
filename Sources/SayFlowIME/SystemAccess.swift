import AppKit
import AVFoundation
import Carbon
import Security
import SayFlowCore

enum PermissionState {
    case granted, denied, notDetermined
}

/// 输入法只会用到麦克风这一项权限（只在打开语音输入后）。
/// 不需要也不申请「辅助功能」「输入监控」：按键由系统交给输入法，文字通过输入法接口写入。
@MainActor
enum Permissions {
    static func microphone() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func requestMicrophone(_ done: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            onMain { done(granted) }
        }
    }

    /// 打开「系统设置 → 隐私与安全性 → 麦克风」
    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 焦点在密码框等安全输入时为 true
    static var isSecureInputActive: Bool {
        return IsSecureEventInputEnabled()
    }
}

/// 令牌由程序自己写进钥匙串（不用 security 命令）
enum KeychainStore {
    static let service = "com.sayflow.inputmethod.SayFlow"
    static let account = "gateway-token"

    private static func baseQuery() -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    static var hasKey: Bool { read() != nil }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        var query = baseQuery()
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrLabel as String] = "SayFlow 输入法网关令牌"
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
