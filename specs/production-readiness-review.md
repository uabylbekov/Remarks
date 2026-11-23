# Production readiness review — 2026-11-22

Release assessment: **not ready to sign off yet**. This pass found and fixed several data-loss paths, but the iPhone test-host watchdog termination and the remaining items below need resolution or explicit acceptance before release.

This was a source-wide risk scan with focused manual review of persistence, maintenance, sync monitoring, editor save/conflict handling, attachment import/export, navigation, thumbnails, settings, and intent/service integration. Automated tests exercise additional parser, formatting, rendering, and query paths. It is not proof that every runtime path is bug-free. Existing staged and unstaged changes were preserved; no schema or signing settings were changed.

## Fixed in this pass

| Finding | Change | Validation |
| --- | --- | --- |
| Recovery copies preserved Markdown references but did not own attachment records. Cleanup or deletion of the original could leave the recovery note with missing files. | `Library.createRecoveryCopy(of:)` clones attachment records, rewrites references to independent IDs, and retains tags and reader version. `EditorSession` uses it before overwriting unseen incoming text. | New library test verifies files survive original-note deletion; editor integration test verifies incoming attachment recovery. |
| Duplicate-note cleanup cascade-deleted the losing row's attachments even when the surviving body referenced them. | Reparent distinct attachments before deleting the duplicate; fill a surviving attachment's missing payload from the duplicate when available. | Two regression tests cover attachment ownership and a payload arriving on the losing row. |
| Folder cascade deletion could remove a newer trashed child before its own retention expired, or a live child delivered by sync. | Detach children outside the deletion set before deleting their parents. Their subtrees survive at the root. | Regression tests cover expired-parent purge and Empty Trash with a live child. All 32 library tests pass. |
| Cancellation skipped maintenance sleeps and still proceeded to purge. | Propagate cancellation out of the maintenance loop and check cancellation before cleanup. | Build validation and control-flow review; no timing-based runtime test added. |
| Exported attachment links could interpret literal percent escapes in filenames as URL escapes. | Encode `%` along with Markdown delimiters and fragment markers in exported paths. | Regression test covers a filename containing `%20`, parentheses, and `#`. |
| List thumbnails did not retry after an initially missing image payload arrived; replacing the leading image could retain the old view's cached state. | Retry when payload availability changes, ignore canceled results, and give the thumbnail the attachment's identity. | Build validation; delayed CloudKit arrival and image replacement still need visual testing. |

Small cleanup: removed forced optional unwraps in checkbox layout and corrected the obsolete `TagService` comment in the schema.

## Remaining findings, ordered by release relevance

| Priority | Finding and evidence | Required follow-up |
| --- | --- | --- |
| P1 | **iPhone test-host watchdog termination.** The first full test run ended with `TEST FINISHED WITH UNKNOWN OUTCOME`; the console contains a FRONTBOARD `0x8BADF00D` termination and “test runner crashed before establishing connection.” Its main-thread stack passes through `MarkdownAccessoryView.init`, `UIInputView`, status-bar preference evaluation, and SwiftUI AttributeGraph during `NoteTextView.makeUIViewController`. | Reproduce on iPhone with an already-selected note and keyboard setup, distinguish app launch behavior from the hosted-test lifecycle, then fix and rerun the iOS suite. The stack identifies an investigation path, not a proven root cause. A subsequent Mac test pass does not close this finding. |
| P1 | **Automatic purge can run on stale offline state.** `LibraryMaintenance` in `Notes/MyApp.swift` purges after 60 seconds even if no successful import occurred. A restore performed elsewhere may not have reached this device before it permanently deletes the old local record. | Define and implement a conservative purge policy for offline/import-failure states, and test two-device restore versus expiry. A timeout is not evidence that sync completed. |
| P1 | **Attachment grace period starts at creation, not removal.** `AttachmentStore.unreferenced` in `NotesCore/Attachments.swift` compares `createdAt` with the cutoff. Removing a reference to a months-old attachment can make it eligible for the next maintenance pass immediately, despite the comment promising a grace period for undo. | Track when a reference became absent, with a sync-safe retention policy, or defer destructive collection until that policy exists. Include remove → maintenance → undo and offline-sync tests. This likely needs a deliberate model/storage design rather than a cosmetic cleanup. |
| P1 | **Service save failures retain pending mutations.** `NotesService` uses a long-lived model context, mutates it, and directly calls `save()` in create/append/trash/restore. On a thrown save, the failed operation remains dirty in that context and may be persisted by a later request. | Establish rollback or transaction handling for every mutating service operation and test injected save failures followed by another request. Preserve the editor's separate retry semantics. |
| P2 | **Reader-version protection is declared but not enforced.** `Note.minimumReaderVersion` says older readers must hide newer notes, but list predicates, `NoteFilter`, service lookups, and the detail editor do not enforce it. | Apply a shared supported-version policy to discovery and opening/editing before introducing a format that requires a newer reader. Test app, Shortcuts, and Spotlight paths. |
| P2 | **Export silently omits unavailable attachment payloads.** `NoteExporter.export` skips attachments whose `data` is nil and returns success while leaving internal attachment links in the exported Markdown. This can occur while CloudKit files are still arriving. | Surface an incomplete-export error or an explicit partial-export choice, with a pending-payload regression test. |
| P2 | **Spotlight refresh does not explicitly observe remote imports.** `SpotlightSync` observes `ModelContext.didSave`; a CloudKit import is not an explicit trigger there. Remote changes may remain absent or stale until another local save or relaunch. | Validate on two devices and add an import-triggered refresh if confirmed. Also test turning indexing off while an indexing request is in flight. |
| P2 | **Maintenance failures are silent.** `tidy` uses `try?` for both cleanup and persistence, and the first-purge flag advances even if cleanup failed. | Record actionable diagnostics and mark a purge complete only after successful persistence; avoid rolling back unrelated editor changes in the shared context. |
| P2 | **Some view tests access SceneStorage outside a mounted view.** The Mac run logs repeated warnings from `NoteListQueryTests`, including a warning that this usage will become fatal in a future release. | Mount those fixtures through an actual hosting lifecycle or test a separate state-independent view. These warnings weaken navigation/restoration coverage. |

P1 means resolve before release signoff. P2 means address or explicitly assess against the intended release scope. Findings based on static code inspection are identified as such; remote-sync and launch behavior need device evidence.

## Verification evidence

- Initial full run on Uluk’s iPhone: 357 passed, 0 assertion failures, 3 expected failures, 22 with no result; **overall outcome unknown because the test host terminated**.
- Five targeted recovery/deduplication/export regression tests: 5 passed, 0 failed. The destination can change in Xcode between tool calls; do not infer device coverage from this count alone.
- Subsequent full run on My Mac: 461 passed, 0 failed, 3 expected failures, 9 with no result. Those nine are UIKit-only tests unavailable in the Mac build, including keyboard/viewport/deletion presentation tests.
- After the folder deletion changes: all 32 library tests passed.
- Final build including test targets passed after the thumbnail and cleanup edits.
- `git diff --check` passed before the final documentation edits.
- Three expected syntax-highlighting failures remain: nested block comments, interpolation containing quotes, and JavaScript regex literals. These are documented parser limitations, not passing feature coverage.

Detailed logs from this session are under Xcode ActionArtifacts session `4033D4D2-8BB4-4F70-93DB-11DBB491A0E3`. Relevant result summaries: initial `8F760E90-99E8-4075-8ECF-DB7538622DBC`, Mac `FEF2B9D8-9348-49A0-A7CB-E35F9BCFFABC`, targeted regressions `13C69BFF-CE60-4F39-B09C-61A86723B9AE`, and library regressions `972AF529-D625-4733-B042-E8BE5F1D0DEF`.

## Release checks still outstanding

- Complete the real-device checklist with recorded outcomes, especially two-device CloudKit conflicts with attachments, restore versus expiry, offline edits, keyboard/table focus, undo after attachment removal, camera permission, and delayed file delivery.
- Test upgrading an on-disk library from the actual previous build; in-memory fixtures do not validate migration compatibility. The workspace includes existing schema changes.
- Build and inspect a distribution archive, including provisioning-derived push/iCloud entitlements, CloudKit production schema deployment, and privacy manifest/required-reason API declarations. The source entitlements alone do not prove the signed distribution entitlements.
- Test Siri/Shortcuts and Spotlight while the app is closed, open, indexing-disabled, and after remote edits.
- Validate accessibility and large text on device, and measure launch/memory/large-library behavior before making performance claims. This pass did not perform an accessibility audit or an Instruments profile.

No archive upload, CloudKit schema deployment, or external publication was performed.
