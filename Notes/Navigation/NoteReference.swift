import CoreTransferable
import UniformTypeIdentifiers

/// What is dragged when a note is picked up in the list: only its id. A folder in the sidebar accepts it and moves the
/// note there.
struct NoteReference: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .noteReference)
    }
}

extension UTType {
    /// Declared in Info.plist (`UTExportedTypeDeclarations`).
    static let noteReference = UTType(exportedAs: "io.github.uabylbekov.notes.note-reference")
}
