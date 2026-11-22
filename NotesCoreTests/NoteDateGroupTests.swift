import Testing
import Foundation
@testable import NotesCore

/// The list's date headings, and how a row writes its date.
struct NoteDateGroupTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Saturday, 21 November 2026, 15:30.
    private var now: Date { date(2026, 11, 21, 15, 30) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func group(_ value: Date) -> NoteDateGroup { NoteDateGroup(date: value, now: now, calendar: calendar) }

    @Test func groupsFollowTheDistanceInDays() {
        #expect(group(date(2026, 11, 21, 0, 1)) == .today)
        #expect(group(date(2026, 11, 22)) == .today, "a clock that runs ahead still reads as today")
        #expect(group(date(2026, 11, 20, 23, 59)) == .yesterday)
        #expect(group(date(2026, 11, 19)) == .previous7Days)
        #expect(group(date(2026, 11, 14)) == .previous7Days)
        #expect(group(date(2026, 11, 13)) == .previous30Days)
        #expect(group(date(2026, 10, 22)) == .previous30Days)
        #expect(group(date(2026, 10, 21)) == .month(year: 2026, month: 10))
        #expect(group(date(2026, 1, 2)) == .month(year: 2026, month: 1))
        #expect(group(date(2025, 12, 31)) == .year(2025))
    }

    @Test func runsSplitNewestFirstItemsAndCoverEveryItem() {
        let dates = [
            date(2026, 11, 21, 14), date(2026, 11, 21, 9),
            date(2026, 11, 20, 18),
            date(2026, 11, 17), date(2026, 11, 15),
            date(2026, 11, 1), date(2026, 10, 25),
            date(2026, 10, 3), date(2026, 10, 1, 0, 0),
            date(2026, 2, 14),
            date(2025, 6, 1), date(2025, 1, 1, 0, 0), date(2019, 3, 3),
        ]
        let runs = NoteDateGroup.runs(of: dates, date: { $0 }, now: now, calendar: calendar)
        #expect(runs.map(\.group) == [
            .today, .yesterday, .previous7Days, .previous30Days,
            .month(year: 2026, month: 10), .month(year: 2026, month: 2), .year(2025), .year(2019),
        ])
        #expect(runs.map(\.range) == [0..<2, 2..<3, 3..<5, 5..<7, 7..<9, 9..<10, 10..<12, 12..<13])
    }

    @Test func runsMatchGroupingEveryItemOneByOne() {
        // A spread of dates across years, newest first.
        let dates = (0..<400).map { now.addingTimeInterval(-Double($0) * 86_400 * 3.7) }
        let runs = NoteDateGroup.runs(of: dates, date: { $0 }, now: now, calendar: calendar)
        let direct = dates.map(group)
        #expect(runs.flatMap { run in run.range.map { _ in run.group } } == direct)
    }

    @Test func noItemsMakeNoRuns() {
        #expect(NoteDateGroup.runs(of: [Date](), date: { $0 }, now: now, calendar: calendar).isEmpty)
    }

    @Test func rowDatesReadLikeAppleNotes() {
        func style(_ value: Date) -> NoteRowDateStyle { NoteRowDateStyle(date: value, now: now, calendar: calendar) }
        #expect(style(date(2026, 11, 21, 8)) == .time)
        #expect(style(date(2026, 11, 20)) == .yesterday)
        #expect(style(date(2026, 11, 18)) == .weekday)
        #expect(style(date(2026, 11, 15)) == .weekday)
        #expect(style(date(2026, 11, 14)) == .date)
        #expect(style(date(2025, 1, 1)) == .date)
    }

    @Test func midnightRefreshMovesBothSectionsAndRowLabels() {
        let modified = date(2026, 11, 21, 23, 58)
        let before = date(2026, 11, 21, 23, 59)
        let after = date(2026, 11, 22, 0, 0)
        #expect(NoteDateGroup.runs(of: [modified], date: { $0 }, now: before, calendar: calendar).first?.group == .today)
        #expect(NoteDateGroup.runs(of: [modified], date: { $0 }, now: after, calendar: calendar).first?.group == .yesterday)
        #expect(NoteRowDateStyle(date: modified, now: before, calendar: calendar) == .time)
        #expect(NoteRowDateStyle(date: modified, now: after, calendar: calendar) == .yesterday)
    }

    @Test func calendarDaysSurviveDaylightSavingTransitions() throws {
        var local = calendar
        local.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        for (month, day) in [(3, 8), (11, 1)] {
            let today = try #require(local.date(from: DateComponents(year: 2026, month: month, day: day, hour: 23)))
            let yesterday = try #require(local.date(byAdding: .day, value: -1, to: today))
            #expect(NoteDateGroup(date: yesterday, now: today, calendar: local) == .yesterday)
            #expect(NoteRowDateStyle(date: yesterday, now: today, calendar: local) == .yesterday)
        }
    }

}
