import Foundation

/// Whether a place is open right now, derived from `hours` jsonb or a parseable `hours_text`.
public enum OpenStatus: Sendable, Hashable {
    /// Open now; `closesAt` is the closing time today when known.
    case open(closesAt: Date?)
    /// Closed now; `opensAt` is the next opening time when known.
    case closed(opensAt: Date?)
    /// Hours missing or not understood. Show the raw text instead.
    case unknown
}

/// A time of day in minutes since midnight.
public struct MinuteOfDay: Sendable, Hashable, Comparable {
    public var minutes: Int
    public init(_ minutes: Int) { self.minutes = minutes }
    public init(hour: Int, minute: Int) { minutes = hour * 60 + minute }
    public var hour: Int { minutes / 60 }
    public var minute: Int { minutes % 60 }
    public static func < (lhs: MinuteOfDay, rhs: MinuteOfDay) -> Bool { lhs.minutes < rhs.minutes }
}

public struct TimeRange: Sendable, Hashable {
    public var start: MinuteOfDay
    public var end: MinuteOfDay
    public init(start: MinuteOfDay, end: MinuteOfDay) {
        self.start = start
        self.end = end
    }
    public func contains(_ t: MinuteOfDay) -> Bool {
        if end > start { return t >= start && t < end }
        // Overnight (e.g. 22:00-02:00)
        return t >= start || t < end
    }
}

/// Weekly schedule keyed by weekday (1 = Sunday … 7 = Saturday, matching `Calendar`).
public struct WeeklyHours: Sendable, Hashable {
    public var days: [Int: [TimeRange]]

    public init(days: [Int: [TimeRange]]) { self.days = days }

    public static let weekdayKeys: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
    ]

    /// Parse the structured `hours` jsonb (`{"mon":"9:00-17:00","sun":"closed"}`).
    public init?(json: [String: String]) {
        var days: [Int: [TimeRange]] = [:]
        for (key, value) in json {
            guard let weekday = Self.weekdayKeys[key.lowercased().trimmingCharacters(in: .whitespaces)] else { continue }
            days[weekday] = HoursParser.parseRanges(value)
        }
        guard !days.isEmpty else { return nil }
        self.days = days
    }

    /// Parse free text such as "Mon–Fri 9am–5pm; Sat 10am–2pm" or "Daily 8:00-20:00".
    public init?(text: String) {
        guard let parsed = HoursParser.parseText(text) else { return nil }
        self = parsed
    }

    public func status(at date: Date, calendar: Calendar = .current) -> OpenStatus {
        let weekday = calendar.component(.weekday, from: date)
        let now = MinuteOfDay(hour: calendar.component(.hour, from: date), minute: calendar.component(.minute, from: date))
        let todayRanges = days[weekday] ?? []
        if let range = todayRanges.first(where: { $0.contains(now) }) {
            return .open(closesAt: calendar.date(bySettingHour: range.end.hour, minute: range.end.minute, second: 0, of: date))
        }
        // Next opening: later today, then the following 7 days.
        if let next = todayRanges.filter({ $0.start > now }).min(by: { $0.start < $1.start }) {
            return .closed(opensAt: calendar.date(bySettingHour: next.start.hour, minute: next.start.minute, second: 0, of: date))
        }
        for offset in 1...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            let wd = calendar.component(.weekday, from: day)
            if let first = days[wd]?.min(by: { $0.start < $1.start }) {
                return .closed(opensAt: calendar.date(bySettingHour: first.start.hour, minute: first.start.minute, second: 0, of: day))
            }
        }
        return .closed(opensAt: nil)
    }
}

public enum HoursParser {
    /// "9:00-17:00", "9am-5pm", "9:30 AM – 6 PM", "closed", "9-5, 6-9". Unparseable → empty (closed).
    public static func parseRanges(_ value: String) -> [TimeRange] {
        let lowered = value.lowercased()
        if lowered.contains("closed") { return [] }
        return lowered
            .split(whereSeparator: { $0 == "," || $0 == "&" })
            .compactMap { parseRange(String($0)) }
    }

    static func parseRange(_ text: String) -> TimeRange? {
        let normalized = text
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: " to ", with: "-")
        let parts = normalized.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let start = parseTime(parts[0]), let end = parseTime(parts[1]) else { return nil }
        // "9-5pm" style: if the start has no meridiem and the end is pm, assume start is am
        // (already how parseTime treats a bare hour), so nothing extra to do here.
        return TimeRange(start: start, end: end)
    }

    /// Accepts "9", "9am", "9:30", "9:30pm", "17:00", "12pm", "noon", "midnight".
    static func parseTime(_ raw: String) -> MinuteOfDay? {
        var s = raw.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
        if s == "noon" { return MinuteOfDay(hour: 12, minute: 0) }
        if s == "midnight" { return MinuteOfDay(hour: 0, minute: 0) }
        var meridiem: String?
        if s.hasSuffix("am") { meridiem = "am"; s.removeLast(2) }
        else if s.hasSuffix("pm") { meridiem = "pm"; s.removeLast(2) }
        else if s.hasSuffix("a") { meridiem = "am"; s.removeLast() }
        else if s.hasSuffix("p") { meridiem = "pm"; s.removeLast() }
        let pieces = s.split(separator: ":")
        guard let first = pieces.first, var hour = Int(first), (0...24).contains(hour) else { return nil }
        var minute = 0
        if pieces.count > 1 {
            guard let m = Int(pieces[1]), (0...59).contains(m) else { return nil }
            minute = m
        }
        if pieces.count > 2 { return nil }
        switch meridiem {
        case "am": if hour == 12 { hour = 0 }
        case "pm": if hour < 12 { hour += 12 }
        default: break
        }
        if hour == 24 { hour = 0 }
        guard hour < 24 else { return nil }
        return MinuteOfDay(hour: hour, minute: minute)
    }

    /// Free-text weekly hours. Segments split on ";" or "|" or newline; each is "<days> <times>".
    static func parseText(_ text: String) -> WeeklyHours? {
        var days: [Int: [TimeRange]] = [:]
        let segments = text.split(whereSeparator: { $0 == ";" || $0 == "|" || $0.isNewline })
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard let (weekdays, remainder) = splitDays(trimmed) else { continue }
            let ranges = parseRanges(remainder)
            for wd in weekdays { days[wd, default: []].append(contentsOf: ranges) }
        }
        guard !days.isEmpty else { return nil }
        return WeeklyHours(days: days)
    }

    /// Splits "Mon-Fri 9am-5pm" into ([2,3,4,5,6], "9am-5pm"). "Daily"/"Every day" → all days.
    static func splitDays(_ segment: String) -> ([Int], String)? {
        let lowered = segment.lowercased()
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        if let range = lowered.range(of: "every day") ?? lowered.range(of: "daily") ?? lowered.range(of: "everyday") {
            return (Array(1...7), String(lowered[range.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        if lowered.hasPrefix("weekdays") {
            return ([2, 3, 4, 5, 6], String(lowered.dropFirst("weekdays".count)).trimmingCharacters(in: .whitespaces))
        }
        if lowered.hasPrefix("weekends") {
            return ([1, 7], String(lowered.dropFirst("weekends".count)).trimmingCharacters(in: .whitespaces))
        }
        // Consume leading day tokens: "mon-fri", "mon, wed, fri", "sat".
        var weekdays: [Int] = []
        var rest = Substring(lowered)
        while true {
            let token = rest.prefix { $0.isLetter || $0 == "-" || $0 == "," }
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ","))
            guard !cleaned.isEmpty else { break }
            if cleaned.contains("-") {
                let ends = cleaned.split(separator: "-").map(String.init)
                guard ends.count == 2, let a = WeeklyHours.weekdayKeys[ends[0]], let b = WeeklyHours.weekdayKeys[ends[1]] else { break }
                var d = a
                while true {
                    weekdays.append(d)
                    if d == b { break }
                    d = d % 7 + 1
                }
            } else if let d = WeeklyHours.weekdayKeys[cleaned] {
                weekdays.append(d)
            } else {
                break
            }
            rest = rest.dropFirst(token.count).drop { $0 == " " || $0 == "," || $0 == ":" }
        }
        guard !weekdays.isEmpty else { return nil }
        return (weekdays, String(rest).trimmingCharacters(in: .whitespaces))
    }
}

extension Place {
    /// Structured hours win; otherwise try to understand `hoursText`; otherwise `.unknown`.
    public func openStatus(at date: Date = Date(), calendar: Calendar = .current) -> OpenStatus {
        if let hours, let weekly = WeeklyHours(json: hours) {
            return weekly.status(at: date, calendar: calendar)
        }
        if let hoursText, let weekly = WeeklyHours(text: hoursText) {
            return weekly.status(at: date, calendar: calendar)
        }
        return .unknown
    }
}
