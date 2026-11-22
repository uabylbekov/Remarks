import SwiftUI
import NotesCore
import UniformTypeIdentifiers

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

/// Saves a note as Markdown plus its attachments. Set the binding to a note to ask where to save it.
private struct NoteExportModifier: ViewModifier {
    @Binding var note: Note?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        // Reads every attachment, so it is built once per update, not once for the document and again for the name.
        let exported = note.map(NoteExporter.export)
        return content
            .fileExporter(
                isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } }),
                document: exported.map(NoteExportDocument.init),
                contentType: .folder,
                defaultFilename: exported?.name ?? "Note"
            ) { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
            }
            .alert("Couldn’t Export the Note", item: $errorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }
}

extension View {
    /// Shows a save panel for a note, as a Markdown file with its attachments, when the binding is set.
    func noteExport(for note: Binding<Note?>) -> some View {
        modifier(NoteExportModifier(note: note))
    }
}
