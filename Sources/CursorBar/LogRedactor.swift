import Foundation
import OSLog

private let logger = Logger(subsystem: "com.cursorbar", category: "general")

enum Log {
    static func info(_ message: String) {
        logger.info("\(LogRedactor.redact(message))")
    }

    static func error(_ message: String) {
        logger.error("\(LogRedactor.redact(message))")
    }
}

enum LogRedactor {
    private static let emailRegex = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        options: [.caseInsensitive])
    private static let cookieRegex = try! NSRegularExpression(
        pattern: #"(?i)(cookie\s*:\s*)([^\r\n]+)"#)
    private static let authRegex = try! NSRegularExpression(
        pattern: #"(?i)(authorization\s*:\s*)([^\r\n]+)"#)
    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"(?i)\bbearer\s+[a-z0-9._\-]+=*\b"#)

    static func redact(_ text: String) -> String {
        var output = text
        output = replace(emailRegex, in: output, with: "<redacted-email>")
        output = replace(cookieRegex, in: output, with: "$1<redacted>")
        output = replace(authRegex, in: output, with: "$1<redacted>")
        output = replace(bearerRegex, in: output, with: "Bearer <redacted>")
        return output
    }

    private static func replace(
        _ regex: NSRegularExpression, in text: String, with template: String
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
