# Spec 06: App Intents and Spotlight

Status: **Draft v0.2 (2026-11-19). D1 and D2 decided; ready to build in the order below.** Milestone: M3.
Depends on: Spec 01 (data model), Spec 02 (sync), Spec 03 (editor), Spec 04 (organization, `NoteFilter`).
Source of the API rules below: Apple's App Intents guidance for the iOS 26 and 27 SDKs (execution model, entities and queries, dependencies, execution modes).

## Status of the build (2026-11-19)

| Step | State |
|---|---|
| 1. `NotesService` (`@ModelActor`) | Done. 30 tests (create, append, find, trash, restore, search, paging, conditions) |
| 2. Editor conflict fix | Done in code, with the decision logic tested (`EditorSync`, 8 tests). **Not yet tried on a device** |
| 3. Entities and queries | Done: `NoteEntity`, `FolderEntity`, and their queries (`EntityPropertyQuery` and `EntityStringQuery` for notes) |
| 4. Create, Add to, Find, Get Note Text | Done |
| 5. Open Note, Trash Note | Done. Open goes through `NavigationRouter`; Trash confirms first and registers Undo |
| 6. App Shortcuts and phrases | Done: four shortcuts (Create, Add to, Find, Open). The build extracted all of them |
| 7. Spotlight indexing and the Settings switch (D1) | **Not built yet** |

**Where the code lives.** The intents and entities are in `NotesCore`, not the app target. The app target is main-actor by default, which conflicts with App Intents and produced about 30 warnings; the framework is not, and this is how Apple's own sample is organized. `NotesCorePackage` and the app's `NotesAppPackage` (an `AppIntentsPackage` pair) tell the system where to find them. Only the `AppShortcutsProvider` stays in the app. A future widget or Siri extension can reuse the same framework.

**Differences from the draft above:** the Trash intent's spoken confirmation uses the system confirmation, and Find Notes takes an optional folder plus a limit (1 to 100, default 20). `Find Notes where…` filters by title, modified date, pinned, folder name, and tag; sorting is by title, modified date, or pinned.

**Not verified:** nothing here has run through Siri, Shortcuts, or `AppIntentsTesting` yet. Only the metadata extraction and the underlying service are checked.

## Goal

Siri, Shortcuts, Spotlight, and Apple Intelligence can **create, append to, find, read, open, and trash notes** without the app being open. The same service layer is what the future MCP server (Spec 10) will call, so none of the note logic lives in the intents themselves.

## Principles

1. **Intents are thin.** Each intent validates input, calls `NotesService` (in `NotesCore`), and returns a result. The rules (trash, folder, tag, dedupe, snapshots) stay in `Library`, as they are now.
2. **Intents run cold.** Siri can launch the app's process and call `perform()` without any view appearing. Everything an intent needs is created in `App.init()`.
3. **Spotlight is on by default, and the user can turn it off.** Only titles and snippets are indexed, never the full text (see Decisions).
4. **No irreversible work in an intent without a way back.** Trashing is recoverable (Recently Deleted). Permanent deletion and Empty Trash are **not** exposed.
5. **A stable contract.** Intent type names, `AppEntity.id` values, and shortcut phrases are saved in people's shortcuts. After release they are only added to, never renamed.

## Decisions

| # | Question | Decision |
|---|---|---|
| D1 | Are notes searchable in Spotlight and visible to Apple Intelligence? | **Decided (2026-11-19): on by default, like Apple Notes.** A Settings switch turns indexing off, and turning it off removes everything from the index. Only titles, snippets, folder, and tags are indexed |
| D2 | Are intents part of the paid unlock? | **Decided (2026-11-19): all free in v1.** Revisit gating in Spec 09 once the trial limits are set |
| D3 | Can Siri trash a note? | **Proposed: yes, with a confirmation and Undo.** Permanent delete is never available |
| D4 | Locked or hidden notes | **Not applicable yet.** If notes can be locked later, they must never appear in intents or the index |

## Architecture

```text
Intent (app target)  ->  NotesService (NotesCore, @ModelActor)  ->  Library -> SwiftData (CloudKit)
                                          ^
MCP server (later), widgets (later) ------+
```

- **`NotesService`** is a `@ModelActor` in `NotesCore` (this finishes task T11b). It owns its own `ModelContext`, so intents never touch the main context or any UI object. It exposes plain, `Sendable` values (`NoteInfo`: id, title, snippet, modified date, folder name, tags), never `@Model` objects.
- **Registration.** `MyApp.init()` builds the container, then registers the service with `AppDependencyManager.shared.add(dependency:)`. An unregistered `@Dependency` is a `fatalError`, and `@Dependency` only works on intents and queries, not on entities or enums.
- **Where intents run.** In the **app's own process** for v1 (no App Intents extension), so no App Group is needed. A widget or share extension later will need the App Group store (B8). Intents use the default execution target, which lets the system choose.
- **Foreground only for Open.** Everything else declares `supportedModes = .background`. Open Note uses `.foreground(.immediate)`.

## Entities

| Entity | `id` | `@Property` (visible to the system) | Notes |
|---|---|---|---|
| `NoteEntity` | `Note.id` (a `UUID` that is minted once, stored with the note, and the same on every device) | `title`, `snippet`, `modifiedAt`, `folder` name, `isPinned`, `tags` | `displayRepresentation` shows the title and the snippet |
| `FolderEntity` | `Folder.id` | `name`, `noteCount` | For "add to the Work folder" |
| `TagEntity` | `Tag.id` | `name` | Phase 2 |

The note **body** is not a `@Property` of `NoteEntity` (it can be 1 MB). It is returned only by the Get Note Text intent.

### Queries

- `NoteEntityQuery` conforms to **`EntityPropertyQuery`** and **`EntityStringQuery`**, not `EnumerableEntityQuery`, because the library can hold thousands of notes and `EnumerableEntityQuery` loads all of them.
  - `entities(for:)` resolves all ids in **one** fetch. Missing ids are simply omitted.
  - `suggestedEntities()` returns the 20 most recently modified notes. Cheap and bounded.
  - `entities(matching:)` and the property comparators run through the existing `NoteFilter` (case and accent insensitive, all words). The framework does not filter for us, so we call it.
  - Properties offered to Shortcuts "Find Notes where…": title, modified date, pinned, folder, tag.
- Trashed notes are never returned by default queries.

## Intents (v1)

| Intent | Parameters | Result | Mode | Notes |
|---|---|---|---|---|
| **Create Note** | `text`, optional `title`, optional `folder` | `NoteEntity` plus a dialog | background | Title is taken from the first line if not given. Empty text is allowed and creates an empty note |
| **Add to Note** | `note`, `text`, `position` (end or start) | `NoteEntity` | background | See the editor conflict below |
| **Find Notes** | search text, scope (all, folder, tag) | `[NoteEntity]` | background | Also provided automatically by `EntityPropertyQuery` |
| **Get Note Text** | `note` | the Markdown text (a `String`) | background | The main hook for Apple Intelligence and Shortcuts |
| **Open Note** | `note` | none | foreground | An `OpenIntent`. Navigation goes through one `@MainActor` router that the app registers as a dependency |
| **Trash Note** | `note` | none | background | `UndoableIntent`, with `requestConfirmation` **before** trashing. Moves to Recently Deleted |

Execution rules that apply to all of them:
- `perform()` is not main-actor isolated. Only Open Note hops to the main actor, for navigation.
- `perform()` can be run again from the top. Each intent first resolves and validates every parameter, then does the one write **last**. Create Note writes once at the end; Add to Note is not idempotent by nature, so it checks for a value request before writing.
- Errors conform to `CustomLocalizedStringResourceConvertible`, so Siri speaks a real message ("That note is in Recently Deleted").
- User-facing strings are literal `LocalizedStringResource` values.

### App Shortcuts (spoken phrases)

Each phrase includes `\(.applicationName)` (a phrase without it is silently dropped), with a short title and an SF Symbol:
- "Create a note in `\(.applicationName)`"
- "Add to a note in `\(.applicationName)`"
- "Find notes in `\(.applicationName)`"
- "Open a note in `\(.applicationName)`"

Phrases are a public contract after release: add, don't rename.

## The editor conflict (a risk in the current code)

`Add to Note` changes `Note.body` while the same note may be open and focused in the editor. Today the editor ignores incoming body changes while focused, and then `flushSave()` writes `textView.text` back, **silently overwriting the appended text**. Sync has the same hole: a remote edit that arrives while you type can be lost without a version being kept.

Required fix (part of this milestone, tested):
1. The editor remembers the last body it saved or loaded (`baseBody`).
2. When the note's stored body changes while the editor is focused:
   - if the editor's text equals `baseBody` (nothing typed yet), load the new body;
   - otherwise keep the typed text, **save the incoming body as a version** ("Before an update from iCloud" or "Before an intent change"), and tell the user with a non-blocking message ("Another change was saved to Version History").
3. `flushSave()` records the body it is about to replace as a snapshot when it differs from `baseBody`.

This also closes the S2 gap noted in Spec 02 for open notes.

## Spotlight and Apple Intelligence (on by default, with a switch, decision D1)

- `NoteEntity` conforms to `IndexedEntity`. Indexed fields: title, snippet, folder, tags. The full body is **not** indexed in v1.
- Implement `IndexedEntityQuery` so the system can ask for a reindex.
- A Settings switch ("Show notes in Spotlight", default on) turns it off. When it is off, delete the entities from the index and stop indexing new ones.
- Entities map to Spotlight fields with `@Property(indexingKey:)` or `@ComputedProperty`.
- Note text is only handed to Apple Intelligence through the **Get Note Text** intent, one note at a time, when the person asks.

## Not in v1

Tags as entities, creating folders by voice, Visual Intelligence, interactive snippets, on-screen entity annotation (so "summarize this note" while a note is open), `RelevantEntities`, and cross-device entity syncing. Each can be added later without changing the contract above. On-screen annotation is the most valuable follow-up.

## Testing

| What | How |
|---|---|
| `NotesService` (create, append, find, trash, paging) | Swift Testing, in-memory `ModelContainer`, in `NotesCoreTests` |
| Query behavior (ids resolved in one fetch, missing ids omitted, ranking) | Same, against `NoteFilter` |
| Editor conflict fix | Unit tests on the pure decision (`baseBody`, typed text, incoming body) in `NotesCore` |
| The intents end to end | `AppIntentsTesting` (iOS 27) runs them out-of-process against the installed app. Needs a device or simulator build; add after the first working build |
| Siri phrases, Shortcuts editor, Spotlight | Manual on a device |

## Build order

1. `NotesService` (`@ModelActor`) with tests. Finishes T11b.
2. The editor conflict fix, with tests.
3. `NoteEntity`, `NoteEntityQuery`, `FolderEntity`.
4. Create Note, Add to Note, Find Notes, Get Note Text. Dependency registration in `MyApp.init()`.
5. Open Note with the router, then Trash Note.
6. App Shortcuts and phrases.
7. Spotlight indexing and the Settings switch (D1).

## Acceptance criteria

1. From a cold start, "Create a note in Notes" through Siri or Shortcuts creates a note that appears in the app and syncs.
2. Add to Note on a note that is open and being typed in loses nothing. The incoming text is kept in Version History.
3. Find Notes with 5,000 notes returns in well under a second and loads only the matches.
4. No intent can permanently delete data.
5. With the Spotlight setting off, Spotlight shows nothing from the app. With it on (the default), titles and snippets appear in Spotlight.
6. Every intent works with no iCloud account and offline (Spec 02, Y2).
7. VoiceOver and Siri read results (title and snippet) rather than IDs.

## Open risks

1. The `@ModelActor` context and the main context see each other's saves, but timing is not verified with CloudKit mirroring on a device.
2. Cold launch time: building the container in `App.init()` must be fast enough for Siri's time limit. Measure.
3. `EntityPropertyQuery` comparators map to `NoteFilter` only partly (dates, pinned, folder, tag need new filter cases).
