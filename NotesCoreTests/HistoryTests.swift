import Testing
import Foundation
import SwiftData
@testable import NotesCore

/// Spec 02, S1 to S4: local snapshots as a safety net against lost edits.
struct SnapshotPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let minute: TimeInterval = 60
    private let day: TimeInterval = 24 * 60 * 60

    @Test func theFirstSnapshotIsAlwaysTaken() {
        #expect(SnapshotPolicy.shouldTake(lastTakenAt: nil, lastBody: nil, newBody: "x", now: t0))
    }

    @Test func unchangedTextIsNeverSnapshotted() {
        #expect(!SnapshotPolicy.shouldTake(lastTakenAt: t0, lastBody: "x", newBody: "x", now: t0.addingTimeInterval(day)))
        #expect(!SnapshotPolicy.shouldTake(lastTakenAt: t0, lastBody: "x", newBody: "x", now: t0.addingTimeInterval(day), force: true))
    }

    @Test func ordinaryEditsWaitFiveMinutes() {
        #expect(!SnapshotPolicy.shouldTake(lastTakenAt: t0, lastBody: "a", newBody: "b", now: t0.addingTimeInterval(4 * minute)))
        #expect(SnapshotPolicy.shouldTake(lastTakenAt: t0, lastBody: "a", newBody: "b", now: t0.addingTimeInterval(5 * minute)))
    }

    @Test func aForcedSnapshotIgnoresTheInterval() {
        #expect(SnapshotPolicy.shouldTake(lastTakenAt: t0, lastBody: "a", newBody: "b", now: t0.addingTimeInterval(1), force: true))
    }

    // MARK: Pruning

    private func makeSnapshots(count: Int, spacing: TimeInterval, endingAt end: Date) -> [NoteSnapshot] {
        let id = UUID()
        return (0..<count).map { index in
            NoteSnapshot(noteID: id, body: "v\(index)", takenAt: end.addingTimeInterval(-Double(index) * spacing), reason: .edit)
        }
    }

    @Test func fewSnapshotsAreAllKept() {
        let snapshots = makeSnapshots(count: 20, spacing: 600, endingAt: t0)
        #expect(SnapshotPolicy.prune(snapshots, now: t0).isEmpty)
    }

    @Test func beyondTheNewestTwentyOnlyOnePerDayIsKept() {
        // 25 snapshots, 10 minutes apart: all on one day. The newest 20 stay, plus the newest of the other 5.
        let snapshots = makeSnapshots(count: 25, spacing: 600, endingAt: t0)
        let doomed = SnapshotPolicy.prune(snapshots, now: t0)
        #expect(doomed.count == 4)
        let newestTwenty = Set(snapshots.sorted { $0.takenAt > $1.takenAt }.prefix(20).map { ObjectIdentifier($0) })
        #expect(doomed.allSatisfy { !newestTwenty.contains(ObjectIdentifier($0)) })
    }

    @Test func oldSnapshotsBeyondTheDailyWindowAreRemoved() {
        var snapshots = makeSnapshots(count: 20, spacing: 60, endingAt: t0)
        let id = snapshots[0].noteID
        let ancient = NoteSnapshot(noteID: id, body: "old", takenAt: t0.addingTimeInterval(-30 * day), reason: .edit)
        let recentDay = NoteSnapshot(noteID: id, body: "yesterday", takenAt: t0.addingTimeInterval(-2 * day), reason: .edit)
        snapshots += [ancient, recentDay]

        let doomed = SnapshotPolicy.prune(snapshots, now: t0)
        #expect(doomed.count == 1)
        #expect(doomed.first === ancient)
    }
}

@MainActor
struct HistoryRecorderTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRecorder() throws -> HistoryRecorder {
        HistoryRecorder(container: try HistoryStore.makeContainer(inMemory: true))
    }

    @Test func recordsAndListsNewestFirst() throws {
        let recorder = try makeRecorder()
        let id = UUID()
        #expect(recorder.record(noteID: id, body: "one", reason: .edit, now: t0))
        #expect(recorder.record(noteID: id, body: "two", reason: .edit, now: t0.addingTimeInterval(600)))

        let bodies = recorder.snapshots(for: id).map(\.body)
        #expect(bodies == ["two", "one"])
    }

    @Test func skipsEmptyUnchangedAndTooFrequentSnapshots() throws {
        let recorder = try makeRecorder()
        let id = UUID()
        #expect(!recorder.record(noteID: id, body: "", reason: .edit, now: t0))
        #expect(recorder.record(noteID: id, body: "a", reason: .edit, now: t0))
        #expect(!recorder.record(noteID: id, body: "a", reason: .edit, now: t0.addingTimeInterval(3_600)))
        #expect(!recorder.record(noteID: id, body: "b", reason: .edit, now: t0.addingTimeInterval(60)))
        #expect(recorder.snapshots(for: id).count == 1)
    }

    @Test func aForcedSnapshotIsTakenImmediately() throws {
        let recorder = try makeRecorder()
        let id = UUID()
        recorder.record(noteID: id, body: "local text", reason: .edit, now: t0)
        #expect(recorder.record(noteID: id, body: "text before sync overwrote it", reason: .beforeSyncUpdate, now: t0.addingTimeInterval(1), force: true))
        #expect(recorder.snapshots(for: id).first?.reason == SnapshotReason.beforeSyncUpdate.rawValue)
    }

    @Test func notesDoNotShareHistory() throws {
        let recorder = try makeRecorder()
        let a = UUID(), b = UUID()
        recorder.record(noteID: a, body: "A text", reason: .edit, now: t0)
        recorder.record(noteID: b, body: "B text", reason: .edit, now: t0)
        #expect(recorder.snapshots(for: a).map(\.body) == ["A text"])
        #expect(recorder.snapshots(for: b).map(\.body) == ["B text"])
    }

    @Test func recordingKeepsOnlyTheNewestTwentyPlusOnePerDay() throws {
        let recorder = try makeRecorder()
        let id = UUID()
        for index in 0..<30 {
            recorder.record(noteID: id, body: "v\(index)", reason: .edit, now: t0.addingTimeInterval(Double(index) * 600))
        }
        // 30 recorded on one day: the newest 20 plus one survivor from the rest.
        #expect(recorder.snapshots(for: id).count == 21)
        #expect(recorder.snapshots(for: id).first?.body == "v29")
    }
}
