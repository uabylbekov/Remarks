import Foundation
import CloudKit

/// The iCloud account, as the app needs to understand it.
public enum SyncAccount: Sendable, Equatable {
    case unknown, available, noAccount, restricted, temporarilyUnavailable

    /// iCloud is not in use, so this device holds the only copy of the library. Anything else may still have
    /// newer changes in iCloud that have not arrived yet.
    public var isLocalOnly: Bool {
        self == .noAccount || self == .restricted
    }
}

/// What went wrong, in terms a person can act on.
public enum SyncProblem: Sendable, Equatable {
    case storageFull
    case notSignedIn
    case offline
    case other(String)

    /// Maps a CloudKit or Core Data error to a plain-language problem.
    public static func from(_ error: Error) -> SyncProblem {
        let nsError = error as NSError
        if nsError.domain == CKErrorDomain, let code = CKError.Code(rawValue: nsError.code) {
            switch code {
            case .quotaExceeded: return .storageFull
            case .notAuthenticated: return .notSignedIn
            case .networkUnavailable, .networkFailure: return .offline
            default: break
            }
        }
        return .other(error.localizedDescription)
    }
}

public enum SyncKind: Sendable, Equatable {
    case setup, importing, exporting
}

/// Something that happened, reported by CloudKit, the account, or the network.
public enum SyncEvent: Sendable, Equatable {
    case account(SyncAccount)
    case network(isOnline: Bool)
    case started(SyncKind)
    case finished(SyncKind, at: Date, problem: SyncProblem?)
}

/// What the status display shows, in priority order.
public enum SyncSummary: Sendable, Equatable {
    case checking
    case signedOut
    case restricted
    case unavailable
    case offline
    case syncing
    case problem(SyncProblem)
    case upToDate(Date?)
}

/// A pure state machine for the sync status (Spec 02, Y3). It has no CloudKit calls of its own,
/// so every case can be unit tested. `SyncMonitor` feeds it real events.
public struct SyncState: Sendable, Equatable {
    public private(set) var account: SyncAccount = .unknown
    public private(set) var isOnline = true
    public private(set) var inFlight = 0
    public private(set) var lastSuccess: Date?
    public private(set) var lastProblem: SyncProblem?

    public init() {}

    public mutating func apply(_ event: SyncEvent) {
        switch event {
        case .account(let newAccount):
            account = newAccount
            if newAccount == .available, lastProblem == .notSignedIn { lastProblem = nil }

        case .network(let online):
            isOnline = online
            if online, lastProblem == .offline { lastProblem = nil }

        case .started:
            inFlight += 1

        case .finished(_, let date, let problem):
            inFlight = max(0, inFlight - 1)
            if let problem {
                lastProblem = problem
            } else {
                lastSuccess = date
                lastProblem = nil
            }
        }
    }

    public var summary: SyncSummary {
        switch account {
        case .noAccount: return .signedOut
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .unavailable
        case .unknown, .available: break
        }
        if !isOnline { return .offline }
        if inFlight > 0 { return .syncing }
        if let lastProblem { return .problem(lastProblem) }
        if account == .unknown && lastSuccess == nil { return .checking }
        return .upToDate(lastSuccess)
    }
}
