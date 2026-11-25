import Testing
import Foundation
import CloudKit
import SwiftData
@testable import RemarksCore

/// Spec 02, Y3 and Y4: the sync status state machine, error mapping, and the maintenance pass.
struct SyncStateTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func state(_ events: SyncEvent...) -> SyncState {
        var state = SyncState()
        events.forEach { state.apply($0) }
        return state
    }

    @Test func startsOutAsChecking() {
        #expect(SyncState().summary == .checking)
    }

    @Test func accountStatesMapToTheirSummaries() {
        #expect(state(.account(.noAccount)).summary == .signedOut)
        #expect(state(.account(.restricted)).summary == .restricted)
        #expect(state(.account(.temporarilyUnavailable)).summary == .unavailable)
        #expect(state(.account(.available)).summary == .upToDate(nil))
    }

    @Test("Each successful import adds one to the import count")
    func successfulImportsAreCounted() {
        #expect(SyncState().importCount == 0)
        let once = state(.started(.importing), .finished(.importing, at: t0, problem: nil))
        #expect(once.importCount == 1)
        let twice = state(
            .started(.importing), .finished(.importing, at: t0, problem: nil),
            .started(.importing), .finished(.importing, at: t0.addingTimeInterval(60), problem: nil)
        )
        #expect(twice.importCount == 2)
    }

    @Test("Imports that fail, exports, setup, and events that have only started are not counted")
    func otherSyncEventsAreNotCounted() {
        let state = state(
            .started(.importing), .finished(.importing, at: t0, problem: .offline),
            .started(.exporting), .finished(.exporting, at: t0, problem: nil),
            .started(.setup), .finished(.setup, at: t0, problem: nil),
            .started(.importing)
        )
        #expect(state.importCount == 0)
    }

    /// The purge deletes for good, so it may only run on a timer when no other copy can exist in iCloud.
    @Test func onlySignedOutAndRestrictedAccountsAreLocalOnly() {
        #expect(SyncAccount.noAccount.isLocalOnly)
        #expect(SyncAccount.restricted.isLocalOnly)
        #expect(!SyncAccount.available.isLocalOnly)
        #expect(!SyncAccount.temporarilyUnavailable.isLocalOnly)
        #expect(!SyncAccount.unknown.isLocalOnly)
    }

    @Test func aSignedOutAccountOutranksEverythingElse() {
        let state = state(.account(.noAccount), .network(isOnline: false), .started(.exporting))
        #expect(state.summary == .signedOut)
    }

    @Test func offlineOutranksSyncing() {
        let state = state(.account(.available), .started(.exporting), .network(isOnline: false))
        #expect(state.summary == .offline)
    }

    @Test func syncingLastsUntilEveryStartedEventFinishes() {
        var state = state(.account(.available), .started(.importing), .started(.exporting))
        #expect(state.summary == .syncing)
        state.apply(.finished(.importing, at: t0, problem: nil))
        #expect(state.summary == .syncing)
        state.apply(.finished(.exporting, at: t0.addingTimeInterval(5), problem: nil))
        #expect(state.summary == .upToDate(t0.addingTimeInterval(5)))
    }

    @Test func aFailureShowsAsAProblemAfterSyncingStops() {
        var state = state(.account(.available), .started(.exporting))
        state.apply(.finished(.exporting, at: t0, problem: .storageFull))
        #expect(state.summary == .problem(.storageFull))
    }

    @Test func aLaterSuccessClearsTheProblem() {
        var state = state(.account(.available), .started(.exporting))
        state.apply(.finished(.exporting, at: t0, problem: .storageFull))
        state.apply(.started(.exporting))
        state.apply(.finished(.exporting, at: t0.addingTimeInterval(60), problem: nil))
        #expect(state.summary == .upToDate(t0.addingTimeInterval(60)))
    }

    @Test func signingInClearsANotSignedInProblem() {
        var state = state(.account(.available), .started(.importing))
        state.apply(.finished(.importing, at: t0, problem: .notSignedIn))
        #expect(state.summary == .problem(.notSignedIn))
        state.apply(.account(.available))
        #expect(state.summary == .upToDate(nil))
    }

    @Test func comingBackOnlineClearsAnOfflineProblem() {
        var state = state(.account(.available), .started(.exporting))
        state.apply(.finished(.exporting, at: t0, problem: .offline))
        state.apply(.network(isOnline: false))
        state.apply(.network(isOnline: true))
        #expect(state.summary == .upToDate(nil))
    }

    @Test func aFinishWithoutAStartNeverGoesNegative() {
        var state = SyncState()
        state.apply(.finished(.exporting, at: t0, problem: nil))
        #expect(state.inFlight == 0)
    }

    @Test func mapsCloudKitErrorsToPlainLanguage() {
        func error(_ code: CKError.Code) -> NSError { NSError(domain: CKErrorDomain, code: code.rawValue) }
        #expect(SyncProblem.from(error(.quotaExceeded)) == .storageFull)
        #expect(SyncProblem.from(error(.notAuthenticated)) == .notSignedIn)
        #expect(SyncProblem.from(error(.networkUnavailable)) == .offline)
        #expect(SyncProblem.from(error(.networkFailure)) == .offline)
        if case .other = SyncProblem.from(error(.internalError)) {} else {
            Issue.record("An unmapped CloudKit error should fall back to .other")
        }
    }

    @Test func nonCloudKitErrorsKeepTheirMessage() {
        let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Boom"])
        #expect(SyncProblem.from(error) == .other("Boom"))
    }
}

struct MaintenanceTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeLibrary() throws -> (Library, ModelContext) {
        let container = try NotesStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        return (Library(context: context), context)
    }

    @Test func dedupeReportsWhatItMerged() throws {
        let (library, context) = try makeLibrary()
        context.insert(RemarksCore.Tag(name: "swift", now: t0))
        context.insert(RemarksCore.Tag(name: "Swift", now: t0.addingTimeInterval(1)))
        let a = Note(body: "a", now: t0)
        let b = Note(body: "b", now: t0.addingTimeInterval(5))
        context.insert(a)
        context.insert(b)
        a.id = b.id

        let report = try library.dedupe()
        #expect(report.mergedTags == 1)
        #expect(report.mergedNotes == 1)
        #expect(report.purgedNotes == 0)
        #expect(report.changedAnything)
    }

    @Test func maintenanceAlsoPurgesExpiredTrash() throws {
        let (library, _) = try makeLibrary()
        let now = t0.addingTimeInterval(100 * day)
        let old = library.createNote(body: "old", now: t0)
        let recent = library.createNote(body: "recent", now: t0)
        library.trash(old, now: now.addingTimeInterval(-31 * day))
        library.trash(recent, now: now.addingTimeInterval(-1 * day))

        let report = try library.runMaintenance(now: now)
        #expect(report.purgedNotes == 1)
        #expect(report.mergedTags == 0)
    }

    @Test func maintenanceOnACleanLibraryChangesNothing() throws {
        let (library, _) = try makeLibrary()
        library.createNote(body: "fine", now: t0)
        #expect(try library.runMaintenance(now: t0).changedAnything == false)
    }
}
