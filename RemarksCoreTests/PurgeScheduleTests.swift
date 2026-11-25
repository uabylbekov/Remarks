import Testing
import Foundation
@testable import RemarksCore

/// Spec 02: when the permanent deletion of Recently Deleted items may run.
struct PurgeScheduleTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func aLibraryThatNeverPurgedIsDue() {
        #expect(PurgeSchedule().isDue(at: t0))
    }

    @Test func aPurgeJustDoneIsNotDueAgain() {
        var schedule = PurgeSchedule()
        schedule.didPurge(at: t0)
        #expect(!schedule.isDue(at: t0.addingTimeInterval(PurgeSchedule.interval - 1)))
    }

    @Test func aPurgeIsDueOnceADayHasPassed() {
        var schedule = PurgeSchedule()
        schedule.didPurge(at: t0)
        #expect(schedule.isDue(at: t0.addingTimeInterval(PurgeSchedule.interval)))
    }

    @Test func aTimerMayOnlyPurgeWhenThisDeviceHoldsTheOnlyCopy() {
        #expect(PurgeSchedule.timerMayPurge(account: .noAccount))
        #expect(PurgeSchedule.timerMayPurge(account: .restricted))
        #expect(!PurgeSchedule.timerMayPurge(account: .available))
        #expect(!PurgeSchedule.timerMayPurge(account: .temporarilyUnavailable))
        #expect(!PurgeSchedule.timerMayPurge(account: .unknown))
    }
}
