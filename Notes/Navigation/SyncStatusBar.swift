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
        case .upToDate: "Up to date"
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

/// The sync status as a standard sidebar row: a `Label` with a tinted iCloud symbol, and a popover for details.
struct SyncStatusButton: View {
    @Environment(SyncMonitor.self) private var monitor
    @State private var showsDetail = false

    var body: some View {
        let summary = monitor.state.summary
        Button {
            showsDetail = true
        } label: {
            Label {
                Text(summary.title)
            } icon: {
                Image(systemName: summary.symbol)
                    .foregroundStyle(summary.tint)
                    .symbolEffect(.rotate, isActive: summary == .syncing)
            }
            .font(.footnote)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("iCloud sync: \(summary.title)")
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
}
