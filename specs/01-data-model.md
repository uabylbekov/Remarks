# Spec 01: Data Model and Storage

Status: **Approved 2026-11-19** (all six recommended decisions accepted: tag entity, 30-day trash, unlimited folder depth with a warning past 5, stored `title`/`snippet`, no `isLocked` yet, single `body` field for v1). Decision 6 stays conditional on the conflict spike. Milestone: M0.
Depends on: `00-product-plan.md`, `00-open-questions.md` (A3, A4, B4, B8, B15).

## Why this spec is high-stakes

The CloudKit production schema is **additive only**: after release you cannot delete or rename record types or fields. A mistake here is permanent. Everything below is designed so the schema can grow but never needs to shrink.

## Goals

1. Store notes, folders, and tags in SwiftData, synced through the CloudKit private database (container `iCloud.io.github.uabylbekov.remarks`).
2. Make the model satisfy every CloudKit restriction from day one.
3. Keep model logic in a UI-free `NotesCore` package that the app, App Intents, widgets, and a future MCP server share.
4. Keep Markdown text as the only source of truth for note content.

## Non-goals

Attachments (Spec 07), locked notes (Spec 08), sharing (out of scope), and full-text search design (Spec 04). The schema leaves room for them without restructuring.

## What the docs say (design constraints)

| Constraint | Source finding | Consequence here |
|---|---|---|
| No unique constraints under CloudKit | SwiftData sync docs | Uniqueness of `id` and tag names is enforced by services plus a dedupe job, not by the store |
| All relationships optional, with inverses | SwiftData and Core Data CloudKit docs | Every relationship below is `Optional` with an explicit inverse |
| No `.deny` delete rule | Same | Use `.nullify` or `.cascade` only |
| Changes arrive in indeterminate order | Same | Never assume a parent exists when a child arrives. Handle orphans |
| Production schema is additive only | Same | Versioning rules below. Never repurpose a field |
| Record size limit 1 MB (assets excluded) | CloudKit record docs | Large `String` and `Data` values are converted to assets automatically by Core Data mirroring, so a long note body is handled. Verify in a spike |
| 256 fields per record type | TN3164 | Far below the limit |
| Many-to-many relationships are stored as separate join records | Core Data CloudKit record docs | Note-to-tag has a small sync cost per link. Accepted |
| Every attribute needs a default or must be optional | SwiftData CloudKit practice | All attributes below have defaults |
| `PersistentIdentifier` is temporary until first save | SwiftData docs | Never persist it. Use our own `id: UUID` |

## Entities

All properties have defaults. `id` is assigned once at creation and never changes.

### `Note`

| Property | Type | Default | Notes |
|---|---|---|---|
| `id` | `UUID` | `UUID()` | Stable across devices and launches. This is the `AppEntity` id for App Intents. Not unique-constrained (see above) |
| `body` | `String` | `""` | The Markdown. **Only source of truth for content** |
| `title` | `String` | `""` | Derived: first non-empty line, stripped of Markdown marks. Rebuilt by the model on every body change. Safe to overwrite on conflict |
| `snippet` | `String` | `""` | Derived: first ~200 characters after the title, for list rows. Same rules as `title` |
| `createdAt` | `Date` | `.now` | |
| `modifiedAt` | `Date` | `.now` | Set by the model whenever `body`, `folder`, or `isPinned` changes |
| `isPinned` | `Bool` | `false` | |
| `deletedAt` | `Date?` | `nil` | Non-nil means in Recently Deleted. See "Deletion" |
| `minimumReaderVersion` | `Int` | `1` | Older app versions must ignore notes whose value exceeds what they understand (Apple's documented versioning strategy). Raised only when a note uses a format older apps cannot render |
| `folder` | `Folder?` | `nil` | Inverse: `Folder.notes`. Delete rule on the folder side: `.nullify` |
| `tags` | `[Tag]?` | `nil` | Inverse: `Tag.notes` |

### `Folder`

| Property | Type | Default | Notes |
|---|---|---|---|
| `id` | `UUID` | `UUID()` | |
| `name` | `String` | `""` | |
| `createdAt` | `Date` | `.now` | |
| `sortIndex` | `Double` | `0` | Manual ordering. A `Double` lets us insert between two items without renumbering (fewer synced writes) |
| `deletedAt` | `Date?` | `nil` | Same trash semantics as `Note` |
| `parent` | `Folder?` | `nil` | Inverse: `Folder.children` |
| `children` | `[Folder]?` | `nil` | Delete rule `.cascade` (service moves content to trash first, so nothing is lost silently) |
| `notes` | `[Note]?` | `nil` | Delete rule `.nullify` |

Virtual folders **All Notes**, **Unfiled**, and **Recently Deleted** are queries, not stored entities.

### `Tag`

| Property | Type | Default | Notes |
|---|---|---|---|
| `id` | `UUID` | `UUID()` | |
| `name` | `String` | `""` | Stored as typed. Compared case- and diacritic-insensitively |
| `createdAt` | `Date` | `.now` | |
| `notes` | `[Note]?` | `nil` | Inverse: `Note.tags`. Delete rule `.nullify` |

## Rules the model must enforce itself

1. **Derived fields:** `title`, `snippet`, and `modifiedAt` are updated inside the model (a single `setBody(_:)` entry point plus observers), never by views. This guarantees every entry point (UI, Siri intent, widget, import) produces consistent rows.
2. **Duplicates:** because the store cannot enforce uniqueness, a `DedupeService` runs at launch and after sync imports:
   - Two `Tag`s with the same normalized name: merge into the older one, relink notes, delete the other.
   - Two rows with the same `id` (possible after a rare sync race): keep the one with the later `modifiedAt`.
3. **Orphans:** a note whose `folder` is `nil` is **Unfiled**, not an error. A folder whose `parent` points at a missing folder is shown at the top level.
4. **Cycles:** moving a folder under its own descendant is rejected by the service. Sync could still deliver one, so tree walks must be cycle-safe.
5. **Normalization:** trim tag names. Reject empty names.

## Deletion

- Deleting a note or folder sets `deletedAt` (soft delete). It shows under Recently Deleted.
- Items are purged **30 days** after `deletedAt` by a background job in `NotesCore`. Purging is a real delete and syncs.
- Restoring clears `deletedAt` (and restores a missing parent folder to Unfiled).
- Deleting a folder soft-deletes its subtree and notes together so restore is consistent.

## Body size

- `body` is a plain `String`. Per the Core Data CloudKit docs, variable-length strings over the record limit are stored as assets automatically. **Verify** this holds for SwiftData with a 2 MB test note in the sync spike.
- Soft limit: warn at 1,000,000 characters. Hard limits are not needed unless the spike finds a failure.
- Keep large derived data (search indexes, parsed trees) **out** of the synced store. Rebuild locally.

## Versioning and migration

1. The first shipped schema is `SchemaV1: VersionedSchema` with a `NotesMigrationPlan: SchemaMigrationPlan`, even though it has one stage. This makes every later change a stage instead of a retrofit.
2. **Allowed changes after release (additive):** add a new property with a default, add a new entity, add an optional relationship.
3. **Forbidden after release:** deleting or renaming a property or entity, changing a property's type, making an optional required, reusing an old name for new meaning.
4. To "remove" something, stop reading it and leave the field in the schema forever.
5. Gate features that older apps cannot render with `minimumReaderVersion`, so older devices leave the note alone rather than corrupt it. `NoteFormat.supportedReaderVersion` is the highest value this build understands, and `Note.isReadable` compares against it. A build leaves a note it cannot read untouched:
   - The app lists it with its title and date and the line "Needs a newer version of Remarks". Opening it shows "Update Required" instead of the editor. Its actions menu leaves out Export. Pin, Move to, Tags, and Delete still work, because they only change fields every version understands.
   - Siri, Shortcuts, Spotlight, and search through `NotesService` never return it, and changing it fails with a spoken message.
   - Maintenance never treats its attachments as unreferenced, because its text may refer to them in a way this build cannot see.
   - Raise `supportedReaderVersion` only together with the code that reads the new format. The check protects only builds that contain it, so it has to ship before the first format that needs version 2.
6. Before any schema release: initialize the development schema (`initializeCloudKitSchema` in DEBUG builds), inspect it in the CloudKit Console, then promote it to production. This is a manual checklist item in the release spec.

## Architecture (MV layering)

```
NotesCore (local Swift package, no UI imports)
├── Models          @Model: Note, Folder, Tag, SchemaV1, NotesMigrationPlan
├── Store           makeContainer(inMemory:) -> ModelContainer (CloudKit private DB on; off for tests)
├── Services        @ModelActor actors: NoteService, FolderService, TagService, DedupeService, PurgeService
└── Markdown        title extraction, block scanner (shared with the editor)

Notes (app target)
└── SwiftUI views   @Query for reads, @Environment(\.modelContext) for simple writes; NoteService for anything with rules above
```

- **Isolation:** the project defaults to `MainActor`. `NotesCore` is a separate package, so it sets its own default and its pure logic is `nonisolated`.
- **Cross-actor rule:** never pass `@Model` instances between actors. Pass `Note.id` (a `UUID`) and re-fetch with a predicate.
- **Container creation:** one factory so the app, intents, and tests build identical containers. Tests use in-memory with `cloudKitDatabase: .none`.
- **Container discovery:** SwiftData uses the first iCloud container found in the entitlements. We have exactly one. Pass it explicitly anyway so a later second container cannot change behavior silently.
- **App Group:** not needed yet. When widgets or extensions arrive (M4), SwiftData can move the store into a group container. Per Apple's sample, a store from a version without an app group is copied into the group container on upgrade. Verify that behavior with CloudKit enabled before shipping widgets.

## Acceptance criteria

1. A `ModelContainer` builds with CloudKit sync enabled and no schema errors, on macOS and iOS.
2. In DEBUG, `initializeCloudKitSchema` succeeds, and the CloudKit Console shows `CD_Note`, `CD_Folder`, and `CD_Tag` with the expected fields.
3. Unit tests (in-memory store):
   - Creating a note sets `id`, `title`, `snippet`, `createdAt`, and `modifiedAt` correctly for empty, single-line, multi-line, emoji, and fenced-code bodies.
   - `setBody` updates derived fields and `modifiedAt`. Changing `isPinned` or `folder` updates `modifiedAt`.
   - Dedupe merges duplicate tags and keeps the newest of duplicate IDs.
   - Moving a folder under its descendant is rejected. A synced cycle does not hang tree walks.
   - Soft delete, restore, and purge behave per "Deletion", including subtree handling.
   - Orphaned notes appear under Unfiled.
4. A V1 to V2 migration test exists with a trivial additive V2 (new property with default). It passes, which proves the migration pipeline works before we need it.
5. A 2 MB note round-trips through the store, and (during the sync spike) through CloudKit.
6. Two devices create the same tag name offline. After sync and dedupe, one tag remains, and all notes keep their tag.

## Decisions to confirm before implementation

| # | Question | My recommendation | Why it matters |
|---|---|---|---|
| 1 | Tags as an entity (this spec) or a plain `[String]` on `Note` | Entity | Allows rename and later colors. Cost: a join record per link. A `[String]` is simpler but cannot be renamed globally without touching every note |
| 2 | Trash retention | 30 days | Apple Notes uses 30 days. Longer costs storage and sync, shorter risks data loss |
| 3 | Folder nesting | Unlimited depth, UI warns past 5 | Apple Notes supports subfolders. A hard limit is a one-way door once users build deep trees |
| 4 | Store `title` and `snippet` (derived, synced) or compute at read time | Store | Needed for fast sorted lists and Spotlight. They are overwritable derived data, so conflicts are harmless. Cost: two extra synced fields per edit |
| 5 | Include `isLocked` now | **Not now.** Add additively in Spec 08 | Adding a field with a default later is safe, and the design of locking is undecided |
| 6 | One `body` field or split into blocks | One field for v1 | Simplest. Conflict handling depends on the two-device sync spike (Spec 02). If conflicts prove destructive, revisit before release, not after |

## Risks

1. Single `body` field means a conflict on two devices editing the same note can lose one side's text. Mitigated by the conflict spike and a conflicted-copy safeguard (Spec 02).
2. Dedupe runs after sync imports. The exact hook (history tracking or remote-change notification) must be confirmed for SwiftData.
3. `@Model` observers and derived-field updates run on every keystroke path if mis-wired. Debounce body writes from the editor (Spec 03) rather than saving per character.
