import Foundation
import CloudKit
import CoreData
import Network
import Observation

/// Watches iCloud and turns what it sees into `SyncState` events (Spec 02, Y3 and Y4).
/// - Account status, checked at launch and whenever the account changes.
/// - CloudKit setup, import, and export events from the SwiftData store.
/// - Connectivity, for information only: sync itself never depends on it.
@MainActor
@Observable
public final class SyncMonitor {
    public private(set) var state = SyncState()

    /// Called after every successful import from iCloud. The app uses it to clean up duplicates.
    @ObservationIgnored public var onImportFinished: (@MainActor () -> Void)?

    @ObservationIgnored private let containerID: String
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    public init(containerID: String = NotesStore.cloudKitContainerID) {
        self.containerID = containerID
    }

    /// A monitor that shows a given state and never talks to CloudKit. For previews and tests.
    public convenience init(showing state: SyncState) {
        self.init()
        self.state = state
    }

    public func start() {
        guard tasks.isEmpty else { return }
        tasks = [
            Task { await self.observeCloudKitEvents() },
            Task { await self.observeAccount() },
        ]
        startNetworkMonitor()
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func receive(_ event: SyncEvent) {
        state.apply(event)
    }

    // MARK: CloudKit events

    private func observeCloudKitEvents() async {
        let name = NSPersistentCloudKitContainer.eventChangedNotification
        for await notification in NotificationCenter.default.notifications(named: name) {
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { continue }

            let kind: SyncKind
            switch event.type {
            case .setup: kind = .setup
            case .import: kind = .importing
            case .export: kind = .exporting
            @unknown default: continue
            }

            if let end = event.endDate {
                let problem = event.error.map(SyncProblem.from)
                receive(.finished(kind, at: end, problem: problem))
                if kind == .importing, problem == nil { onImportFinished?() }
            } else {
                receive(.started(kind))
            }
        }
    }

    // MARK: Account

    private func observeAccount() async {
        await refreshAccount()
        for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
            await refreshAccount()
        }
    }

    private func refreshAccount() async {
        let account: SyncAccount
        do {
            switch try await CKContainer(identifier: containerID).accountStatus() {
            case .available: account = .available
            case .noAccount: account = .noAccount
            case .restricted: account = .restricted
            case .temporarilyUnavailable: account = .temporarilyUnavailable
            case .couldNotDetermine: account = .unknown
            @unknown default: account = .unknown
            }
        } catch {
            account = .unknown
        }
        receive(.account(account))
    }

    // MARK: Network

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.receive(.network(isOnline: online)) }
        }
        monitor.start(queue: DispatchQueue(label: "notes.sync.network"))
        pathMonitor = monitor
    }
}
