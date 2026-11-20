import Testing
import Foundation
import SwiftData
@testable import NotesCore

// MARK: - Title and snippet (Spec 01 acceptance criterion 3)

struct DerivedCase: Sendable, CustomTestStringConvertible {
    let name: String
    let body: String
    let title: String
    let snippet: String

    var testDescription: String { name }
}

struct NoteTextTests {
    static let cases: [DerivedCase] = [
        DerivedCase(name: "empty", body: "", title: "", snippet: ""),
        DerivedCase(name: "single line", body: "Hello", title: "Hello", snippet: ""),
        DerivedCase(name: "heading then lines", body: "# Heading\nBody one\nBody two", title: "Heading", snippet: "Body one Body two"),
        DerivedCase(name: "blank lines and a task box first", body: "\n\n  - [ ] todo item\nmore", title: "todo item", snippet: "more"),
        DerivedCase(name: "ordered list and quote marks", body: "1. First\n> quoted", title: "First", snippet: "quoted"),
        DerivedCase(name: "fence markers skipped, code kept", body: "```swift\nlet x = 1\n```\nAfter", title: "let x = 1", snippet: "After"),
        DerivedCase(name: "tilde fence", body: "~~~\ncode\n~~~\nAfter", title: "code", snippet: "After"),
        DerivedCase(name: "emoji", body: "😀 Party\nsecond line", title: "😀 Party", snippet: "second line"),
        DerivedCase(name: "heading marks only", body: "###\nReal title", title: "Real title", snippet: ""),
        DerivedCase(name: "hash inside text is kept", body: "C# is fun", title: "C# is fun", snippet: ""),
    ]

    @Test(arguments: cases)
    func derivesTitleAndSnippet(_ testCase: DerivedCase) {
        let derived = NoteText.derive(from: testCase.body)
        #expect(derived.title == testCase.title)
        #expect(derived.snippet == testCase.snippet)
    }

    @Test func capsTitleAndSnippetLength() {
        let long = String(repeating: "a", count: 500)
        let derived = NoteText.derive(from: "\(long)\n\(long)")
        #expect(derived.title.count == NoteText.maxTitleLength)
        #expect(derived.snippet.count == NoteText.maxSnippetLength)
    }
}

// MARK: - Model rules (Spec 01 acceptance criterion 3)

struct NoteModelTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    @Test func newNoteSetsIdentityDatesAndDerivedFields() {
        let note = Note(body: "# Title\nbody", now: t0)
        #expect(note.title == "Title")
        #expect(note.snippet == "body")
        #expect(note.createdAt == t0)
        #expect(note.modifiedAt == t0)
        #expect(note.deletedAt == nil)
        #expect(note.minimumReaderVersion == 1)
        #expect(note.folder == nil)
    }

    @Test func setBodyUpdatesDerivedFieldsAndModifiedAt() {
        let note = Note(body: "Old", now: t0)
        note.setBody("# New title\ntext", now: t1)
        #expect(note.body == "# New title\ntext")
        #expect(note.title == "New title")
        #expect(note.snippet == "text")
        #expect(note.modifiedAt == t1)
        #expect(note.createdAt == t0)
    }

    @Test func settingTheSameBodyDoesNotTouchModifiedAt() {
        let note = Note(body: "Same", now: t0)
        note.setBody("Same", now: t1)
        #expect(note.modifiedAt == t0)
    }

    @Test func pinningAndMovingUpdateModifiedAt() {
        let note = Note(body: "x", now: t0)
        note.setPinned(true, now: t1)
        #expect(note.isPinned)
        #expect(note.modifiedAt == t1)

        let later = Date(timeIntervalSince1970: 3_000)
        let folder = Folder(name: "Work", now: t0)
        note.move(to: folder, now: later)
        #expect(note.folder?.id == folder.id)
        #expect(note.modifiedAt == later)
    }

    @Test func pinningToTheSameValueIsANoOp() {
        let note = Note(body: "x", now: t0)
        note.setPinned(false, now: t1)
        #expect(note.modifiedAt == t0)
    }
}

// MARK: - Schema and store

struct StoreTests {
    @Test func entityNamesMatchTheCloudKitSchemaWeSpiked() {
        let names = NotesStore.schema.entities.map(\.name).sorted()
        #expect(names == ["Folder", "Note", "Tag"])
    }

    @Test func inMemoryContainerRoundTripsANote() throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let note = Note(body: "# Saved\nline")
        context.insert(note)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Note>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Saved")
        #expect(fetched.first?.id == note.id)
    }

    @Test func noteWithoutAFolderIsUnfiled() throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        context.insert(Note(body: "orphan"))
        try context.save()

        let unfiled = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.folder == nil }))
        #expect(unfiled.count == 1)
    }

    @Test func notesLinkToTagsBothWays() throws {
        let container = try NotesStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let note = Note(body: "tagged")
        let tag = Tag(name: "swift")
        context.insert(note)
        context.insert(tag)
        note.tags = [tag]
        try context.save()

        #expect(tag.notes?.count == 1)
        #expect(tag.notes?.first?.id == note.id)
    }
}
