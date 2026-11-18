#if SAYFLOW_RIME
import AppKit
import CRime
import SayFlowCore

/// 用 librime 打字。全部在本机，不联网：
/// - 方案、词库、语言模型都在 App 包的 Resources/rime-data 里，打包时预编译好，签名后只读；
/// - 个人词频记忆（用户词典 *.userdb）在沙盒容器的 Library/SayFlowRime 里；
/// - 启动时删掉该目录里所有 yaml 和 build 缓存，不加载外来配置，也不在运行时生成配置；
/// - 编译时关闭了 Rime 的日志，不带 Lua 等脚本插件。
@MainActor
final class RimeEngine: InputEngine {
    private let api: UnsafeMutablePointer<RimeApi>
    private var session: RimeSessionId = 0
    private var ready = false
    private let sharedDir: URL
    private let userDir: URL
    private var schema: InputSchema
    private var learning: Bool

    init?(prefs: Preferences) {
        guard let api = rime_get_api(),
              let shared = Bundle.main.resourceURL?.appendingPathComponent("rime-data", isDirectory: true),
              FileManager.default.fileExists(atPath: shared.appendingPathComponent("default.yaml").path),
              let user = DataFiles.rimeUserDirectory() else { return nil }
        self.api = api
        self.sharedDir = shared
        self.userDir = user
        self.schema = prefs.schema
        self.learning = prefs.learningEnabled

        var traits = RimeTraits()
        traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
        traits.shared_data_dir = RimeEngine.cString(shared.path)
        traits.prebuilt_data_dir = RimeEngine.cString(shared.appendingPathComponent("build").path)
        traits.user_data_dir = RimeEngine.cString(user.path)
        traits.staging_dir = RimeEngine.cString(user.appendingPathComponent("build").path)
        traits.distribution_name = RimeEngine.cString("SayFlow")
        traits.distribution_code_name = RimeEngine.cString("SayFlow")
        traits.distribution_version = RimeEngine.cString(AppInfo.version)
        traits.app_name = RimeEngine.cString("rime.sayflow")
        traits.min_log_level = 4   // 只留致命错误；日志在编译时已关闭
        api.pointee.setup?(&traits)
        api.pointee.initialize?(&traits)
        deploy()
    }

    private static func cString(_ text: String) -> UnsafePointer<CChar>? {
        guard let copy = strdup(text) else { return nil }
        return UnsafePointer(copy)
    }

    // MARK: 部署

    /// 不在输入法进程里「部署」（编译方案和词库）：在本进程里编译出来的拼音索引是坏的，查不到词。
    /// 方案、词库、语言模型和所有设置都在打包时由 C 工具预先编译好（App 包里的 rime-data/build），
    /// 这里只清掉用户目录里的配置和旧缓存，然后直接使用预编译结果。个人词频（*.userdb）保留。
    private func deploy() {
        ready = false
        cleanUserDirectory()
        startSession()
    }

    private func startSession() {
        if session != 0 { _ = api.pointee.destroy_session?(session) }
        session = api.pointee.create_session?() ?? 0
        guard session != 0 else { return }
        _ = api.pointee.select_schema?(session, schemaID)
        ready = true
    }

    private func cleanUserDirectory() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil) else { return }
        for item in items where item.pathExtension == "yaml" || item.lastPathComponent == "build" {
            try? fm.removeItem(at: item)
        }
    }

    /// 实际选用的方案：关闭学习时用打包好的「_nolearn」版本
    private var schemaID: String {
        return learning ? schema.rawValue : schema.rawValue + "_nolearn"
    }

    // MARK: InputEngine

    var isReady: Bool { ready && session != 0 }

    var isAsciiMode: Bool {
        guard isReady else { return true }
        var status = RimeStatus()
        status.data_size = Int32(MemoryLayout<RimeStatus>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_status?(session, &status) != 0 else { return false }
        defer { _ = api.pointee.free_status?(&status) }
        return status.is_ascii_mode != 0
    }

    func process(keyCode: UInt16, characters: String?, modifiers: RimeKeys.Modifiers) -> EngineResult {
        guard isReady else { return EngineResult(handled: false, commit: nil, state: EngineState()) }
        // ⌘ 组合键一律交给 App
        if modifiers.contains(.command) { return EngineResult(handled: false, commit: nil, state: currentState()) }
        guard let keysym = RimeKeys.keysym(keyCode: keyCode, charactersIgnoringModifiers: characters) else {
            return EngineResult(handled: false, commit: nil, state: currentState())
        }
        var mods = modifiers
        mods.remove(.capsLock)
        let handled = api.pointee.process_key?(session, keysym, RimeKeys.mask(mods)) != 0
        return EngineResult(handled: handled, commit: takeCommit(), state: currentState())
    }

    func processModifier(keyCode: UInt16, pressed: Bool, modifiers: RimeKeys.Modifiers) -> EngineResult {
        guard isReady, let keysym = RimeKeys.modifierKeysyms[keyCode] else {
            return EngineResult(handled: false, commit: nil, state: EngineState())
        }
        let mask = RimeKeys.mask(modifiers, release: !pressed)
        let handled = api.pointee.process_key?(session, keysym, mask) != 0
        return EngineResult(handled: handled, commit: takeCommit(), state: currentState())
    }

    func select(index: Int) -> EngineResult {
        guard isReady else { return EngineResult(handled: false, commit: nil, state: EngineState()) }
        let handled = api.pointee.select_candidate_on_current_page?(session, index) != 0
        return EngineResult(handled: handled, commit: takeCommit(), state: currentState())
    }

    var snapshot: EngineState { isReady ? currentState() : EngineState() }

    func candidateList(from: Int, count: Int) -> [Candidate] {
        guard isReady, count > 0 else { return [] }
        var it = RimeCandidateListIterator()
        guard api.pointee.candidate_list_from_index?(session, &it, Int32(from)) != 0 else { return [] }
        defer { api.pointee.candidate_list_end?(&it) }
        var list: [Candidate] = []
        while list.count < count, api.pointee.candidate_list_next?(&it) != 0 {
            let text = it.candidate.text.map { String(cString: $0) } ?? ""
            let comment = it.candidate.comment.map { String(cString: $0) }
            list.append(Candidate(text: text, comment: (comment?.isEmpty ?? true) ? nil : comment))
        }
        return list
    }

    func select(globalIndex: Int) -> EngineResult {
        guard isReady else { return EngineResult(handled: false, commit: nil, state: EngineState()) }
        let handled = api.pointee.select_candidate?(session, globalIndex) != 0
        return EngineResult(handled: handled, commit: takeCommit(), state: currentState())
    }

    func commitRaw() -> String? {
        guard isReady, let input = api.pointee.get_input?(session) else { return nil }
        let text = String(cString: input)
        api.pointee.clear_composition?(session)
        return text.isEmpty ? nil : text
    }

    func clear() {
        guard isReady else { return }
        api.pointee.clear_composition?(session)
    }

    func setAsciiMode(_ ascii: Bool) {
        guard isReady else { return }
        api.pointee.set_option?(session, "ascii_mode", ascii ? 1 : 0)
    }

    func apply(schema: InputSchema, pageSize: Int, learning: Bool) {
        // 每页候选数固定为 8（打包时写死），这里不处理 pageSize
        self.schema = schema
        self.learning = learning
        if isReady {
            // 重新建立会话，保证新方案立刻生效
            startSession()
        }
    }

    func clearUserDictionary() -> Bool {
        ready = false
        if session != 0 { _ = api.pointee.destroy_session?(session) }
        session = 0
        api.pointee.finalize?()
        let fm = FileManager.default
        var ok = true
        if let items = try? fm.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasSuffix(".userdb") || item.lastPathComponent.hasSuffix(".userdb.txt") {
                do { try fm.removeItem(at: item) } catch { ok = false }
            }
        }
        var traits = RimeTraits()
        traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
        traits.shared_data_dir = RimeEngine.cString(sharedDir.path)
        traits.prebuilt_data_dir = RimeEngine.cString(sharedDir.appendingPathComponent("build").path)
        traits.user_data_dir = RimeEngine.cString(userDir.path)
        traits.staging_dir = RimeEngine.cString(userDir.appendingPathComponent("build").path)
        traits.app_name = RimeEngine.cString("rime.sayflow")
        traits.min_log_level = 4
        api.pointee.initialize?(&traits)
        deploy()
        return ok
    }

    var statusText: String {
        if !ready { return "打字引擎正在准备词库…" }
        return "Rime 打字引擎已就绪（本机运行，不联网）"
    }

    // MARK: 读取状态

    private func takeCommit() -> String? {
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_commit?(session, &commit) != 0 else { return nil }
        defer { _ = api.pointee.free_commit?(&commit) }
        guard let text = commit.text else { return nil }
        let value = String(cString: text)
        return value.isEmpty ? nil : value
    }

    private func currentState() -> EngineState {
        var state = EngineState()
        state.schemaLabel = schema.shortTitle
        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_context?(session, &context) != 0 else { return state }
        defer { _ = api.pointee.free_context?(&context) }

        if let preedit = context.composition.preedit {
            let text = String(cString: preedit)
            state.preedit = text
            // cursor_pos 是 UTF-8 字节位置，换算成 UTF-16
            let bytes = Array(text.utf8)
            let cursorBytes = min(Int(context.composition.cursor_pos), bytes.count)
            let prefix = String(decoding: bytes[0..<cursorBytes], as: UTF8.self)
            state.cursor = prefix.utf16.count
        }
        let menu = context.menu
        state.highlighted = Int(menu.highlighted_candidate_index)
        state.pageNumber = Int(menu.page_no)
        state.pageStart = Int(menu.page_no) * Int(menu.page_size)
        state.isLastPage = menu.is_last_page != 0
        if let list = menu.candidates {
            for i in 0..<Int(menu.num_candidates) {
                let item = list[i]
                let text = item.text.map { String(cString: $0) } ?? ""
                let comment = item.comment.map { String(cString: $0) }
                state.candidates.append(Candidate(text: text, comment: (comment?.isEmpty ?? true) ? nil : comment))
            }
        }
        if let keys = menu.select_keys {
            state.selectLabels = String(cString: keys).map { String($0) }
        } else {
            state.selectLabels = (1...max(1, state.candidates.count)).map { String($0 % 10) }
        }
        return state
    }
}
#endif
