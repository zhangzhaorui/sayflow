import Foundation
import SayFlowCore

final class TextSanitizerTests: XCTestCase {
    func testPlainTextUnchanged() {
        XCTAssertEqual(TextSanitizer.sanitize("你好，世界", singleLine: false), "你好，世界")
    }

    func testControlCharactersRemoved() {
        XCTAssertEqual(TextSanitizer.sanitize("ls\u{1B}[31m -la", singleLine: false), "ls[31m -la")
        XCTAssertEqual(TextSanitizer.sanitize("a\u{07}b\u{00}c\u{7F}", singleLine: false), "abc")
        XCTAssertEqual(TextSanitizer.sanitize("a\u{85}b\u{9B}c", singleLine: false), "abc")
    }

    func testInvisibleCharactersRemoved() {
        XCTAssertEqual(TextSanitizer.sanitize("a\u{200B}b\u{200F}c", singleLine: false), "abc")
        XCTAssertEqual(TextSanitizer.sanitize("abc\u{202E}dcba", singleLine: false), "abcdcba")
        XCTAssertEqual(TextSanitizer.sanitize("x\u{2066}y\u{2069}z", singleLine: false), "xyz")
        XCTAssertEqual(TextSanitizer.sanitize("\u{FEFF}hello", singleLine: false), "hello")
    }

    func testNewlyRequiredRangesRemoved() {
        // U+2060–U+2064
        XCTAssertEqual(TextSanitizer.sanitize("a\u{2060}b\u{2061}c\u{2062}d\u{2063}e\u{2064}f", singleLine: false), "abcdef")
        // Unicode 标签字符 U+E0000–U+E007F（可用来藏指令）
        let tagValues: [UInt32] = [0xE0001, 0xE0072, 0xE006D, 0xE007F]
        var view = String.UnicodeScalarView()
        view.append(contentsOf: tagValues.compactMap { Unicode.Scalar($0) })
        let hidden = "ok" + String(view)
        XCTAssertEqual(TextSanitizer.sanitize(hidden, singleLine: false), "ok")
    }

    func testNewlinesNormalised() {
        XCTAssertEqual(TextSanitizer.sanitize("a\r\nb\rc", singleLine: false), "a\nb\nc")
        XCTAssertEqual(TextSanitizer.sanitize("a\u{2028}b", singleLine: false), "a\nb")
    }

    func testTerminalSingleLine() {
        XCTAssertEqual(TextSanitizer.sanitize("echo hi\nrm -rf /tmp/x\n", singleLine: true), "echo hi rm -rf /tmp/x")
        XCTAssertEqual(TextSanitizer.sanitize("a\tb", singleLine: true), "a b")
        XCTAssertEqual(TextSanitizer.sanitize("a\u{2028}b", singleLine: true), "a b")
        XCTAssertEqual(TextSanitizer.sanitize("第一行\n第二行", singleLine: false), "第一行\n第二行")
    }
}

final class ResultGuardTests: XCTestCase {
    func testExpansion() {
        XCTAssertFalse(ResultGuard.isTooMuchLonger(raw: "帮我写一个函数", cleaned: "帮我写一个函数。"))
        XCTAssertTrue(ResultGuard.isTooMuchLonger(raw: "帮我写一个函数", cleaned: "帮我写一个函数。以下是代码：" + String(repeating: "字", count: 40)))
        XCTAssertFalse(ResultGuard.isTooMuchLonger(raw: String(repeating: "字", count: 100), cleaned: String(repeating: "字", count: 170)))
        XCTAssertTrue(ResultGuard.isTooMuchLonger(raw: String(repeating: "字", count: 100), cleaned: String(repeating: "字", count: 171)))
    }

    func testTranslationNotFlagged() {
        let zh = "明天下午三点开会，请大家准时参加。"
        let en = "We have a meeting at 3 pm tomorrow afternoon. Please be on time."
        XCTAssertFalse(ResultGuard.isTooMuchLonger(raw: zh, cleaned: en))
        XCTAssertFalse(ResultGuard.isTooMuchLonger(raw: en, cleaned: zh))
    }

    func testUnits() {
        XCTAssertEqual(TextMeasure.units("你好，world 2026！"), 4)
        XCTAssertEqual(TextMeasure.units("don't stop"), 2)
        XCTAssertEqual(TextMeasure.units(""), 0)
    }
}

final class PromptTests: XCTestCase {
    func testAutoStylePicksAppHint() {
        let prompt = PromptBuilder.systemPrompt(appName: "Terminal", bundleID: "com.apple.Terminal", dictionary: ["Claude Code"], style: .auto)
        XCTAssertTrue(prompt.contains(AppProfiles.codeHint))
        XCTAssertTrue(prompt.contains("Claude Code"))
        XCTAssertTrue(prompt.contains("绝对不要回答"))
    }

    func testStyleOverride() {
        let prompt = PromptBuilder.systemPrompt(appName: "Terminal", bundleID: "com.apple.Terminal", dictionary: [], style: .formal)
        XCTAssertTrue(prompt.contains(AppProfiles.docHint))
        XCTAssertFalse(prompt.contains(AppProfiles.codeHint))
    }

    func testTerminalDetection() {
        XCTAssertTrue(AppProfiles.isTerminal("com.googlecode.iterm2"))
        XCTAssertFalse(AppProfiles.isTerminal("com.apple.TextEdit"))
        XCTAssertFalse(AppProfiles.isTerminal(nil))
    }
}

final class GatewayTests: XCTestCase {
    func testDefaultEndpoint() {
        let e = GatewayEndpoint.builtinDefault
        XCTAssertEqual(e.sttModel, "qwen3-asr-1.7b")
        XCTAssertEqual(e.cleanupModel, "gemini-3.1-flash-lite")
        XCTAssertEqual(e.rewriteModel, "gemini-3.1-flash-lite")
    }

    func testBaseURLNormalisation() {
        XCTAssertEqual(GatewayEndpoint.normalizeBaseURL(" https://api.example.com/ "), "https://api.example.com")
        XCTAssertEqual(GatewayEndpoint.normalizeBaseURL("https://api.example.com/v1/"), "https://api.example.com")
        XCTAssertEqual(GatewayEndpoint.normalizeBaseURL("https://gw.example.com:8443/openai"), "https://gw.example.com:8443/openai")
        XCTAssertNil(GatewayEndpoint.normalizeBaseURL("http://api.example.com"))
        XCTAssertNil(GatewayEndpoint.normalizeBaseURL("api.example.com"))
        XCTAssertNil(GatewayEndpoint.normalizeBaseURL("https://user:pw@example.com"))
        XCTAssertNil(GatewayEndpoint.normalizeBaseURL("https://example.com?x=1"))
        XCTAssertNil(GatewayEndpoint.normalizeBaseURL("https://exa mple.com"))
    }

    func testEndpointURLWithPrefix() {
        guard case .success(let e) = GatewayEndpoint.make(baseURL: "https://gw.example.com/openai", sttModel: "a", cleanupModel: "b", rewriteModel: "c") else {
            return XCTFail("should be valid")
        }
        XCTAssertEqual(e.url(for: GatewayConfig.transcriptionPath)?.absoluteString,
                       "https://gw.example.com/openai/v1/audio/transcriptions")
    }

    func testModelIDValidation() {
        XCTAssertTrue(GatewayEndpoint.isValidModelID("qwen3.8-27b-fp8-gpustack-24g:nina-v6"))
        XCTAssertTrue(GatewayEndpoint.isValidModelID("zai-org/glm-5"))
        XCTAssertTrue(GatewayEndpoint.isValidModelID("MaaS_Cl_Sonnet_4.6_20260217_cache"))
        XCTAssertFalse(GatewayEndpoint.isValidModelID(""))
        XCTAssertFalse(GatewayEndpoint.isValidModelID("gpt 5"))
        XCTAssertFalse(GatewayEndpoint.isValidModelID("a\"b"))
        if case .failure(let err) = GatewayEndpoint.make(baseURL: "https://x.com", sttModel: "ok", cleanupModel: "ok", rewriteModel: "bad model") {
            XCTAssertEqual(err, .badRewriteModel)
        } else {
            XCTFail("should fail")
        }
        // 留空用默认值
        if case .success(let e) = GatewayEndpoint.make(baseURL: "https://x.com", sttModel: " ", cleanupModel: "", rewriteModel: "big-model") {
            XCTAssertEqual(e.sttModel, GatewayConfig.defaultSTTModel)
            XCTAssertEqual(e.cleanupModel, GatewayConfig.defaultCleanupModel)
            XCTAssertEqual(e.rewriteModel, "big-model")
        } else {
            XCTFail("should succeed")
        }
    }

    func testChatParsing() throws {
        let body = #"{"choices":[{"message":{"content":"<think>x</think>  整理好的文字 "}}]}"#
        XCTAssertEqual(try GatewayResponse.chatText(from: Data(body.utf8)), "整理好的文字")
        let parts = #"{"choices":[{"message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}]}"#
        XCTAssertEqual(try GatewayResponse.chatText(from: Data(parts.utf8)), "ab")
    }

    func testTranscriptionParsing() throws {
        XCTAssertEqual(try GatewayResponse.transcriptionText(from: Data(#"{"text":"你好"}"#.utf8)), "你好")
        XCTAssertThrowsError(try GatewayResponse.transcriptionText(from: Data("{}".utf8)))
    }

    func testErrorMessage() {
        XCTAssertEqual(GatewayResponse.errorMessage(from: Data(#"{"error":{"message":"Invalid token"}}"#.utf8)), "Invalid token")
    }

    func testMultipart() {
        let form = GatewayRequests.transcriptionForm(audio: Data([1, 2, 3]), dictionary: ["A", "B"], model: "qwen3-asr-1.7b")
        let text = String(decoding: form.finished(), as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nqwen3-asr-1.7b"))
        XCTAssertTrue(text.contains("name=\"prompt\"\r\n\r\nA, B"))
        XCTAssertTrue(text.hasSuffix("--" + form.boundary + "--\r\n"))
    }

    func testKeyFormat() {
        XCTAssertTrue(APIKeyFormat.isValid("sk-abcDEF123_456.789xyz"))
        XCTAssertFalse(APIKeyFormat.isValid("sk-abc\"\nurl = evil"))
        XCTAssertFalse(APIKeyFormat.isValid("short"))
        XCTAssertFalse(APIKeyFormat.isValid("sk-has space here"))
    }
}

final class SupportTests: XCTestCase {
    func testOrderedDelivery() {
        let d = OrderedDelivery<String>()
        let a = d.reserve(), b = d.reserve(), c = d.reserve()
        XCTAssertEqual(d.resolve(b, "二"), [])
        XCTAssertEqual(d.resolve(c, nil), [])
        XCTAssertEqual(d.resolve(a, "一"), ["一", "二"])
        let e = d.reserve()
        XCTAssertEqual(d.resolve(e, "四"), ["四"])
    }

    func testDictionaryParser() {
        XCTAssertEqual(DictionaryParser.parse("Claude Code，Cursor、New API\nCursor, ,"), ["Claude Code", "Cursor", "New API"])
        XCTAssertEqual(DictionaryParser.parse("a\u{202E}b"), ["ab"])
    }

}

final class RewriteTests: XCTestCase {
    func testPrompt() {
        let p = RewriteAction.systemPrompt(.toEnglish, dictionary: ["SayFlow"])
        XCTAssertTrue(p.contains("英文"))
        XCTAssertTrue(p.contains("绝对不要回答"))
        XCTAssertTrue(p.contains("SayFlow"))
        XCTAssertEqual(RewriteAction.userMessage("a"), "<text>\na\n</text>")
        XCTAssertEqual(GatewayResponse.clean("<text>\nhi\n</text>"), "hi")
    }
}

final class PreviewTests: XCTestCase {
    func testPreview() {
        XCTAssertEqual(TextPreview.line("a\nb\tc"), "a b c")
        XCTAssertEqual(TextPreview.line(String(repeating: "字", count: 70), maxLength: 5), "字字字字字…")
    }
}

final class KeyMappingTests: XCTestCase {
    func testKeysyms() {
        XCTAssertEqual(RimeKeys.keysym(keyCode: 0, charactersIgnoringModifiers: "a"), 0x61)
        XCTAssertEqual(RimeKeys.keysym(keyCode: 36, charactersIgnoringModifiers: "\r"), 0xFF0D)
        XCTAssertEqual(RimeKeys.keysym(keyCode: 49, charactersIgnoringModifiers: " "), 0x20)
        XCTAssertNil(RimeKeys.keysym(keyCode: 0, charactersIgnoringModifiers: "é"))
        XCTAssertEqual(RimeKeys.modifierKeysyms[56], 0xFFE1)
        XCTAssertEqual(RimeKeys.mask([.shift, .control], release: true), RimeKeys.shiftMask | RimeKeys.controlMask | RimeKeys.releaseMask)
    }
}
