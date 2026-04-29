//
//  RegexFallback.swift
//  MacosStatsWidgetShared
//
//  Offline token extractor used while a selector is broken.
//

import Foundation

struct RegexFallbackToken: Equatable {
    enum TokenType: Int {
        case currency = 0
        case percent = 1
        case number = 2
    }

    var value: String
    var range: NSRange
    var type: TokenType
}

final class RegexFallback {
    static func bestValue(in text: String, previousValue: String?) -> String? {
        let tokens = allTokens(in: text)
        guard !tokens.isEmpty else {
            return nil
        }

        if let previousValue,
           !previousValue.isEmpty,
           let priorRange = (text as NSString).range(of: previousValue, options: [.caseInsensitive]).nonEmpty {
            return tokens
                .min { lhs, rhs in
                    distance(lhs.range, from: priorRange) < distance(rhs.range, from: priorRange)
                }?
                .value
        }

        return tokens.sorted { lhs, rhs in
            if lhs.type.rawValue != rhs.type.rawValue {
                return lhs.type.rawValue < rhs.type.rawValue
            }
            return lhs.range.location < rhs.range.location
        }
        .first?
        .value
    }

    private static func allTokens(in text: String) -> [RegexFallbackToken] {
        let patterns: [(RegexFallbackToken.TokenType, String)] = [
            (.currency, #"[$£€¥]\s?-?\d+(?:[.,]\d+)*"#),
            (.percent, #"-?\d+(?:[.,]\d+)*\s?%"#),
            (.number, #"-?\d+(?:[.,]\d+)*"#)
        ]
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var tokens: [RegexFallbackToken] = []
        var seenRanges: [NSRange] = []

        for (type, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let range = match?.range,
                      range.length > 0,
                      !seenRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) else {
                    return
                }

                let value = nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    return
                }

                seenRanges.append(range)
                tokens.append(RegexFallbackToken(value: value, range: range, type: type))
            }
        }

        return tokens
    }

    private static func distance(_ range: NSRange, from priorRange: NSRange) -> Int {
        if NSIntersectionRange(range, priorRange).length > 0 {
            return 0
        }

        if range.location > priorRange.location {
            return range.location - priorRange.upperBound
        }

        return priorRange.location - range.upperBound
    }
}

private extension NSRange {
    var upperBound: Int {
        location + length
    }

    var nonEmpty: NSRange? {
        location != NSNotFound && length > 0 ? self : nil
    }
}
