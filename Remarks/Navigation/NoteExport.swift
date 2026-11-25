import SwiftUI
import SwiftData
import RemarksCore
import UniformTypeIdentifiers

/// The ways a note can be exported. Add a case here, and to `NoteExportDocument`, to offer another format; the
/// "Export as" menu lists every case.
enum NoteExportFormat: CaseIterable, Identifiable {
    case markdown

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .markdown: "Markdown…"
        }
    }

    var systemImage: String {
        switch self {
        case .markdown: "doc.plaintext"
        }
    }
}

/// A note, and the format it is to be exported in. Equal only to itself, so asking to export the same note twice still
/// changes the binding, and comparing never has to read the note.
struct NoteExportRequest: Equatable {
    let note: Note
    let format: NoteExportFormat
    private let token = UUID()

    init(note: Note, format: NoteExportFormat) {
        self.note = note
        self.format = format
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.token == rhs.token }
}

/// A note written out as a folder: `Note name/Note name.md` and, when it has attachments, `Note name/attachments/…`.
/// Links in the exported Markdown are relative, so any Markdown app can open it (Spec 07, Export).
private struct NoteExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    static var writableContentTypes: [UTType] { [.folder] }

    let exported: ExportedNote

    init(exported: ExportedNote) {
        self.exported = exported
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var children: [String: FileWrapper] = [
            "\(exported.name).md": FileWrapper(regularFileWithContents: Data(exported.markdown.utf8)),
        ]
        if !exported.files.isEmpty {
            var files: [String: FileWrapper] = [:]
            for file in exported.files {
                files[(file.path as NSString).lastPathComponent] = FileWrapper(regularFileWithContents: file.data)
            }
            children["attachments"] = FileWrapper(directoryWithFileWrappers: files)
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }
}

/// Saves a note in the requested format. Set the binding to ask where to save it.
///
/// The files are gathered once, when the request arrives, and kept until the save panel closes. The panel writes them
/// later and off to the side, so they must not depend on the note, which can change or be deleted meanwhile.
private struct NoteExportModifier: ViewModifier {
    @Binding var request: NoteExportRequest?
    @State private var document: NoteExportDocument?
    @State private var isPresented = false
    @State private var errorMessage: String?
    /// An export that is missing attachments waits here until the person has chosen to go on without them.
    @State private var documentMissingAttachments: NoteExportDocument?
    @State private var asksAboutMissingAttachments = false

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, request in
                if let request { begin(request) }
            }
            .fileExporter(
                isPresented: $isPresented,
                document: document,
                contentType: .folder,
                defaultFilename: document?.exported.name ?? "Note"
            ) { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
            }
            .onChange(of: isPresented) { _, isPresented in
                guard !isPresented else { return }
                request = nil
                document = nil
            }
            .confirmationDialog(
                "Some Attachments Aren’t Available",
                isPresented: $asksAboutMissingAttachments,
                titleVisibility: .visible
            ) {
                Button("Export Without Them") {
                    document = documentMissingAttachments
                    documentMissingAttachments = nil
                    isPresented = true
                }
                Button("Cancel", role: .cancel) {
                    documentMissingAttachments = nil
                    request = nil
                }
            } message: {
                Text("Some attachments aren’t on this device yet. They may still be downloading from iCloud. You can export the note without them, or wait and try again.")
            }
            .onChange(of: asksAboutMissingAttachments) { _, asking in
                guard !asking, !isPresented else { return }
                documentMissingAttachments = nil
                request = nil
            }
            .alert("Couldn’t Export the Note", item: $errorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    private func begin(_ request: NoteExportRequest) {
        let note = request.note
        guard !note.isDeleted, note.modelContext != nil else {
            self.request = nil
            return
        }
        switch request.format {
        case .markdown:
            let exported = NoteExporter.export(note)
            // A link whose file is missing would be saved as a dead link, so the person decides first.
            if exported.missingAttachmentCount > 0 {
                documentMissingAttachments = NoteExportDocument(exported: exported)
                asksAboutMissingAttachments = true
                return
            }
            document = NoteExportDocument(exported: exported)
        }
        isPresented = true
    }
}

extension View {
    /// Shows a save panel for a note, in the requested format, when the binding is set.
    func noteExport(for request: Binding<NoteExportRequest?>) -> some View {
        modifier(NoteExportModifier(request: request))
    }
}
