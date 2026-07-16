import Foundation

enum LogRedactor {
    private static let replacements: [(NSRegularExpression, String)] = {
        let patterns = [
            (#"(?i)(\"(?:token|authorization|roon_auth_token)\"\s*:\s*\")[^\"]*(\")"#, "$1[redacted]$2"),
            (#"(?i)((?:token|authorization|roon_auth_token)\s*[=:]\s*)[^\s,&}\]]+"#, "$1[redacted]"),
            (#"(?i)([?&](?:token|roon_auth_token|authorization)=)[^&\s]+"#, "$1[redacted]"),
            (#"(?i)(\"(?:user_?id|machine_?id|core_?id|paired_core_id|profile_?id)\"\s*:\s*\")[^\"]*(\")"#, "$1[redacted]$2"),
            (#"(?i)((?:user_?id|machine_?id|core_?id|paired_core_id|profile_?id)\s*[=:]\s*)[A-F0-9-]{8,}"#, "$1[redacted]"),
            (#"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[redacted-email]")
        ]
        return patterns.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
        }
    }()

    static func redact(_ value: String) -> String {
        var result = value.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        for (regex, replacement) in replacements {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        return result
    }

    static func event(_ event: RuntimeEvent) -> RuntimeEvent {
        var copy = event
        copy.message = redact(event.message)
        return copy
    }
}
