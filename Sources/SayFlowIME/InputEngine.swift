import AppKit
import SayFlowCore

/// 候选词
struct Candidate {
    let text: String
    let comment: String?
}

/// 引擎当前的输入状态（未上屏的拼音和候选）
struct EngineState {
    var preedit: String = ""
    /// 光标在 preedit 里的位置（UTF-16）
    var cursor: Int = 0
    var candidates: [Candidate] = []
    var highlighted: Int = 0
    var pageNumber: Int = 0
    /// 当前页第一个候选在全部候选里的序号
    var pageStart: Int = 0
    var isLastPage: Bool = true
    /// 选词键标签，例如 "1234567"
    var selectLabels: [String] = []
    /// 当前输入方案的简称（显示在候选窗里，例如「全拼」「小鹤」）
    var schemaLabel: String = ""

    var isComposing: Bool { !preedit.isEmpty }
}

/// 一次按键交给引擎的结果
struct EngineResult {
    /// 引擎是否处理了这个键（没处理的键交还给 App）
    var handled: Bool
    /// 要上屏的文字
    var commit: String?
    /// 处理后的输入状态
    var state: EngineState
}

/// 打字引擎。SayFlow 的打字由 Rime（librime）完成，全部在本机运行，不联网。
@MainActor
protocol InputEngine: AnyObject {
    /// 引擎是否可以打中文（librime 未就绪时为 false，按键原样交给 App）
    var isReady: Bool { get }
    /// 当前是否英文模式
    var isAsciiMode: Bool { get }

    /// 普通按键
    func process(keyCode: UInt16, characters: String?, modifiers: RimeKeys.Modifiers) -> EngineResult
    /// 修饰键按下或松开（用于 Shift 切换中英文）
    func processModifier(keyCode: UInt16, pressed: Bool, modifiers: RimeKeys.Modifiers) -> EngineResult
    /// 用鼠标点选当前页的第 index 个候选
    func select(index: Int) -> EngineResult
    /// 当前的输入状态（不按任何键）
    var snapshot: EngineState { get }
    /// 展开候选：从第 from 个开始取最多 count 个候选（跨页）
    func candidateList(from: Int, count: Int) -> [Candidate]
    /// 按全部候选里的序号选词（展开候选时用）
    func select(globalIndex: Int) -> EngineResult
    /// 把当前输入的拼音原样上屏（例如切换 App 时）
    func commitRaw() -> String?
    /// 清除未上屏的输入
    func clear()

    func setAsciiMode(_ ascii: Bool)
    func apply(schema: InputSchema, pageSize: Int, learning: Bool)
    /// 清空本机词库（个人词频记忆）
    func clearUserDictionary() -> Bool
    /// 说明引擎状态，显示在设置里
    var statusText: String { get }
}

/// librime 还没编译进来时使用：所有按键原样交给 App。
/// 语音、改写等功能照常可用。
@MainActor
final class PassthroughEngine: InputEngine {
    var isReady: Bool { false }
    var isAsciiMode: Bool { true }

    func process(keyCode: UInt16, characters: String?, modifiers: RimeKeys.Modifiers) -> EngineResult {
        return EngineResult(handled: false, commit: nil, state: EngineState())
    }

    func processModifier(keyCode: UInt16, pressed: Bool, modifiers: RimeKeys.Modifiers) -> EngineResult {
        return EngineResult(handled: false, commit: nil, state: EngineState())
    }

    func select(index: Int) -> EngineResult {
        return EngineResult(handled: false, commit: nil, state: EngineState())
    }

    var snapshot: EngineState { EngineState() }
    func candidateList(from: Int, count: Int) -> [Candidate] { [] }

    func select(globalIndex: Int) -> EngineResult {
        return EngineResult(handled: false, commit: nil, state: EngineState())
    }

    func commitRaw() -> String? { nil }
    func clear() {}
    func setAsciiMode(_ ascii: Bool) {}
    func apply(schema: InputSchema, pageSize: Int, learning: Bool) {}
    func clearUserDictionary() -> Bool { false }
    var statusText: String { "打字引擎还没编进这个版本（等安全团队确认 Rime 后加入），目前按键原样输入英文" }
}

@MainActor
enum EngineFactory {
    static func make(prefs: Preferences) -> InputEngine {
        #if SAYFLOW_RIME
        if let engine = RimeEngine(prefs: prefs) { return engine }
        #endif
        return PassthroughEngine()
    }
}

extension NSEvent.ModifierFlags {
    var rimeModifiers: RimeKeys.Modifiers {
        var m: RimeKeys.Modifiers = []
        if contains(.shift) { m.insert(.shift) }
        if contains(.control) { m.insert(.control) }
        if contains(.option) { m.insert(.option) }
        if contains(.command) { m.insert(.command) }
        if contains(.capsLock) { m.insert(.capsLock) }
        return m
    }
}
