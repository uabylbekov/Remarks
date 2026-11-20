# Open Questions and Gaps

Status: Draft v0.1 (2026-11-19). Companion to `00-product-plan.md`.

Items marked **Proposed** are recommendations awaiting your confirmation. Items marked **Verify** are things the docs did not settle, so they need a spike before the owning spec is finalized.

## Part A: Open questions from the plan

### A1. Editor technology (Spec 03)

**Findings**
- SwiftUI `TextEditor` now has a rich-text initializer: `TextEditor(text: Binding<AttributedString>, selection: Binding<AttributedTextSelection>?)`.
- `attributedTextFormattingDefinition(_:)` lets us constrain which attributes the user can produce.
- Custom attributes can be defined through `AttributeScope`, so code-block and Markdown semantics could live in the attributed string.
- TextKit 2 (`UITextView` / `NSTextView`, `NSTextContentStorage`, `NSTextLayoutManager`) is the lower-level fallback and is shared across iOS and macOS.

**Decided (2026-11-19): TextKit 2.** See `specs/spikes/01-editor-spike.md`. The text below is the original analysis, kept for context.

**Original proposal:** Spike both (1 to 2 days each) against the same test document before committing.
- Spike 1: `TextEditor` + `AttributedString`, with highlighting applied by re-styling code ranges on edit.
- Spike 2: a TextKit 2 wrapper using `NSTextStorage` attribute updates.

**Decision criteria:** typing latency on a 50k-character note, correct selection and IME behavior, undo/redo integrity while re-styling, ability to draw code-block backgrounds, and accessibility (VoiceOver, Dynamic Type).

**Verify:** minimum OS for the `AttributedString` `TextEditor` (the docs search did not state availability), and whether it can render block-level backgrounds for code.

### A2. Syntax highlighting engine (Spec 05)

**Findings:** Apple provides no syntax highlighter. Candidates are a Swift library (Highlightr, Splash) or tree-sitter. I did not evaluate them in this pass.

**Decided (2026-11-19):** Apple frameworks only, so Highlightr, Splash, and tree-sitter are out. We build our own tokenizer on `NSRegularExpression` or Swift Regex, driven by small per-language grammar definitions (data, not code). Define a `SyntaxHighlighter` protocol in `NotesCore` so the engine stays swappable.

**Spike 02 is complete (2026-11-19):** see `specs/spikes/02-highlighter-spike.md`. 9 languages, 19 of 19 correctness cases pass, 3 documented regex limits, about 10 ms for 800 lines in a debug build, and 0.1 ms to re-highlight one block. The questions below were the original brief.

**Spike 02 originally asked:** how many languages we can cover well with regex grammars, where regex breaks down (nested or multi-line constructs such as block comments and string interpolation), the cost of incremental re-highlighting after an edit, and the grammar data format. Set a v1 language list (for example Swift, Python, JavaScript/TypeScript, JSON, shell, HTML/CSS, SQL, C-family, Rust, Go) and accept "good enough" rather than perfect.

### A3. Sync model (Spec 02) and sharing

**Findings (from Apple docs)**
- SwiftData syncs through `NSPersistentCloudKitContainer` under the hood.
- CloudKit-compatible schemas cannot use unique constraints. All relationships must be optional and have inverses, and the `.deny` delete rule is not allowed.
- **The production CloudKit schema is additive-only.** You cannot delete or rename record types or fields once promoted. Apple suggests a `version` attribute so older app versions ignore newer records.
- Large binary data should use `@Attribute(.externalStorage)`. `.allowsCloudEncryption` is available for sensitive fields.
- Required setup: iCloud + CloudKit capability, Background Modes (remote notifications), and a manual step to initialize and then promote the schema.
- Record sharing (`CKShare`) is documented for Core Data (`NSPersistentCloudKitContainer`) and raw CloudKit. I found no SwiftData sharing API in the docs.

**Implications**
1. Data model mistakes are permanent in production. Spec 01 needs extra review, and the schema should be designed for additive growth from day one.
2. Because collaboration is a v1 non-goal, SwiftData + CloudKit is acceptable. If shared notes might ever matter, choose Core Data + `NSPersistentCloudKitContainer` or `CKSyncEngine` now, because switching later means a store migration.
3. **Conflict handling is a product risk.** If the note body is a single synced field, concurrent edits on two devices will lose one side's changes. **Verify** the exact merge behavior in a two-device test, then choose: accept last-writer-wins, keep a "conflicted copy", or store the body in smaller blocks.

**Proposed:** Stay with SwiftData + CloudKit, put the body in one field for v1, add a conflict-copy safeguard, and run a two-device conflict spike in M0. Treat sharing as out of scope and document that revisiting it costs a migration.

### A4. Markdown as truth vs. rich features (Spec 03)

**Proposed:** Dialect is CommonMark + GFM (tables, task lists, strikethrough, fenced code). Anything beyond that, such as attachments, must be expressed as extended syntax that degrades gracefully in other Markdown tools, for example `![](attachment://UUID)`.

**Native-only findings (2026-11-19):** Foundation's `AttributedString(markdown:)` parses block kinds (headers, paragraphs, block quotes, ordered and unordered lists, code blocks with a language hint, thematic breaks, and tables with alignment) and inline kinds (emphasis, strong, strikethrough, code, links, images, HTML). It can attach source positions (line and column) to runs. Gaps found in the docs:
1. **No task-list kind.** `- [ ]` and `- [x]` checklists are not a block kind, so we parse them ourselves.
2. **No documented Markdown serializer.** Foundation parses Markdown into an attributed string but I found nothing that writes it back. Because Markdown is the source of truth, the editor edits the Markdown **text** and we derive styling from a parse, rather than serializing a rich string back to Markdown.
3. **Fidelity is unverified.** How closely Foundation follows CommonMark and GFM on edge cases needs a test against a real corpus.

**Plan:** a thin `MarkdownParser` in `NotesCore` that wraps Foundation, adds checklist and our attachment syntax, and exposes source ranges. The Markdown round-trip corpus test is written first (see Spec 03).

Acceptance rule: `parse(serialize(parse(x)))` equals `parse(x)` for a corpus of real-world notes. This round-trip test is written before the editor.

### A5. Apple Notes import (post-v1)

**Findings:** I found no public Apple Notes API in the docs. This remains unverified beyond that.

**Proposed:** Do not promise import in the v1 marketing. Research in a time-boxed spike: macOS scripting, reading exported content, or Share-sheet based import per note. Decide go or no-go before M4.

### A6. Pricing mechanics (Spec 09)

**Findings**
- StoreKit supports non-consumable In-App Purchases, including Family Sharing for them.
- `AppTransaction` lets you detect when and at what version a customer first bought the app. Apple documents this for business model changes, such as moving a paid app to free with an unlock.

**Proposed:** Free download with a **one-time non-consumable unlock**.
- Pros: Allows a trial, lowers the barrier, and `AppTransaction` keeps the door open to grandfather early adopters if the model changes.
- Constraint: The trial must **not** gate sync, or the "free iCloud sync" promise is broken. Gate by note count or advanced features (code highlighting, intents), not by sync.

**Decide:** Free download + unlock vs. paid upfront (simpler, no trial).

### A7. Minimum OS version (Spec 01)

**Decided:** iOS/macOS 27 only (see Part C). The app has no legacy user base, so the newest APIs and simplest code win. Re-check the trade-off if the audience on the previous release looks large near launch.

## Part B: Gaps not yet in the plan

| # | Gap | Why it matters | Proposed handling | Spec |
|---|---|---|---|---|
| B1 | **Definition of "superset"** | Without a parity matrix we cannot say when we are done | Build a feature-by-feature matrix of Apple Notes, mark each Parity / Better / Skip | 00 / 04 |
| B2 | **Locked notes vs. sync** | Locking must protect content in CloudKit, not just in the UI | Encrypt the locked body with a key held in Keychain, and evaluate `.allowsCloudEncryption`. Decide what happens when the user forgets the password. | 08 |
| B3 | **Data portability and exit** | Users own their data, and CloudKit docs expect an access/export path | Full export to a folder of `.md` files plus attachments, available from day one | 03 / 04 |
| B4 | **Schema evolution** | Additive-only production schema | Version field on every model, and a written rule list of allowed changes | 01 |
| B5 | **Large notes and attachments** | CloudKit record size limits and sync cost. **Verify** limits. | External storage for blobs, size caps, and lazy loading | 02 / 07 |
| B6 | **Search architecture** | Needs to be fast and also feed Spotlight | In-app search over the store, plus Spotlight indexing of entities (see B7) | 04 |
| B7 | **AI and Siri access path** | Core to the product | See "AI access" below | 06 / 10 |
| B8 | **Shared storage for extensions** | Widgets, share extension, and intents need the same store | App Group container, set via `ModelConfiguration`. **Verify** behavior with CloudKit sync. | 01 |
| B9 | **MCP security and platform fit** | iOS apps cannot practically host a long-running server | macOS-only local MCP server first, with explicit user consent, per-tool permissions, and an audit log. iOS exposure goes through App Intents. | 10 |
| B10 | **Offline and sync status UI** | Users need to trust sync | Show sync state, last sync time, and error surfacing. Handle "iCloud signed out" gracefully. | 02 |
| B11 | **Accessibility** | Required for a quality native app | VoiceOver, Dynamic Type, and contrast checked per feature, not at the end | all |
| B12 | **Localization** | App Store reach | String catalogs from day one | all |
| B13 | **Testing strategy** | Spec-driven needs testable criteria | In-memory SwiftData for unit tests, a Markdown round-trip corpus, App Intents tests, and UI tests for core flows | all |
| B14 | **Privacy and App Store compliance** | Required to ship | Privacy manifest, no third-party analytics, App Privacy details, iCloud data disclosure | 09 |
| B15 | **Support and recovery** | Data loss destroys trust | Recently Deleted folder with retention window, and local snapshot backups before schema migrations | 01 / 04 |

### AI access (B7), in detail

There are three layers, ordered by cost:

1. **Spotlight + App Intents (v1, M3).** Make notes an `IndexedEntity` and donate them with `CSSearchableIndex.indexAppEntities`. Implement `IndexedEntityQuery` so the system can ask for reindexing. This gives Siri and Shortcuts access and is the foundation for everything else.
2. **Foundation Models search tool (cheap follow-up).** The docs describe a `SpotlightSearchTool` that lets on-device models search an app's Spotlight index. If the index is good, this adds natural-language search over notes with little extra work. **Verify** availability and limits.
3. **MCP server (post-v1).** Exposes read, search, and write tools to external agents. Needs the security model in B9. Depends on `NotesCore` being UI-free, which is already a plan decision.

## Part C: Decisions (resolved 2026-11-19)

| # | Decision | Outcome | Consequence |
|---|---|---|---|
| 1 | Pricing | **Free download with a limited trial, then a single non-consumable purchase.** Sync is never gated. | Spec 09 defines trial limits (not sync). Use `AppTransaction` for grandfathering. |
| 2 | Sharing | **Out of scope for v1. Keep SwiftData + CloudKit.** | Adding sharing later requires migrating to Core Data or `CKSyncEngine`. |
| 3 | Minimum OS | **iOS/macOS 27 only.** | Newest APIs and simplest code. Excludes users who have not updated. |
| 4 | Spikes | **Run editor, conflict, and highlighter spikes before Specs 01 to 05.** | Conflict spike needs two devices on one iCloud account and a paid developer account. |
| 5 | Dependencies | **Apple frameworks only.** No third-party or Apple open-source packages. | We write our own highlighter, Markdown gap-filler, and MCP transport. See A2 and A4. |
| 6 | Settings storage | **`NSUbiquitousKeyValueStore` + `UserDefaults` mirror.** | Needs the key-value storage iCloud capability in addition to CloudKit. Sync is slightly delayed. |
| 7 | Platforms | **iOS, iPadOS, macOS. visionOS removed from the project.** | `SUPPORTED_PLATFORMS` and `TARGETED_DEVICE_FAMILY` updated and build verified. Can be added back later. |
| 8 | Developer account and test devices | **Paid membership. Mac + iPhone on one iCloud account.** | iCloud, CloudKit, and key-value storage can be enabled in M0. The two-device conflict spike is unblocked. Bundle ID set to `io.github.uabylbekov.notes` (2026-11-19). iCloud entitlements added (CloudKit container `iCloud.io.github.uabylbekov.notes`, CloudKit service, key-value storage, push) plus outgoing network for the sandbox and the remote-notification background mode. A signed macOS build succeeded on 2026-11-19 after the Program License Agreement was accepted and the account was re-signed in. Container creation in the CloudKit Console is not independently verified yet. iOS device signing is untested. |
