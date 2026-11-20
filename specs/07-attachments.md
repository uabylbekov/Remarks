# Spec 07: Attachments

Status: **Built 2026-11-20, except export and paste (see the table below). Scope: images and any file, shown as a file chip you can open.** Milestone: M4 (brought forward at your request).
Depends on: Spec 01 (data model, additive schema), Spec 02 (sync), Spec 03 (editor), `00-open-questions.md` (B3 export, B5 large blobs).

## Status of the build (2026-11-20)

| Step | State |
|---|---|
| Schema: `Attachment` model, `Note.attachments` | Done, **in place in `SchemaV1`** (not a V2 with a migration), because the app is not released. An existing development store may fail to open after this change: delete the app (or the simulator's data) once. Add a proper V2 stage before the first release |
| `AttachmentStore` (limits, downscale, Markdown, cleanup) | Done, 16 tests |
| Cleanup of unreferenced attachments after 30 days | Done, part of the daily maintenance pass |
| Markdown form, title and snippet | Done. The list shows the attachment's name, not the link |
| Editor: inline images, file chips, "Waiting for iCloud…" and "Missing attachment" states | Done, checked in previews on iPhone and Mac. The line height depends only on the attachment, never on the caret |
| Insert: photo library, camera, files, drag and drop of files | Done. Paperclip menu in the Mac toolbar and on the iPhone keyboard bar. **Not verified on a device** |
| Open: Quick Look on iPhone and iPad | Done. **Mac opens the file in its default app** instead of the Quick Look panel (a later polish) |
| Paste of images and files | **Not built** |
| Export to `.md` plus an attachments folder | **Not built** |
| Alt text editing, VoiceOver labels on pictures | **Not built** (the picture is drawn, not an accessibility element yet) |

## Goal

Add photos, images, PDFs, and other files to a note, the way Apple Notes does, while the note itself stays plain Markdown. The Markdown is still the only source of truth for text. An attachment is a separate synced record that the Markdown points at.

## Principles

1. **Markdown stays readable anywhere.** An attachment appears in `body` as ordinary Markdown with our own link scheme, so other Markdown tools show a broken image or link, never garbage (decided in `00-open-questions.md`, A4).
2. **Additive schema only.** A new `Attachment` model and a new relationship. Nothing existing is renamed or retyped (Spec 01 rules).
3. **Sync is never gated.** Attachments sync for free, like everything else. Size limits protect iCloud storage and sync time, not the paywall.
4. **Nothing is lost silently.** A file that is too big, or unreadable, produces a clear message. Deleting text that references an attachment does not delete the file at once (see "Cleanup").
5. **Apple frameworks only.** `PhotosUI`, `UniformTypeIdentifiers`, `QuickLook`, `QuickLookThumbnailing`, `ImageIO`, `SwiftData`.

## Markdown form

| Kind | In `body` |
|---|---|
| Image | `![alt text](attachment://UUID)` |
| Any other file | `[file name.pdf](attachment://UUID)` |

- `UUID` is the `Attachment.id`. The link text is a hint for other tools and for VoiceOver. The record's own `fileName` and `altText` are authoritative.
- The scanner (`InlineScanner`) learns the `attachment://` scheme the same way it learns links. Hiding rules for the live preview follow the link rules in Spec 03.
- Raising `minimumReaderVersion` to 2 on a note that uses attachments is **not** needed: older app versions show the Markdown text unchanged. (If we later hide such notes from old versions, revisit.)

## Data model (SchemaV2, lightweight migration)

New model `Attachment`. All properties have defaults. CloudKit restrictions apply (no unique constraints, optional relationship with an inverse, no `.deny`).

| Property | Type | Default | Notes |
|---|---|---|---|
| `id` | `UUID` | `UUID()` | Referenced from the Markdown. Never changes |
| `fileName` | `String` | `""` | Original name, shown on the file chip |
| `typeIdentifier` | `String` | `""` | A UTI such as `public.jpeg`. Decides image or file, icon, and preview |
| `byteCount` | `Int` | `0` | For the size label and the limit check |
| `createdAt` | `Date` | `.now` | |
| `altText` | `String` | `""` | Image description for VoiceOver. Optional for the user |
| `pixelWidth`, `pixelHeight` | `Int` | `0` | Images only. Lets the editor reserve the right height before the image loads |
| `data` | `Data?` | `nil` | `@Attribute(.externalStorage)`. Mirrored to CloudKit as an asset. Loaded lazily |
| `note` | `Note?` | `nil` | Inverse of `Note.attachments`. Delete rule on the note side: `.cascade` |

`Note` gets `attachments: [Attachment]?` (relationship, inverse `Attachment.note`).

Thumbnails are **not** stored in the synced model. They are generated on demand with `QLThumbnailGenerator` and cached on disk in the Caches directory, so they cost no sync bandwidth and can be thrown away.

## Limits

| Limit | v1 value | Why |
|---|---|---|
| One file | 25 MB | Well under CloudKit's asset limit, and keeps a first sync on cellular reasonable |
| Per note | 20 attachments | Keeps the note view responsive |
| Images | Downscaled to 2048 px on the long edge and re-encoded as HEIC or JPEG when larger than the limit | Photos from a modern iPhone are 5 to 10 MB. Originals are not kept (see decision D2) |

Numbers are starting points to tune after real use. A file over the limit is refused with: "That file is larger than 25 MB."

## Getting an attachment in

| Source | Platforms | How |
|---|---|---|
| Photo library | iPhone, iPad, Mac | `PhotosPicker` (no photo-library permission prompt) |
| Camera | iPhone, iPad | `UIImagePickerController` in camera mode (needs `NSCameraUsageDescription`) |
| Files | all | `.fileImporter` with the security-scoped URL copied into the store at once |
| Drag and drop | iPad, Mac | `.dropDestination` on the editor, accepting `Transferable` file and image types |
| Paste | all | Pasted image data or file URLs |

All paths end in one function in `NotesCore`: `AttachmentStore.add(data:fileName:type:to:)`. It enforces the limits, downscales images, creates the record, and returns the Markdown to insert at the caret. The editor inserts that text through the normal text-system path, so undo and redo work.

An **Attachments button** goes on the formatting toolbar (Mac window toolbar and the iPhone keyboard bar), a paperclip with a menu: Photo Library, Take Photo, Choose File.

## How it looks

- **Image:** shown inline at the width of the text column, never wider than the original. Height reserved from `pixelHeight`, so loading does not move the text. Implemented with an `NSTextAttachment` view provider in TextKit 2, on the line that holds the Markdown. While the caret is on that line, the raw Markdown shows (same rule as other marks).
- **Other file:** a **file chip**: type icon, file name, size. Tapping or clicking opens it with Quick Look (`QLPreviewController` on iOS, `QLPreviewPanel` on the Mac).
- **Missing data** (record arrived before its asset, or asset not downloaded yet): a placeholder with a progress indicator, then it fills in. A reference whose record does not exist at all shows a "Missing attachment" chip. The Markdown is never altered.
- **Accessibility:** images use `altText` (or the file name), chips read "name, type, size, button".

## Cleanup (no silent data loss)

- Deleting the Markdown that references an attachment leaves the record in place. A maintenance pass (the same one that purges Recently Deleted) deletes attachments of a live note that are **not referenced in the body** and are older than 30 days. This keeps undo and Version History restorable.
- Trashing a note keeps its attachments. Permanent deletion removes them (cascade).
- Version History snapshots store only text, so restoring an old version can reference an attachment that has been cleaned up. That shows "Missing attachment". Because of the 30-day grace period, this only happens for old versions.

## Export (B3)

Export writes each note as a `.md` file plus an `attachments` folder. References are rewritten to relative paths (`attachments/UUID-name.ext`) in the exported copy only. The stored body is never changed.

## Search and intents

- Search matches the text in `body`, so a file name in the link text is searchable. Text inside images and PDFs (OCR with Vision) is **out of scope** for v1.
- App Intents: Get Note Text returns the Markdown with `attachment://` links. Returning the files themselves, and an "Add file to note" intent, are later (Spec 06 follow-up).

## Risks

1. **Sync cost.** Each attachment is a CloudKit asset. A note with many large photos syncs slowly on a first install. Mitigation: the limits above and lazy loading. **Verify** with a real iCloud account on cellular.
2. **Ordering.** The note's text can arrive before the attachment record. The placeholder state above is required, not optional.
3. **Lightweight migration.** Adding a model and a relationship is additive, so SchemaV1 to SchemaV2 should migrate automatically. **Verify** on a copy of a real store before release.
4. **TextKit 2 attachments.** View providers behave differently on UIKit and AppKit and inside our custom layout fragments. A small spike is needed first (see Build order).

## Decisions needed

| # | Question | Proposed |
|---|---|---|
| D1 | File size limit and per-note count | 25 MB, 20 files (above) |
| D2 | Keep the original full-size photo, or downscale | Downscale to 2048 px. Keeping originals makes sync and storage heavy |
| D3 | Delete unreferenced attachments automatically | Yes, after 30 days, as described |
| D4 | OCR and scanning documents (VisionKit) | Later, with search inside attachments (M4 scanning item) |

## Testing

| What | How |
|---|---|
| Limits, downscale decision, Markdown generation, unreferenced-attachment detection | Swift Testing in `NotesCore` (pure logic, no UI) |
| Schema migration V1 to V2 | Test with an in-memory store built from the V1 schema |
| `attachment://` scanning | Extend `InlineScannerTests` |
| Inline image, file chip, Quick Look, picker, drag and drop, camera, sync of assets | Manual on devices; previews for the rendered states |

## Build order

1. Spike: an inline image and a chip inside the TextKit 2 editor on both platforms (risk 4).
2. `SchemaV2` with `Attachment`, `Note.attachments`, and the migration stage, with tests.
3. `AttachmentStore` (limits, downscale, Markdown, cleanup pass), with tests.
4. Scanner support for `attachment://`.
5. Editor rendering: image view provider, file chip, placeholders.
6. Insertion: toolbar button and the five sources.
7. Quick Look, export, accessibility pass, device test rows.

## Acceptance criteria

1. Adding a photo from the library puts it in the note, shown inline, and it appears on the other device.
2. Adding a PDF shows a chip; clicking it opens a preview.
3. A file over the limit is refused with a clear message and nothing is added to the note.
4. The note's `body` contains only the Markdown form above, and opens correctly in another Markdown editor (as broken image or link, with readable text).
5. Deleting the text of an attachment, then undoing, brings it back with its image.
6. A note that syncs before its attachment shows a placeholder and then the image, with no layout jump.
7. Export produces a folder with the `.md` files and their attachments.
