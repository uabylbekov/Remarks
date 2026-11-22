# M0 Tasks: Foundations

Status: In progress (started 2026-11-19). Specs: 01 (data model), 02 (sync), `00-platform-design.md`.

**Exit criteria (from the plan):** project structure in place, `NotesCore` with SwiftData models, CloudKit container configured, and notes sync between two devices.

Spikes already proved basic sync between a Mac and an iPhone (`spikes/03-sync-spike.md`). M0 turns those throwaways into real structure.

## Tasks

Legend: [x] done, [ ] to do.

### Structure
- [x] T1. `NotesCore` multiplatform framework target, embedded in the app
- [x] T2. `NotesCoreTests` target (Swift Testing)
- [x] T3. `NotesCore` build settings: supported platforms iOS and macOS only, `nonisolated` default isolation. (Deployment target left at the template default, still to confirm it is 27.x)

### Models and store
- [x] T4. `Note`, `Folder`, `Tag` per Spec 01 in `NotesCore`, with `setBody`, `setPinned`, and `move` keeping derived fields and `modifiedAt` consistent. Derived properties use `private(set)`
- [x] T5. `SchemaV1: VersionedSchema` (models nested in the schema version) and `NotesMigrationPlan`
- [x] T6. `NotesStore.makeContainer(inMemory:syncsWithCloudKit:)` with the explicit CloudKit container
- [x] T7. `NoteText.derive`: Markdown-aware title and snippet

### Services (implemented as `Library`, a struct over a `ModelContext`)
- [x] T8. Notes: create, trash, restore, unfiled query
- [x] T9. Folders: create with `sortIndex`, cycle-safe move, trash and restore of a subtree
- [x] T10. Tags and dedupe: normalized find-or-create, merge duplicate tags, resolve duplicate note IDs
- [x] T11. Purge items trashed 30 days or more
- [x] T11b. `NotesService`, a `@ModelActor` for work off the main actor (App Intents, and later MCP). The purge schedule still runs on the main context

### Tests (Spec 01 acceptance criteria 3 and 4)
- [x] T12. Derived fields: empty, single-line, multi-line, emoji, fenced code, tilde fences, heading marks
- [x] T13. `setBody`, `isPinned`, and `folder` changes update `modifiedAt`; same-value writes are no-ops
- [x] T14. Dedupe merges duplicate tags, relinks notes, and keeps the newest duplicate note
- [x] T15. Folder cycle rejection and cycle-safe tree walk
- [x] T16. Soft delete, restore, purge, and subtree behavior
- [x] T17. Orphaned notes appear as Unfiled
- [ ] T18. V1 to V2 migration test with a trivial additive V2 (needs a test-only schema pair and an on-disk store)

**Test status:** 34 of 34 passing (macOS).

### App integration
- [x] T19. Removed the sync spike models and lab from the app (they duplicated `NotesCore`'s entity names)
- [x] T20. App builds its container with `NotesStore.makeContainer()` and shows a minimal notes list: create, select, edit as plain text, swipe to trash. A DEBUG toolbar button opens the editor spikes
- [x] T21. Launch screen setting added (`INFOPLIST_KEY_UILaunchScreen_Generation = YES`)

### Remaining M0 work
- [x] T22. Sync status model and sidebar status bar (Spec 02 Y3). `SyncState` tested. `SyncMonitor` needs device testing
- [x] T23. Dedupe after each finished CloudKit import (Spec 02 Y4)
- [x] T24. Purge at launch and daily
- [x] T25. DEBUG `initializeCloudKitSchema` helper (`-InitializeCloudKitSchema` launch argument) and the release checklist in Spec 02. Not yet run on a device
- [x] T25b. ~~Local version history (Spec 02 S1, S3, S4, and S2 for open notes)~~ Removed 2026-11-21
- [ ] T26. Confirm `NotesCore` deployment targets are 27.x
- [ ] T27. Verify on devices that the existing spike data loads into the new container (same entity names) and that new notes still sync between the Mac and iPhone
- [ ] T28. Create the CloudKit development schema reset plan (throwaway spike records)
