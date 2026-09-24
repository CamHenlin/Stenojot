import Foundation

public enum Timestamp {
    public static func parse(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    public static func formatTime(_ isoTimestamp: String, timeZone: TimeZone = .current) -> String {
        guard let date = parse(isoTimestamp) else { return isoTimestamp }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// A calendar date such as "Wednesday, Sep 23, 2026". Unlike `formatDateLabel`, this does not
    /// change when the day is today or yesterday, so a saved summary keeps its date.
    public static func formatLongDate(_ dateStr: String, calendar: Calendar = .current) -> String {
        guard let date = startOfCalendarDay(dateStr, calendar: calendar) else { return dateStr }
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US")
        output.timeZone = calendar.timeZone
        output.dateFormat = "EEEE, MMM d, yyyy"
        return output.string(from: date)
    }

    public static func localDay(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func formatDateLabel(
        _ dateStr: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: dateStr) else { return dateStr }

        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let dayDiff = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? 0
        if dayDiff == 0 { return "Today" }
        if dayDiff == 1 { return "Yesterday" }

        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US")
        output.timeZone = calendar.timeZone
        output.dateFormat = "EEE, MMM d"
        return output.string(from: date)
    }

    public static func nowISO8601(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// A timestamp that stays on `day` in `calendar`. Today uses the current time. An older day uses
    /// 23:59:59 in that timezone, so the note still appears on the day it belongs to.
    public static func noteTimestamp(
        onDay day: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard let day else { return nowISO8601(now) }
        if localDay(now, calendar: calendar) == day {
            return nowISO8601(now)
        }
        guard let start = startOfCalendarDay(day, calendar: calendar) else { return nowISO8601(now) }
        var parts = calendar.dateComponents([.year, .month, .day], from: start)
        parts.hour = 23
        parts.minute = 59
        parts.second = 59
        guard let end = calendar.date(from: parts) else { return nowISO8601(now) }
        return nowISO8601(end)
    }

    public static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func startOfCalendarDay(_ dateStr: String, calendar: Calendar) -> Date? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: dateStr) else { return nil }
        return calendar.startOfDay(for: date)
    }
}
