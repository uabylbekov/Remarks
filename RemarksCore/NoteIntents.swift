import AppIntents

// The App Intents for notes (Spec 06). Each one is thin: it checks its input, calls `NotesService`, and
// returns a result. `perform()` can be run again from the top, so every intent resolves its input first and
// makes its one change last. All types are `nonisolated` because this target is main-actor by default.

/// Messages Siri and Shortcuts can speak or show. A plain error would only show "something went wrong".
public enum NotesIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noteNotFound
    case noteInTrash
    case folderNotFound

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noteNotFound: LocalizedStringResource("That note no longer exists.", bundle: #bundle)
        case .noteInTrash: LocalizedStringResource("That note is in Recently Deleted. Restore it first.", bundle: #bundle)
        case .folderNotFound: LocalizedStringResource("That folder no longer exists.", bundle: #bundle)
        }
    }
}

/// Runs a service call and turns its errors into the spoken messages above.
private func translatingErrors<Result>(_ work: () async throws -> Result) async throws -> Result {
    do {
        return try await work()
    } catch NotesServiceError.noteNotFound {
        throw NotesIntentError.noteNotFound
    } catch NotesServiceError.noteInTrash {
        throw NotesIntentError.noteInTrash
    } catch NotesServiceError.folderNotFound {
        throw NotesIntentError.folderNotFound
    }
}

public enum AppendPlacement: String, AppEnum {
    // Raw values are saved in people's shortcuts. Add cases at the end; never change or reorder these.
    case end
    case start

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Position")
    public static let caseDisplayRepresentations: [AppendPlacement: DisplayRepresentation] = [
        .end: "At the End",
        .start: "At the Start",
    ]

    public var position: AppendPosition {
        self == .end ? .end : .start
    }
}

// MARK: Create

public struct CreateNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Create Note"
    public static let description = IntentDescription("Creates a note, in a folder if you choose one.", categoryName: "Notes")
    public static var supportedModes: IntentModes { .background }

    @Parameter(title: "Text") var text: String
    @Parameter(title: "Title") var noteTitle: String?
    @Parameter(title: "Folder") var folder: FolderEntity?

    public static var parameterSummary: some ParameterSummary {
        Summary("Create a note with \(\.$text)") {
            \.$noteTitle
            \.$folder
        }
    }

    @Dependency var service: NotesService

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let info = try await translatingErrors {
            try await service.createNote(text: text, title: noteTitle, folderID: folder?.id)
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

public struct AppendToNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add to Note"
    public static let description = IntentDescription("Adds text to the start or end of a note.", categoryName: "Notes")
    public static var supportedModes: IntentModes { .background }

    @Parameter(title: "Note") var note: NoteEntity
    @Parameter(title: "Text") var text: String
    @Parameter(title: "Position", default: .end) var placement: AppendPlacement

    public static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$note)") {
            \.$placement
        }
    }

    @Dependency var service: NotesService

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let info = try await translatingErrors {
            try await service.append(text, to: note.id, at: placement.position)
        }
        let dialog = IntentDialog(
            info.title.isEmpty
                ? LocalizedStringResource("Added to the note.", bundle: #bundle)
                : LocalizedStringResource("Added to “\(info.title)”.", bundle: #bundle)
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
        return .result(value: found.map(NoteEntity.init))
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
            Task { try? await service.restore(id) }
        }
        return .result(dialog: IntentDialog(LocalizedStringResource("Moved to Recently Deleted.", bundle: #bundle)))
    }
}

/// `UndoManager` needs an object to hang an undo step on.
@MainActor
private final class UndoTarget {
    static let shared = UndoTarget()
}

/// Tells the system where this framework's intents, entities, and queries are. The app lists it in its own
/// package (see `RemarksAppPackage`), because metadata for code in a framework is kept in the framework's bundle.
public struct RemarksCorePackage: AppIntentsPackage {}
