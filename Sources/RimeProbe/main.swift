// 开发诊断：用和输入法完全一样的 Swift 调用方式、一样的编译和链接参数测试 librime（不放进 App）。
// 用法：swift run -c release --arch arm64 RimeProbe <shared> <user>
import Foundation
import CRime

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: RimeProbe <shared> <user>"); exit(2) }
let shared = URL(fileURLWithPath: args[1])
let user = URL(fileURLWithPath: args[2])

func cString(_ s: String) -> UnsafePointer<CChar>? { strdup(s).map { UnsafePointer($0) } }

if let loc = ProcessInfo.processInfo.environment["SETLOCALE"] {
    let r = setlocale(LC_ALL, loc)
    print("setlocale(\(loc)) -> " + (r.map { String(cString: $0) } ?? "(null)"))
}
print("LC_CTYPE=" + (setlocale(LC_CTYPE, nil).map { String(cString: $0) } ?? "?"))
guard let api = rime_get_api() else { print("no api"); exit(1) }
var traits = RimeTraits()
traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
traits.shared_data_dir = cString(shared.path)
traits.prebuilt_data_dir = cString(shared.appendingPathComponent("build").path)
traits.user_data_dir = cString(user.path)
traits.staging_dir = cString(user.appendingPathComponent("build").path)
traits.distribution_name = cString("SayFlow")
traits.distribution_code_name = cString("SayFlow")
traits.distribution_version = cString("2.0.0")
let env = ProcessInfo.processInfo.environment
traits.app_name = cString(env["APPNAME"] ?? "rime.sayflow")
if let level = env["LOGLEVEL"], let n = Int32(level) { traits.min_log_level = n } else { traits.min_log_level = 4 }
if env["NO_DIST"] == "1" {
    traits.distribution_name = nil
    traits.distribution_code_name = nil
    traits.distribution_version = nil
}
if env["NO_PREBUILT"] == "1" { traits.prebuilt_data_dir = nil }
print("variant: APPNAME=\(env["APPNAME"] ?? "-") LOGLEVEL=\(env["LOGLEVEL"] ?? "-") NO_DIST=\(env["NO_DIST"] ?? "-") NO_PREBUILT=\(env["NO_PREBUILT"] ?? "-") MAIN=\(env["MAIN"] ?? "-")")
print("traits.data_size=\(traits.data_size) MemoryLayout.size=\(MemoryLayout<RimeTraits>.size) stride=\(MemoryLayout<RimeTraits>.stride)")
api.pointee.setup?(&traits)
api.pointee.initialize?(&traits)

if env["NO_MAINT"] == "1" {
    print("跳过部署（不在本进程里编译任何东西）")
} else if env["MAIN"] == "1" {
    if api.pointee.start_maintenance?(1) != 0 { api.pointee.join_maintenance_thread?() }
} else {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        if api.pointee.start_maintenance?(1) != 0 { api.pointee.join_maintenance_thread?() }
        done.signal()
    }
    done.wait()
}

func candidates(_ s: RimeSessionId) -> String {
    var ctx = RimeContext()
    ctx.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
    guard api.pointee.get_context?(s, &ctx) != 0 else { return "（无 context）" }
    defer { _ = api.pointee.free_context?(&ctx) }
    var out = "preedit=" + (ctx.composition.preedit.map { String(cString: $0) } ?? "") + " 候选:"
    if let list = ctx.menu.candidates {
        for i in 0..<Int(min(ctx.menu.num_candidates, 5)) { out += " " + (list[i].text.map { String(cString: $0) } ?? "") }
    }
    return out
}

let s = api.pointee.create_session?() ?? 0
let schemaID = env["SCHEMA"] ?? "rime_ice"
let inputs = (env["INPUTS"] ?? "wo weishenme").split(separator: " ").map(String.init)
print("select_schema(\(schemaID))=\(api.pointee.select_schema?(s, schemaID) ?? -1)")
for input in inputs {
    api.pointee.clear_composition?(s)
    for c in input.unicodeScalars { _ = api.pointee.process_key?(s, Int32(c.value), 0) }
    print("[\(input)] " + candidates(s))
}
// 符号键测试：KEYS="?,=,@,shift" 逐个模拟按键（带 Shift 的符号先按下 Shift 再松开），打印是否处理、上屏内容
func takeCommit(_ s: RimeSessionId) -> String {
    var commit = RimeCommit()
    commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
    guard api.pointee.get_commit?(s, &commit) != 0 else { return "" }
    defer { _ = api.pointee.free_commit?(&commit) }
    return commit.text.map { String(cString: $0) } ?? ""
}
if let keys = env["KEYS"] {
    let shifted = Set("~!@#$%^&*()_+{}|:\"<>?")
    for key in keys.split(separator: " ").map(String.init) {
        api.pointee.clear_composition?(s)
        var log: [String] = []
        if key == "shift" {
            let a = api.pointee.process_key?(s, 0xFFE1, 1) ?? -1
            let b = api.pointee.process_key?(s, 0xFFE1, 1 << 30) ?? -1
            var st = RimeStatus()
            st.data_size = Int32(MemoryLayout<RimeStatus>.size - MemoryLayout<Int32>.size)
            _ = api.pointee.get_status?(s, &st)
            log.append("press=\(a) release=\(b) ascii_mode=\(st.is_ascii_mode)")
            _ = api.pointee.free_status?(&st)
        } else if let ch = key.unicodeScalars.first {
            let needShift = shifted.contains(Character(ch))
            if needShift { log.append("Shift按下=\(api.pointee.process_key?(s, 0xFFE1, 1) ?? -1)") }
            let h = api.pointee.process_key?(s, Int32(ch.value), needShift ? 1 : 0) ?? -1
            log.append("键=\(h) 上屏=「\(takeCommit(s))」 " + candidates(s))
            if needShift { log.append("Shift松开=\(api.pointee.process_key?(s, 0xFFE1, 1 << 30) ?? -1) 上屏=「\(takeCommit(s))」") }
        }
        print("[\(key)] " + log.joined(separator: " "))
    }
}
_ = api.pointee.destroy_session?(s)
api.pointee.finalize?()
