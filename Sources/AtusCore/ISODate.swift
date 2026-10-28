import Foundation

/// Parses the ISO-8601 timestamps both vendors return. They use microsecond
/// fractions ("10:10:00.714906+00:00") that Foundation's ISO parser rejects,
/// so the fraction is normalised to milliseconds first.
public enum ISODate {
    public static func parse(_ string: String) -> Date? {
        let normalized = normalizeFraction(string)
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(normalized) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(normalized)
    }

    static func normalizeFraction(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        let digitsStart = string.index(after: dot)
        let digitsEnd = string[digitsStart...].firstIndex { !$0.isNumber } ?? string.endIndex
        let digits = string[digitsStart..<digitsEnd]
        let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return String(string[..<digitsStart]) + millis + String(string[digitsEnd...])
    }
}
