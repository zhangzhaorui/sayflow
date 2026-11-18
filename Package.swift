// swift-tools-version:5.9
// SayFlow 2.0 输入法：Rime 打字（本机）+ 语音输入 / AI 整理 / AI 改写（可关，连你自己的网关）
// 纯 AppKit + InputMethodKit，不使用 SwiftUI 和宏，只用「命令行工具」即可编译（不需要完整 Xcode）。
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rimeLibDir = root + "/vendor/rime/lib"
// librime 静态库由 scripts/build-librime.sh 生成；没有时编出「英文直通」版本，其他功能照常
let rimeLibs: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: rimeLibDir)) ?? [])
    .filter { $0.hasPrefix("lib") && $0.hasSuffix(".a") }
    .sorted()
let hasRime = rimeLibs.contains("librime.a")

var imeDependencies: [Target.Dependency] = ["SayFlowCore"]
var imeSwiftSettings: [SwiftSetting] = []
var imeLinkerSettings: [LinkerSetting] = [
    .linkedFramework("AppKit"),
    .linkedFramework("InputMethodKit"),
    .linkedFramework("Carbon"),
    .linkedFramework("AVFoundation"),
    .linkedFramework("AudioToolbox"),
    .linkedFramework("CoreAudio"),
    .linkedFramework("Security"),
]
var targets: [Target] = [
    // 纯逻辑：文字过滤、提示词、请求格式、文字预览、按键编码。只依赖 Foundation，可单独测试。
    .target(name: "SayFlowCore", path: "Sources/SayFlowCore"),
    // 单元检查（不依赖 XCTest）：swift run SayFlowCoreChecks
    .executableTarget(name: "SayFlowCoreChecks", dependencies: ["SayFlowCore"], path: "Sources/SayFlowCoreChecks"),
]

if hasRime {
    targets.append(.systemLibrary(name: "CRime", path: "Sources/CRime"))
    imeDependencies.append("CRime")
    imeSwiftSettings.append(.define("SAYFLOW_RIME"))
    // librime.a 用 force_load 整体链接，保证合并进来的插件（octagram、predict）注册生效
    let names = rimeLibs.filter { $0 != "librime.a" }.map { String($0.dropFirst(3).dropLast(2)) }
    imeLinkerSettings.append(.unsafeFlags(["-L" + rimeLibDir, "-Xlinker", "-force_load", "-Xlinker", rimeLibDir + "/librime.a"]
                                          + names.map { "-l" + $0 }))
    imeLinkerSettings.append(.linkedLibrary("c++"))
}

// 只导出 main：librime 和 boost 等静态库里的 C++ 模板函数（弱符号）不再导出，
// 避免运行时被系统框架里同名的 C++ 符号「合并」替换掉（会导致拼音查不到词）。
let exportOnlyMain: LinkerSetting = .unsafeFlags(["-Xlinker", "-exported_symbol", "-Xlinker", "_main"])

if hasRime {
    imeLinkerSettings.append(exportOnlyMain)
    // 打包验证工具（不放进 App）：用和输入法完全一样的编译、链接方式模拟打字，见 编译打字引擎.command
    targets.append(.executableTarget(name: "RimeProbe", dependencies: ["CRime"], path: "Sources/RimeProbe",
                                     linkerSettings: imeLinkerSettings))
}

targets.append(.executableTarget(
    name: "SayFlow",
    dependencies: imeDependencies,
    path: "Sources/SayFlowIME",
    swiftSettings: imeSwiftSettings,
    linkerSettings: imeLinkerSettings
))

let package = Package(
    name: "SayFlow",
    platforms: [.macOS(.v13)],
    targets: targets
)
