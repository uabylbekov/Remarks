import Foundation

/// When the permanent deletion of Recently Deleted items may run (Spec 02). It holds the decisions only; the app
/// supplies the clock, the account, and the actual purge.
public struct PurgeSchedule: Sendable, Equatable {
    /// A purge reads every note and snapshot, so it runs at most this often.
    public static let interval: TimeInterval = 24 * 60 * 60

    public private(set) var lastPurge: Date?

    public init() {}

    public func isDue(at now: Date) -> Bool {
        lastPurge.map { now.timeIntervalSince($0) >= Self.interval } ?? true
    }

    public mutating func didPurge(at now: Date) {
        lastPurge = now
    }

    /// With an iCloud account the purge follows an import, never a timer: the device may be offline, and its copy
    /// may lack a restore made elsewhere. A timer is only safe when this device holds the only copy.
    public static func timerMayPurge(account: SyncAccount) -> Bool {
        account.isLocalOnly
    }
}
