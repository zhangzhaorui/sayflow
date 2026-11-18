import Foundation

// 不依赖 XCTest 的单元检查（命令行工具里没有 XCTest）。运行：swift run SayFlowCoreChecks
var failures = 0
var current = ""

func record(_ ok: Bool, _ message: String, file: StaticString, line: UInt) {
    if !ok {
        failures += 1
        print("FAIL  \(current)  \(file):\(line)  \(message)")
    }
}

func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    record((try? value()) ?? false, "应为 true " + message, file: file, line: line)
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    record(!((try? value()) ?? true), "应为 false " + message, file: file, line: line)
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    do {
        let x = try a(), y = try b()
        record(x == y, "\(x) != \(y) " + message, file: file, line: line)
    } catch {
        record(false, "抛出错误 \(error)", file: file, line: line)
    }
}
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    let v = try? value()
    record(v == nil || v! == nil, "应为 nil " + message, file: file, line: line)
}
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, file: StaticString = #fileID, line: UInt = #line) {
    var threw = false
    do { _ = try value() } catch { threw = true }
    record(threw, "应抛出错误", file: file, line: line)
}
func XCTFail(_ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    record(false, message, file: file, line: line)
}

class XCTestCase {
    required init() {}
}

func run(_ name: String, _ body: () throws -> Void) {
    current = name
    do { try body() } catch { record(false, "抛出错误 \(error)", file: #fileID, line: #line) }
}

run("TextSanitizerTests.testPlainTextUnchanged") { TextSanitizerTests().testPlainTextUnchanged() }
run("TextSanitizerTests.testControlCharactersRemoved") { TextSanitizerTests().testControlCharactersRemoved() }
run("TextSanitizerTests.testInvisibleCharactersRemoved") { TextSanitizerTests().testInvisibleCharactersRemoved() }
run("TextSanitizerTests.testNewlyRequiredRangesRemoved") { TextSanitizerTests().testNewlyRequiredRangesRemoved() }
run("TextSanitizerTests.testNewlinesNormalised") { TextSanitizerTests().testNewlinesNormalised() }
run("TextSanitizerTests.testTerminalSingleLine") { TextSanitizerTests().testTerminalSingleLine() }
run("ResultGuardTests.testExpansion") { ResultGuardTests().testExpansion() }
run("ResultGuardTests.testTranslationNotFlagged") { ResultGuardTests().testTranslationNotFlagged() }
run("ResultGuardTests.testUnits") { ResultGuardTests().testUnits() }
run("PromptTests.testAutoStylePicksAppHint") { PromptTests().testAutoStylePicksAppHint() }
run("PromptTests.testStyleOverride") { PromptTests().testStyleOverride() }
run("PromptTests.testTerminalDetection") { PromptTests().testTerminalDetection() }
run("GatewayTests.testDefaultEndpoint") { GatewayTests().testDefaultEndpoint() }
run("GatewayTests.testBaseURLNormalisation") { GatewayTests().testBaseURLNormalisation() }
run("GatewayTests.testEndpointURLWithPrefix") { GatewayTests().testEndpointURLWithPrefix() }
run("GatewayTests.testModelIDValidation") { GatewayTests().testModelIDValidation() }
run("GatewayTests.testChatParsing") { try GatewayTests().testChatParsing() }
run("GatewayTests.testTranscriptionParsing") { try GatewayTests().testTranscriptionParsing() }
run("GatewayTests.testErrorMessage") { GatewayTests().testErrorMessage() }
run("GatewayTests.testMultipart") { GatewayTests().testMultipart() }
run("GatewayTests.testKeyFormat") { GatewayTests().testKeyFormat() }
run("SupportTests.testOrderedDelivery") { SupportTests().testOrderedDelivery() }
run("SupportTests.testDictionaryParser") { SupportTests().testDictionaryParser() }
run("RewriteTests.testPrompt") { RewriteTests().testPrompt() }
run("PreviewTests.testPreview") { PreviewTests().testPreview() }
run("KeyMappingTests.testKeysyms") { KeyMappingTests().testKeysyms() }

print(failures == 0 ? "全部通过：26 项检查" : "不通过：\(failures) 处")
exit(failures == 0 ? 0 : 1)
