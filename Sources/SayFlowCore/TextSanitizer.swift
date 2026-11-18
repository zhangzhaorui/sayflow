import Foundation

/// 粘贴前的文字安全处理。
public enum TextSanitizer {
    /// - Parameters:
    ///   - singleLine: 目标是终端类 App 时为 true，换行和 Tab 一律替换为空格，避免粘贴即执行。
    public static func sanitize(_ text: String, singleLine: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        var previous: Unicode.Scalar? = nil
        for scalar in text.unicodeScalars {
            let value = scalar.value
            // 统一换行：CRLF、单独的 CR、Unicode 行/段分隔符都当作换行
            if value == 0x0D {
                scalars.append("\n")
                previous = scalar
                continue
            }
            if value == 0x0A, previous?.value == 0x0D {
                previous = scalar
                continue
            }
            previous = scalar
            if value == 0x2028 || value == 0x2029 {
                scalars.append("\n")
                continue
            }
            if isRemoved(value) { continue }
            scalars.append(scalar)
        }
        var result = String(scalars)
        if singleLine {
            result = collapseWhitespace(result)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 需要删除的隐形或控制字符
    public static func isRemoved(_ value: UInt32) -> Bool {
        switch value {
        case 0x09, 0x0A:
            return false                      // 保留 Tab 和换行（终端里另行替换）
        case 0x00...0x1F, 0x7F:
            return true                       // C0 控制字符（含终端转义序列的 ESC）、DEL
        case 0x80...0x9F:
            return true                       // C1 控制字符
        case 0x200B...0x200F:
            return true                       // 零宽字符、从左到右/从右到左标记
        case 0x202A...0x202E:
            return true                       // 方向嵌入/覆盖
        case 0x2060...0x2064:
            return true                       // 词连接符、不可见运算符
        case 0x2066...0x2069:
            return true                       // 方向隔离
        case 0xFEFF:
            return true                       // BOM / 零宽不换行空格
        case 0xE0000...0xE007F:
            return true                       // Unicode 标签字符
        default:
            return false
        }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\t" || scalar == " " {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(scalar)
                lastWasSpace = false
            }
        }
        return String(out)
    }
}

/// AI 结果的长度保护（安全要求：超过原文 1.5 倍加 20 字时改用原文）
public enum ResultGuard {
    /// 结果长度超过「原文 × 1.5 + 20」时返回 true，此时应改用原文。
    /// 长度按 TextMeasure.units 计：一个汉字算 1，一个英文单词或一串数字算 1，
    /// 这样中英互译不会因为英文字母多而被误判。
    public static func isTooMuchLonger(raw: String,
                                       cleaned: String,
                                       ratio: Double = GatewayConfig.maxExpandRatio,
                                       slack: Int = GatewayConfig.maxExpandChars) -> Bool {
        let rawCount = Double(TextMeasure.units(raw))
        let cleanedCount = Double(TextMeasure.units(cleaned))
        return cleanedCount > rawCount * ratio + Double(slack)
    }
}

/// 文字长度：汉字（及其他非拉丁文字）每个算 1；连续的字母或数字算 1；标点、空白不算
public enum TextMeasure {
    public static func units(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isLatinWordChar = (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
                || (0xC0...0x24F).contains(v) || v == 0x27 || v == 0x2D
            if isLatinWordChar {
                if !inWord { count += 1 }
                inWord = true
                continue
            }
            inWord = false
            if scalar.properties.isWhitespace { continue }
            if scalar.properties.generalCategory.isPunctuationOrSymbol { continue }
            count += 1
        }
        return count
    }
}

private extension Unicode.GeneralCategory {
    var isPunctuationOrSymbol: Bool {
        switch self {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}
