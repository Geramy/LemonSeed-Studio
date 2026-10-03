import Foundation

/// Timestamps as pi writes them: ISO 8601 with milliseconds, UTC.
public enum SessionTime {
    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)

    public static func string(_ date: Date) -> String { date.formatted(style) }
    public static func date(_ string: String) -> Date? {
        (try? style.parse(string)) ?? (try? Date.ISO8601FormatStyle().parse(string))
    }
    /// Unix milliseconds, used for message timestamps.
    public static func millis(_ date: Date = Date()) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }
}

public enum SessionIDs {
    /// pi's entry id: 8 lowercase hex characters.
    public static func short() -> String {
        String(format: "%08x", UInt32.random(in: .min ... .max))
    }
    public static func uuid() -> String { UUID().uuidString.lowercased() }
}
