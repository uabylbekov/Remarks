import SwiftUI
import NotesCore

/// Plain-language wording for each sync state (Spec 02, Y3).
extension SyncSummary {
    var title: String {
        switch self {
        case .checking: "Checking iCloud…"
        case .signedOut, .problem(.notSignedIn): "Not syncing"
        case .restricted: "iCloud is restricted"
        case .unavailable: "iCloud unavailable"
        case .offline, .problem(.offline): "Offline"
        case .syncing: "Syncing…"
        case .problem(.storageFull): "iCloud storage is full"
        case .problem(.other): "Sync problem"
        case .upToDate: "Synced"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "Looking for your iCloud account."
        case .signedOut, .problem(.notSignedIn):
            "Your notes are saved on this device. Sign in to iCloud in Settings to sync them with your other devices."
        case .restricted:
            "iCloud is restricted on this device, for example by Screen Time or a device profile. Your notes are saved on this device."
        case .unavailable:
            "iCloud is temporarily unavailable. Your notes are safe on this device and will sync when it is back."
        case .offline, .problem(.offline):
            "You are offline. Your changes are saved on this device and will sync when you reconnect."
        case .syncing:
            "Sending and receiving changes with iCloud."
        case .problem(.storageFull):
            "Your iCloud storage is full, so new changes can't sync. Your notes are safe on this device. Free up space or upgrade your iCloud storage in Settings."
        case .problem(.other(let message)):
            "Your notes are safe on this device. iCloud reported: \(message)"
        case .upToDate(let date):
            if let date {
                "Last synced \(date.formatted(.relative(presentation: .named)))."
            } else {
                "iCloud sync is on."
            }
        }
    }

    var symbol: String {
        switch self {
        case .checking, .syncing: "arrow.triangle.2.circlepath"
        case .signedOut, .problem(.notSignedIn), .restricted: "icloud.slash"
        case .unavailable, .problem(.storageFull), .problem(.other): "exclamationmark.icloud"
        case .offline, .problem(.offline): "wifi.slash"
        case .upToDate: "checkmark.icloud"
        }
    }

    var tint: Color {
        switch self {
        case .upToDate: .green
        case .checking, .syncing: .secondary
        case .signedOut, .problem(.notSignedIn), .restricted, .offline, .problem(.offline): .orange
        case .unavailable, .problem(.storageFull), .problem(.other): .red
        }
    }
}

extension EnvironmentValues {
    /// The bottom safe area of the whole window (the home indicator), measured outside the navigation container.
    /// Unlike the safe area inside a column, it does not change when a toolbar, such as the note list's search
    /// field, appears or goes away, so a footer placed with it stays still while navigating.
    @Entry var deviceBottomInset: CGFloat = 0
}

/// The sync status as quiet, centered grey text at the bottom of the sidebar, with no icon and no container:
/// the state ("Synced", "Syncing…", "Offline") and, under it, when it last synced. Tap for the full explanation.
struct SyncStatusFooter: View {
    @Environment(SyncMonitor.self) private var monitor
    @State private var showsDetail = false

    var body: some View {
        let summary = monitor.state.summary
        let lastSuccess = monitor.state.lastSuccess
        Button {
            showsDetail = true
        } label: {
            // Refreshes once a minute, so "2 minutes ago" does not go stale while the app stays open.
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                VStack(spacing: 2) {
                    Text(summary.title)
                    if let lastSuccess {
                        Text("Last synced \(lastSuccess.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.footnote)
                .foregroundStyle(summary.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(summary, lastSuccess))
        .accessibilityHint("Shows details")
        .popover(isPresented: $showsDetail) {
            VStack(alignment: .leading, spacing: 8) {
                Label(summary.title, systemImage: summary.symbol)
                    .font(.headline)
                    .foregroundStyle(.primary, summary.tint)
                Text(summary.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(minWidth: 260, maxWidth: 320, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func accessibilityText(_ summary: SyncSummary, _ lastSuccess: Date?) -> String {
        guard let lastSuccess else { return "iCloud sync: \(summary.title)" }
        return "iCloud sync: \(summary.title). Last synced \(lastSuccess.formatted(.relative(presentation: .named)))"
    }
}

extension SyncSummary {
    /// States where something needs attention. Only these leave the quiet grey.
    var isProblem: Bool {
        switch self {
        case .problem, .unavailable, .restricted: true
        case .checking, .signedOut, .offline, .syncing, .upToDate: false
        }
    }
}

#Preview("Synced") {
    var state = SyncState()
    state.apply(.account(.available))
    state.apply(.finished(.exporting, at: .now.addingTimeInterval(-5 * 60), problem: nil))
    return SyncStatusFooter().environment(SyncMonitor(showing: state)).frame(width: 260)
}

#Preview("Offline") {
    var state = SyncState()
    state.apply(.account(.available))
    state.apply(.finished(.importing, at: .now.addingTimeInterval(-3 * 3600), problem: nil))
    state.apply(.network(isOnline: false))
    return SyncStatusFooter().environment(SyncMonitor(showing: state)).frame(width: 260)
}
