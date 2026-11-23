import Foundation

/// The heading a note sits under in the list, by when it was last changed: Today, Yesterday, Previous 7 Days,
/// Previous 30 Days, then a month for the rest of this year and a year for earlier ones.
public enum NoteDateGroup: Hashable, Sendable {
    case today
    case yesterday
    case previous7Days
    case previous30Days
    case month(year: Int, month: Int)
    case year(Int)

    public init(date: Date, now: Date = .now, calendar: Calendar = .current) {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: self = .today
        case 1: self = .yesterday
        case 2...7: self = .previous7Days
        case 8...30: self = .previous30Days
        default:
            let parts = calendar.dateComponents([.year, .month], from: date)
            let year = parts.year ?? 0
            if year == calendar.component(.year, from: now), let month = parts.month {
                self = .month(year: year, month: month)
            } else {
                self = .year(year)
            }
        }
    }

    /// The oldest moment that still belongs to this group. A note from today or later is in Today.
    func lowerBound(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        func daysBack(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: today) ?? .distantPast }
        switch self {
        case .today: return today
        case .yesterday: return daysBack(1)
        case .previous7Days: return daysBack(7)
        case .previous30Days: return daysBack(30)
        case .month(let year, let month): return calendar.date(from: DateComponents(year: year, month: month)) ?? .distantPast
        case .year(let year): return calendar.date(from: DateComponents(year: year)) ?? .distantPast
        }
    }

    /// A run of neighboring items that share a group.
    public struct Run: Equatable, Sendable {
        public let group: NoteDateGroup
        public let range: Range<Int>
    }

    /// Splits items that are already sorted newest first into runs of one group each. It finds where each run ends by
    /// bisection, so it reads the date of only a few items instead of every one.
    public static func runs<Item>(
        of items: [Item],
        date: (Item) -> Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Run] {
        var runs: [Run] = []
        var start = 0
        while start < items.count {
            let group = NoteDateGroup(date: date(items[start]), now: now, calendar: calendar)
            let lower = group.lowerBound(now: now, calendar: calendar)
            // The first item is in the run. Find the first later item that is older than the group allows.
            var low = start + 1, high = items.count
            while low < high {
                let middle = (low + high) / 2
                if date(items[middle]) >= lower { low = middle + 1 } else { high = middle }
            }
            runs.append(Run(group: group, range: start..<low))
            start = low
        }
        return runs
    }
}

/// How a note's date is written in its row, as in Apple Notes: the time today, then Yesterday, the weekday for the
/// rest of the week, and the date after that.
public enum NoteRowDateStyle: Equatable, Sendable {
    case time, yesterday, weekday, date

    public init(date: Date, now: Date = .now, calendar: Calendar = .current) {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: self = .time
        case 1: self = .yesterday
        case 2...6: self = .weekday
        default: self = .date
        }
    }
}
