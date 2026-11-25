# Spec 02: Sync

Status: **Approved to build (2026-11-19)**, with open risks noted below. Milestone: M0 (plumbing), M1 (status UI).
Depends on: Spec 01 (data model), `spikes/03-sync-spike.md`.

## Goals

1. Notes, folders, and tags sync automatically between a person's devices through their private iCloud database, at no cost to them or us.
2. The app is **fully usable offline and while signed out of iCloud**. Sync is an enhancement, never a prerequisite.
3. Sync problems are visible and explainable, never silent.

## What the spike showed (2026-11-19)

| Finding | Evidence | Confidence |
|---|---|---|
| Notes sync between Mac and iPhone | User-run, both directions | Good |
| A 2 MB `body` string synced from iPhone to Mac | User-run. Matching character counts and clean logs not individually confirmed | Moderate |
| Two devices appended to the same note while verified offline (edit log said `OFFLINE`); after reconnecting, **all four stamps survived on both devices** | One verified run | **Low.** Mechanism unexplained, contrary to what the docs lead one to expect |
| Not run: replace vs. append (T3), other reconnect orders, more edits, duplicate tags (T5), tag relationships (T6), delete vs. edit (T7) | User chose to skip further sync testing to start building | Open risk |

**Consequence:** we build on a single `body` field (Spec 01 decision 6), but we do not assume conflicts can never lose text. The safety net below is how we cover that gap.

## Requirements

### Behavior

| ID | Requirement |
|---|---|
| Y1 | Use SwiftData with an explicit `ModelConfiguration(cloudKitDatabase: .private("iCloud.io.github.uabylbekov.notes"))`. One shared factory in `NotesCore` creates the container |
| Y2 | The app works with no iCloud account, no network, and iCloud restricted. Data stays local and syncs later |
| Y3 | Sync status is visible: account state, "syncing", "up to date at HH:MM", and errors with a plain-language explanation |
| Y4 | After every **import** that finishes, run the dedupe pass from Spec 01 (duplicate tags and duplicate IDs) |
| Y5 | When the iCloud account changes or the user signs out, tell the user what will happen to their data before anything is removed. **Verify** the exact platform behavior (the mirrored store may be purged on account change) and design the message from the result |
| Y6 | Appearance settings sync through `NSUbiquitousKeyValueStore` (Spec 11). They do not use the notes store |
| Y7 | Large bodies: warn at 1,000,000 characters (Spec 01). If sync of a large note fails, show the note as "not synced" instead of hiding the error |

### Safety net against silent loss (S)

| ID | Requirement |
|---|---|
| S1 to S4 | **Dropped (2026-11-21).** The app no longer keeps local note snapshots or a Version History screen. Apple Notes has none, and Recently Deleted covers deleted notes |

**Decision (2026-11-21):** Version History was removed (the `HistoryStore`, `HistoryRecorder`, `VersionHistoryView`, and the menu item). The safety net against silent loss is now: a note open in the editor never has typed text replaced by an incoming change, and an untouched editor follows the incoming change (`EditorSync`). If you typed while another device changed the same note, **your text wins and the other device's version is not kept**. Revisit this if sync conflicts turn out to lose text in practice.

## Built so far

| ID | What | Status |
|---|---|---|
| Y1 | Explicit CloudKit container via `NotesStore.makeContainer` | Done (M0) |
| Y2 | Works with no account or network | Design holds; verified by use of the app offline in the spike |
| Y3 | Sync status bar in the sidebar (signed out, offline, syncing, up to date, storage full, other problems), with a tap for the full explanation | Done. State machine unit-tested. Live wiring needs device testing |
| Y4 | Duplicate tags and notes are merged after every finished import | Done. Cleanup logic tested. Trigger needs device testing |
| Y5 | Account change or sign-out explanation before data changes | **Not built.** Platform behavior still unverified |
| Y6 | Settings through `NSUbiquitousKeyValueStore` | Not built (Spec 11) |
| Y7 | Large note "not synced" warning | Not built |
| Purge | Items 30 days in Recently Deleted are deleted for good, at most once a day. iCloud is the source of truth: with an iCloud account the purge only follows a successful import, never a timer, so an offline device cannot delete from stale state. Signed out or restricted accounts (`SyncAccount.isLocalOnly`) have no other copy, so a timer runs the purge instead. A failed pass is retried | Rule tested. Wiring in `MyApp.swift` needs device testing |
| Schema | `-InitializeCloudKitSchema` launch argument (DEBUG only) runs `initializeCloudKitSchema` before the container opens | Written and compiles. **Not yet run on a device** |

## Release checklist: CloudKit schema (do once before the first TestFlight or App Store build)

1. In the CloudKit Console, **Reset Development Environment** for `iCloud.io.github.uabylbekov.notes`, to remove the spike's throwaway records and record types.
2. In Xcode, edit the Notes scheme, Run, Arguments, and add `-InitializeCloudKitSchema`.
3. Run a **debug** build on a device signed into iCloud. Watch the console for `CloudKit schema initialized.`
4. Remove the launch argument.
5. In the CloudKit Console, development environment, confirm `CD_Note`, `CD_Folder`, and `CD_Tag` exist with every field, including `deletedAt`.
6. **Deploy Schema Changes to Production.** After this the schema is additive-only.
7. Archive and test a build that uses the production environment (TestFlight) on two devices before any wider release.

### Observability

- Observe `NSPersistentCloudKitContainer.eventChangedNotification` (setup, import, export, with start and end times and errors). The spike's log showed these events arrive reliably.
- Check account state with `CKContainer.accountStatus()` at launch and when `CKAccountChanged` is posted.
- Show connectivity with `NWPathMonitor` only as information. Sync itself must not depend on it.

## Schema lifecycle (release checklist)

1. In DEBUG, call `initializeCloudKitSchema` (see the SwiftData sync docs) so every field exists up front. The spike did not, so optional fields never set (such as `deletedAt`) may not exist yet.
2. Inspect `CD_Note`, `CD_Folder`, and `CD_Tag` in the CloudKit Console, development environment.
3. Promote the development schema to production **before** any TestFlight or App Store build.
4. After promotion the schema is additive-only (Spec 01 rules).
5. The spike created throwaway data in the development environment. Reset the development environment before the first real schema initialization.

## Acceptance criteria

1. With iCloud signed in: a note created on device A appears on device B within about a minute, and the status UI shows both sides.
2. With iCloud signed out: every feature works, and the status UI says why sync is off.
3. Airplane mode: edits persist and sync after reconnecting.
4. After sync, no duplicate tags (same normalized name) remain.
5. A 2 MB note round-trips between two devices with equal length.
6. An import that changes the body of a note that is open and being typed in never replaces the typed text.
7. Account sign-out and account change show a clear explanation before data changes.

## Open risks

1. **Unexplained merge:** the spike's clean merge may not hold in other timings. Mitigation: the editor keeps typed text over incoming text, and a later regression test with scripted two-device runs. With Version History removed, a lost incoming edit is not recoverable.
2. **Account change behavior** (Y5) is unverified.
3. **Dedupe timing:** running after import events is assumed to be early enough. Verify no UI flicker of duplicates.
4. **Development schema** may not contain fields that were never set until `initializeCloudKitSchema` runs.
