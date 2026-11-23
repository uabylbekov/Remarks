import AppIntents
import os
import UniformTypeIdentifiers

// The App Intents for notes (Spec 06). Each one is thin: it checks its input, calls `NotesService`, and
// returns a result. `perform()` can be run again from the top, so every intent resolves its input first and
// makes its one change last. All types are `nonisolated` because this target is main-actor by default.

/// Messages Siri and Shortcuts can speak or show. A plain error would only show "something went wrong".
public enum NotesIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noteNotFound
    case noteInTrash
    case folderNotFound
    case dataUnavailable
    case attachmentTooLarge
    case tooManyAttachments
    case attachmentUnreadable
    case writerUnavailable
    case writerFailed
    case writerLanguageUnsupported

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .writerUnavailable: LocalizedStringResource("Apple Intelligence isn’t available. Turn it on in Settings, or add the text yourself.", bundle: #bundle)
        case .writerFailed: LocalizedStringResource("Apple Intelligence couldn’t write that. Try a different topic.", bundle: #bundle)
        case .writerLanguageUnsupported: LocalizedStringResource("Apple Intelligence can’t write in that language yet.", bundle: #bundle)
        case .attachmentTooLarge: LocalizedStringResource("That file is larger than 25 MB.", bundle: #bundle)
        case .tooManyAttachments: LocalizedStringResource("A note can have up to 20 attachments.", bundle: #bundle)
        case .attachmentUnreadable: LocalizedStringResource("Remarks couldn't read that file.", bundle: #bundle)
        case .dataUnavailable: LocalizedStringResource("Remarks couldn't open your notes. Open the app to see why.", bundle: #bundle)
        case .noteNotFound: LocalizedStringResource("That note no longer exists.", bundle: #bundle)
        case .noteInTrash: LocalizedStringResource("That note is in Recently Deleted. Restore it first.", bundle: #bundle)
        case .folderNotFound: LocalizedStringResource("That folder no longer exists.", bundle: #bundle)
        }
    }
}

/// Set by the app when the notes store failed to open. Intents then fail with a message instead of working on
/// the empty stand-in store the app registers so that an unregistered dependency can't crash.
public nonisolated enum NotesAvailability {
    private static let unavailable = OSAllocatedUnfairLock(initialState: false)

    public static var isUnavailable: Bool {
        get { unavailable.withLock { $0 } }
        set { unavailable.withLock { $0 = newValue } }
    }
}

/// Runs a service call and turns its errors into the spoken messages above.
private func translatingErrors<Result>(_ work: () async throws -> Result) async throws -> Result {
    if NotesAvailability.isUnavailable { throw NotesIntentError.dataUnavailable }
    do {
        return try await work()
    } catch NotesServiceError.noteNotFound {
        throw NotesIntentError.noteNotFound
    } catch NotesServiceError.noteInTrash {
        throw NotesIntentError.noteInTrash
    } catch NotesServiceError.folderNotFound {
        throw NotesIntentError.folderNotFound
    } catch NotesServiceError.attachmentFailed(let reason) {
        switch reason {
        case .tooLarge: throw NotesIntentError.attachmentTooLarge
        case .tooMany: throw NotesIntentError.tooManyAttachments
        case .unreadable: throw NotesIntentError.attachmentUnreadable
        }
    }
}

/// Files from Siri or Shortcuts as plain data, so they can cross into the notes service.
private func incomingFiles(_ files: [IntentFile]) -> [IncomingFile] {
    files.map { file in
        IncomingFile(
            data: file.data,
            fileName: file.filename,
            typeIdentifier: file.type?.identifier ?? UTType.data.identifier
        )
    }
}

/// The plain text of what Siri heard. Formatting is dropped: notes are Markdown, and Siri's text is plain.
private func plainText(_ text: AttributedString?) -> String {
    text.map { String($0.characters) } ?? ""
}

// MARK: Create

@AppIntent(schema: .notes.createNote)
public struct CreateNoteIntent {
    public static let title: LocalizedStringResource = "Create Note"
    public static let description = IntentDescription("Creates a note, in a folder if you choose one.", categoryName: "Notes")
    public static var supportedModes: IntentModes { .background }

    var name: AttributedString
    var content: AttributedString?
    var attachments: [IntentFile]
    var isPinned: Bool
    var folder: FolderEntity?

    @Dependency var service: NotesService

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let title = plainText(name)
        let text = plainText(content)
        let files = incomingFiles(attachments)
        let info = try await translatingErrors {
            try await service.createNote(text: text, title: title, folderID: folder?.id, isPinned: isPinned, attachments: files)
        }
        let dialog = IntentDialog(
            info.title.isEmpty
                ? LocalizedStringResource("Created a new note.", bundle: #bundle)
                : LocalizedStringResource("Created “\(info.title)”.", bundle: #bundle)
        )
        return .result(value: NoteEntity(info), dialog: dialog)
    }
}

// MARK: Write with Apple Intelligence

/// "Write a note about…": the on-device model writes the text, then it is saved like any other note.
/// This is separate from Create Note, which saves exactly the words it is given.
public struct WriteNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Write Note with Apple Intelligence"
    public static let description = IntentDescription(
        "Apple Intelligence writes a note about a topic and saves it. It answers from what it already knows and does not search the web, so check facts that matter.",
        categoryName: "Notes"
    )
    public static var supportedModes: IntentModes { .background }

    @Parameter(
        title: "Topic",
        requestValueDialog: IntentDialog(LocalizedStringResource("What should the note be about?", bundle: #bundle))
    )
    var topic: String

    @Parameter(title: "Folder") var folder: FolderEntity?

    public static var parameterSummary: some ParameterSummary {
        Summary("Write a note about \(\.$topic)") {
            \.$folder
        }
    }

    @Dependency var service: NotesService

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { throw $topic.needsValueError() }

        // Resolve the folder first, so a missing one fails before the slow part.
        let folderID = folder?.id
        if let folderID, try await translatingErrors({ try await service.folders(withIDs: [folderID]) }).isEmpty {
            throw NotesIntentError.folderNotFound
        }

        let text: String
        do {
            text = try await NoteWriter.write(about: topic)
        } catch NoteWriterError.unavailable {
            throw NotesIntentError.writerUnavailable
        } catch NoteWriterError.unsupportedLanguage {
            throw NotesIntentError.writerLanguageUnsupported
        } catch is CancellationError {
            // Cancelling is not a failure to write, so it should not be reported as one.
            throw CancellationError()
        } catch {
            throw NotesIntentError.writerFailed
        }

        // The one change comes last: running this again from the top only costs a second generation.
        let info = try await translatingErrors {
            try await service.createNote(text: text, folderID: folderID)
        }
        let dialog = IntentDialog(
            info.title.isEmpty
                ? LocalizedStringResource("Created a new note.", bundle: #bundle)
                : LocalizedStringResource("Created “\(info.title)”.", bundle: #bundle)
        )
        return .result(value: NoteEntity(info), dialog: dialog)
    }
}

// MARK: Add to

@AppIntent(schema: .notes.appendText)
public struct AppendToNoteIntent {
    public static let title: LocalizedStringResource = "Add to Note"
    public static let description = IntentDescription("Adds text to the end of a note.", categoryName: "Notes")
    public static var supportedModes: IntentModes { .background }

    var content: AttributedString
    var target: NoteEntity

    @Dependency var service: NotesService

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let text = plainText(content)
        let id = target.id
        let info = try await translatingErrors {
            try await service.append(text, to: id)
        }
        let dialog = IntentDialog(
            info.title.isEmpty
                ? LocalizedStringResource("Added to the note.", bundle: #bundle)
                : LocalizedStringResource("Added to “\(info.title)”.", bundle: #bundle)
        )
        return .result(value: NoteEntity(info), dialog: dialog)
    }
}

// MARK: Update

@AppIntent(schema: .notes.updateNote)
public struct UpdateNoteIntent {
    public static let title: LocalizedStringResource = "Update Note"
    public static let description = IntentDescription("Renames a note, pins it, moves it to a folder, or adds files to it.", categoryName: "Notes")
    public static var supportedModes: IntentModes { .background }

    var target: NoteEntity
    var name: AttributedString?
    var attachments: [IntentFile]?
    var isPinned: Bool?
    var folder: FolderEntity?

    @Dependency var service: NotesService

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let id = target.id
        let title = name.map { plainText($0) }
        let files = incomingFiles(attachments ?? [])
        let info = try await translatingErrors {
            try await service.update(id, title: title, isPinned: isPinned, folderID: folder?.id, attachments: files)
        }
        let dialog = IntentDialog(
            info.title.isEmpty
                ? LocalizedStringResource("Updated the note.", bundle: #bundle)
                : LocalizedStringResource("Updated “\(info.title)”.", bundle: #bundle)
        )
        return .result(value: NoteEntity(info), dialog: dialog)
    }
}

// MARK: Find and read

public struct FindNotesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Find Notes"
    public static let description = IntentDescription("Finds notes that contain every word you give.", categoryName: "Notes")
    public static var supportedModes: IntentModes { .background }

    @Parameter(title: "Search") var query: String
    @Parameter(title: "Folder") var folder: FolderEntity?
    @Parameter(title: "Limit", default: 20, inclusiveRange: (1, 100)) var limit: Int

    public static var parameterSummary: some ParameterSummary {
        Summary("Find notes matching \(\.$query)") {
            \.$folder
            \.$limit
        }
    }

    @Dependency var service: NotesService

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[NoteEntity]> {
        let scope: NoteScope = folder.map { .folder($0.id) } ?? .all
        let found = try await translatingErrors {
            try await service.search(query, scope: scope, limit: limit)
        }
        return .result(value: found.map { NoteEntity($0) })
    }
}

public struct GetNoteTextIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Note Text"
    public static let description = IntentDescription("Returns the text of a note, written in Markdown.", categoryName: "Notes")
    public static var supportedModes: IntentModes { .background }

    @Parameter(title: "Note") var note: NoteEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Get the text of \(\.$note)")
    }

    @Dependency var service: NotesService

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = try await translatingErrors { try await service.text(of: note.id) }
        return .result(value: text)
    }
}

// MARK: Open

public struct OpenNoteIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open Note"
    public static let description = IntentDescription("Opens a note in Remarks.", categoryName: "Notes")
    public static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Note") public var target: NoteEntity

    @Dependency var service: NotesService

    public init() {}
    @Dependency var router: NavigationRouter

    @MainActor
    public func perform() async throws -> some IntentResult {
        // Check first, so a deleted note says so instead of opening to nothing.
        _ = try await translatingErrors { try await service.info(for: target.id) }
        router.open(target.id)
        return .result()
    }
}

// MARK: Trash

public struct TrashNoteIntent: AppIntent, UndoableIntent {
    public static let title: LocalizedStringResource = "Move Note to Recently Deleted"
    public static let description = IntentDescription(
        "Moves a note to Recently Deleted, where you can restore it for 30 days.",
        categoryName: "Notes"
    )
    public static var supportedModes: IntentModes { .background }

    @Parameter(title: "Note") var note: NoteEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$note) to Recently Deleted")
    }

    @Dependency var service: NotesService

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        // Ask first. A cancel throws and stops here, before anything changes.
        try await requestConfirmation(dialog: IntentDialog(LocalizedStringResource("Move this note to Recently Deleted?", bundle: #bundle)))

        let id = note.id
        try await translatingErrors { try await service.trash(id) }

        // Undo puts it back.
        let service = service
        undoManager?.registerUndo(withTarget: UndoTarget.shared) { _ in
            Task {
                do {
                    try await service.restore(id)
                } catch {
                    // An undo has no way to show an error, so at least leave a record of it.
                    undoLogger.error("Could not restore a note after undo: \(error.localizedDescription)")
                }
            }
        }
        return .result(dialog: IntentDialog(LocalizedStringResource("Moved to Recently Deleted.", bundle: #bundle)))
    }
}

private let undoLogger = Logger(subsystem: "io.github.uabylbekov.remarks", category: "intents")

/// `UndoManager` needs an object to hang an undo step on.
@MainActor
private final class UndoTarget {
    static let shared = UndoTarget()
}

/// Tells the system where this framework's intents, entities, and queries are. The app lists it in its own
/// package (see `RemarksAppPackage`), because metadata for code in a framework is kept in the framework's bundle.
public struct RemarksCorePackage: AppIntentsPackage {}
