import Foundation
import SwiftData

/// A saved earlier version of a note's text (Spec 02, S1 to S4).
/// Lives in a **separate, local-only store**: never uploaded, and not part of the CloudKit schema, so it can
/// change freely without touching the permanent synced schema.
@Model
public final class NoteSnapshot {
    public var noteID: UUID = UUID()
    public var body: String = ""
    public var takenAt: Date = Date.now
    /// Why the snapshot was taken. A `SnapshotReason` raw value.
    public var reason: String = SnapshotReason.edit.rawValue

    public init(noteID: UUID, body: String, takenAt: Date, reason: SnapshotReason) {
        self.noteID = noteID
        self.body = body
        self.takenAt = takenAt
        self.reason = reason.rawValue
    }
}

public enum SnapshotReason: String, Sendable {
    case edit
    case beforeSyncUpdate
    case beforeRestore

    public var label: String {
        switch self {
        case .edit: "Saved edit"
        case .beforeSyncUpdate: "Before an update from iCloud"
        case .beforeRestore: "Before a restore"
        }
    }
}

public enum HistoryStore {
    /// A second container for snapshots. It never syncs.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([NoteSnapshot.self])
        let configuration = ModelConfiguration("History", schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}

/// When to take snapshots and which to keep.
public enum SnapshotPolicy {
    /// Ordinary edits are snapshotted at most this often per note.
    public static let minimumInterval: TimeInterval = 5 * 60
    /// The newest this many snapshots are always kept.
    public static let recentLimit = 20
    /// Beyond the newest ones, one snapshot per day is kept for this many days.
    public static let dailyDays = 14

    public static func shouldTake(lastTakenAt: Date?, lastBody: String?, newBody: String, now: Date, force: Bool = false) -> Bool {
        guard newBody != lastBody else { return false }
        if force { return true }
        guard let lastTakenAt else { return true }
        return now.timeIntervalSince(lastTakenAt) >= minimumInterval
    }

    /// The snapshots to delete: everything beyond the newest `recentLimit`, except the newest one of each
    /// calendar day within the last `dailyDays` days.
    public static func prune(_ snapshots: [NoteSnapshot], now: Date, calendar: Calendar = .current) -> [NoteSnapshot] {
        let newestFirst = snapshots.sorted { $0.takenAt > $1.takenAt }
        var keep = Set(newestFirst.prefix(recentLimit).map { ObjectIdentifier($0) })

        let cutoff = now.addingTimeInterval(-TimeInterval(dailyDays) * 24 * 60 * 60)
        var seenDays: Set<Date> = []
        for snapshot in newestFirst.dropFirst(recentLimit) where snapshot.takenAt >= cutoff {
            if seenDays.insert(calendar.startOfDay(for: snapshot.takenAt)).inserted {
                keep.insert(ObjectIdentifier(snapshot))
            }
        }
        return newestFirst.filter { !keep.contains(ObjectIdentifier($0)) }
    }
}

/// Records and reads snapshots. Used by the editor on save, and by the version history screen.
@MainActor
public final class HistoryRecorder {
    /// A context does not keep its container alive, so the recorder must hold the container itself.
    private let container: ModelContainer
    private let context: ModelContext
    /// The most recent snapshot per note, so a save does not need a fetch every time.
    private var latest: [UUID: (takenAt: Date, body: String)] = [:]

    public init(container: ModelContainer) {
        self.container = container
        self.context = container.mainContext
    }

    /// Takes a snapshot if the policy allows it. Empty text and unchanged text are never recorded.
    /// - Returns: whether a snapshot was taken.
    @discardableResult
    public func record(noteID: UUID, body: String, reason: SnapshotReason, now: Date = .now, force: Bool = false) -> Bool {
        guard !body.isEmpty else { return false }
        let last = latestSnapshot(for: noteID)
        guard SnapshotPolicy.shouldTake(lastTakenAt: last?.takenAt, lastBody: last?.body, newBody: body, now: now, force: force) else {
            return false
        }
        context.insert(NoteSnapshot(noteID: noteID, body: body, takenAt: now, reason: reason))
        latest[noteID] = (now, body)
        SnapshotPolicy.prune(snapshots(for: noteID), now: now).forEach(context.delete)
        try? context.save()
        return true
    }

    /// Newest first.
    public func snapshots(for noteID: UUID) -> [NoteSnapshot] {
        let descriptor = FetchDescriptor<NoteSnapshot>(
            predicate: #Predicate { $0.noteID == noteID },
            sortBy: [SortDescriptor(\.takenAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func latestSnapshot(for noteID: UUID) -> (takenAt: Date, body: String)? {
        if let cached = latest[noteID] { return cached }
        var descriptor = FetchDescriptor<NoteSnapshot>(
            predicate: #Predicate { $0.noteID == noteID },
            sortBy: [SortDescriptor(\.takenAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let newest = (try? context.fetch(descriptor))?.first else { return nil }
        latest[noteID] = (newest.takenAt, newest.body)
        return latest[noteID]
    }
}
