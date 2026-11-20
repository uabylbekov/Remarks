import SwiftUI
import SwiftData
import NotesCore

/// Earlier versions of one note, kept on this device only (Spec 02, S3). Restoring keeps the current text as a
/// version first, so a restore can itself be undone.
struct VersionHistoryView: View {
    let note: Note

    @Environment(\.history) private var history
    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [NoteSnapshot] = []

    var body: some View {
        NavigationStack {
            Group {
                if snapshots.isEmpty {
                    ContentUnavailableView(
                        "No Earlier Versions",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Versions appear here as you edit. They stay on this device and are never uploaded.")
                    )
                } else {
                    List(snapshots) { snapshot in
                        NavigationLink {
                            SnapshotDetail(note: note, snapshot: snapshot, onRestored: { dismiss() })
                        } label: {
                            SnapshotRow(snapshot: snapshot)
                        }
                    }
                }
            }
            .navigationTitle("Version History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { snapshots = history?.snapshots(for: note.id) ?? [] }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }
}

private struct SnapshotRow: View {
    let snapshot: NoteSnapshot

    private var preview: String {
        let firstLine = snapshot.body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return String(firstLine.prefix(80))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.takenAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
            Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                Text(SnapshotReason(rawValue: snapshot.reason)?.label ?? "Saved edit")
                Text("·")
                Text("\(snapshot.body.count) characters")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SnapshotDetail: View {
    let note: Note
    let snapshot: NoteSnapshot
    let onRestored: () -> Void

    @Environment(\.history) private var history
    @State private var confirmsRestore = false

    var body: some View {
        ScrollView {
            Text(snapshot.body)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(snapshot.takenAt.formatted(date: .abbreviated, time: .shortened))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: snapshot.body) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Restore") { confirmsRestore = true }
            }
        }
        .confirmationDialog("Restore this version?", isPresented: $confirmsRestore, titleVisibility: .visible) {
            Button("Restore") { restore() }
        } message: {
            Text("The current text is kept as a version, so you can go back.")
        }
    }

    private func restore() {
        history?.record(noteID: note.id, body: note.body, reason: .beforeRestore, force: true)
        note.setBody(snapshot.body)
        onRestored()
    }
}

#Preview("Version history") {
    let notes = (try? NotesStore.makeContainer(inMemory: true)) ?? { fatalError("in-memory container failed") }()
    let historyContainer = (try? HistoryStore.makeContainer(inMemory: true)) ?? { fatalError("history container failed") }()
    let recorder = HistoryRecorder(container: historyContainer)
    let note = Note(body: "# Launch plan\nShip the editor, then the sidebar, then sync status.")
    notes.mainContext.insert(note)
    let now = Date.now
    recorder.record(noteID: note.id, body: "# Launch plan\nShip the editor.", reason: .edit, now: now.addingTimeInterval(-7_200))
    recorder.record(noteID: note.id, body: "# Launch plan\nShip the editor, then the sidebar.", reason: .edit, now: now.addingTimeInterval(-3_600))
    recorder.record(noteID: note.id, body: "# Launch plan (older copy)\nShip it.", reason: .beforeSyncUpdate, now: now.addingTimeInterval(-600), force: true)
    return VersionHistoryView(note: note)
        .modelContainer(notes)
        .environment(\.history, recorder)
}

private struct VersionHistorySheet: ViewModifier {
    @Binding var note: Note?

    func body(content: Content) -> some View {
        content.sheet(item: $note) { VersionHistoryView(note: $0) }
    }
}

extension View {
    /// Shows a note's version history in a sheet when the binding is set.
    func versionHistorySheet(for note: Binding<Note?>) -> some View {
        modifier(VersionHistorySheet(note: note))
    }
}
