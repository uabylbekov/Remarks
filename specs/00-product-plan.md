# Notes: Product Plan

Status: Draft v0.1 (2026-11-19)

## 1. Vision

A native Apple notes app that is a **superset of Apple Notes**: everything Apple Notes does, plus first-class Markdown and code, deep Siri/App Intents integration, and a future MCP server for AI agents.

Pricing: **one-time purchase**. Sync is free because it runs on the user's own iCloud, so there are no server costs and no subscription.

### Why this exists
| Competitor | Gap |
|---|---|
| Apple Notes | No real code blocks or Markdown; limited automation and AI access |
| Bear | iCloud sync is a paid subscription |
| Craft | Expensive and subscription-based |

## 2. Decisions (locked for v1)

| Area | Decision | Rationale |
|---|---|---|
| Platforms | iOS, iPadOS, macOS, one SwiftUI multiplatform codebase | Matches Apple Notes. App Intents are most useful on iPhone and Mac. |
| Storage | **Markdown is the source of truth** | Portable, AI/MCP-friendly, and fenced code blocks give simple highlighting |
| Sync | SwiftData + CloudKit private database | No server, free for user and developer |
| Business model | Free download with a limited trial, then a single non-consumable IAP. Sync is never gated. | Lower barrier, no running costs, early buyers can be grandfathered via `AppTransaction` |
| Minimum OS | iOS / iPadOS / macOS 27 | Newest APIs, simplest code |
| Form factors | Must support iPhone Duo (all poses and displays) and resizable windows | Layout driven by size classes and safe areas. See `00-platform-design.md` |
| Design system | Liquid Glass via standard system components; no glass in the content layer | Native look with little custom code. See `00-platform-design.md` |
| Sharing | Out of scope for v1 | Keeps the simpler SwiftData stack; adding it later means a store migration |
| Architecture | `NotesCore` Swift package (model, Markdown, search, intents-facing services) plus thin app UI | Intents, widgets, and a future MCP server reuse the same core |
| Editing style | **Live preview** (Bear/Obsidian style): prose in the text font, code blocks with a background and the code font, Markdown marks hidden except on the line being edited. Markdown text stays the source of truth. | Matches the "superset of Apple Notes" goal. See `specs/spikes/01-editor-spike.md` |
| Editor technology | **TextKit 2** (`UITextView` / `NSTextView` wrappers) with a content-storage delegate for display-only styling and a custom layout fragment for code backgrounds | Spike 01 and 01b: verified on macOS and iPhone Duo, and confirmed by hands-on testing on Mac. The `AttributedString` `TextEditor` was dropped |
| Code highlighting | Own grammar engine on `NSRegularExpression`: a `Codable` grammar per language, one combined alternation scanned left to right, 10 scopes, highlighted per fenced block | Spike 02: 9 languages, 19/19 cases pass, 3 documented limits, fast enough. See `specs/spikes/02-highlighter-spike.md` |
| Dependencies | **Apple frameworks only.** No third-party or Apple open-source Swift packages. Our own local `NotesCore` package is fine. | Fewer moving parts, no supply-chain risk, and full control. Cost: we write a Markdown gap-filler, a highlighter, and a minimal MCP transport ourselves |
| Settings storage | `NSUbiquitousKeyValueStore` mirrored to `UserDefaults` | Native, tiny data, keeps preferences out of the permanent CloudKit schema |
| UI architecture | MV: views use `@Query`, `@State`, and `modelContext` directly; no view model per screen. Logic shared by intents, widgets, Spotlight, or MCP lives in `NotesCore` services. Exceptions: an `@Observable` editor session (Spec 03) and `@ModelActor` for background work (confirm API in Spec 01). | SwiftData is built for MV, and non-UI entry points cannot depend on views |
| Concurrency | Swift async/await; no Combine | Project guideline |
| Tests | Swift Testing; XCUIAutomation for UI | Project guideline |

## 3. Scope

### 3.1 Apple Notes parity (the "superset" floor)
- Folders and subfolders, pinned notes, tags, smart folders
- Checklists, bullet and numbered lists, headings, tables
- Attachments: images, files, PDFs, links with previews
- Search, including search inside attachments (OCR via Vision)
- Locked notes (biometric)
- Document scanning (VisionKit)
- Quick capture: widget, Control Center, share extension
- Drawing / Apple Pencil (PencilKit), likely post-v1
- Import from Apple Notes. There is no public API, so this needs research (see Risks).

### 3.2 Beyond Apple Notes (the differentiators)
- **Markdown editing** with live rendering
- **Code blocks** with syntax highlighting, language auto-detect, copy button
- Wiki-style links and backlinks
- Export to Markdown, PDF, and HTML
- **App Intents**: create, append, find, and open notes; entities and Spotlight indexing; Siri and Apple Intelligence compatible
- **MCP server** (post-v1): lets AI agents read, search, and write notes over a defined protocol

### 3.3 Explicit non-goals for v1
- Real-time multi-user collaboration
- Android / web clients
- Custom sync server
- Built-in AI features (we expose data to AI via intents and MCP rather than shipping a model)

## 4. Roadmap

| Milestone | Goal | Exit criteria |
|---|---|---|
| **M0: Foundations** | Project structure, `NotesCore` package, SwiftData models, CloudKit container | Notes sync between two devices in a test |
| **M1: Core editor** | Markdown editor, folders, tags, search | Create, edit, organize, and find notes on iOS and macOS |
| **M2: Code** | Fenced code blocks, highlighting, language detection | 10+ languages highlight correctly, in light and dark mode |
| **M3: App Intents** | Entities, queries, create/append/open intents, Spotlight | Siri and Shortcuts can create and find a note |
| **M4: Parity** | Checklists, tables, attachments, scan, lock, widgets | Parity checklist in 3.1 is complete (except post-v1 items) |
| **M5: Ship** | Onboarding, one-time purchase, accessibility, localization, App Store | TestFlight beta, then release |
| **Post-v1** | MCP server, import from Apple Notes, Pencil, backlinks graph | Separate specs |

## 5. Spec-driven workflow

Every feature follows the same loop. No code is written before its spec is reviewed.

1. **Spec**: `specs/NN-feature/spec.md` covers the user stories, acceptance criteria, edge cases, and non-goals.
2. **Plan**: `specs/NN-feature/plan.md` covers the technical design, data model changes, APIs, and risks.
3. **Tasks**: `specs/NN-feature/tasks.md` is a checklist of small, testable steps.
4. **Implement**: one task at a time, with tests derived from the acceptance criteria.
5. **Verify**: build, run tests, check against the spec, then update the spec if reality changed.

### Planned spec index
| # | Spec | Milestone |
|---|---|---|
| 00 | Platform design: iPhone Duo and Liquid Glass (cross-cutting, applies to all specs) | All |
| 01 | Data model and storage | M0 |
| 02 | Sync (CloudKit) | M0 |
| 03 | Markdown editor | M1 |
| 04 | Organization (folders, tags, pins, search) | M1 |
| 05 | Code blocks and highlighting | M2 |
| 06 | App Intents and Spotlight | M3 |
| 07 | Attachments and scanning | M4 |
| 08 | Locked notes | M4 |
| 09 | Monetization and onboarding | M5 |
| 10 | MCP server | Post-v1 |
| 11 | Appearance settings: text font, code font, code themes | M1 to M2 |

## 6. Key risks and open questions

Each of these should be resolved inside the relevant spec, not guessed. Research findings, proposed answers, and additional gaps are in `00-open-questions.md`.

1. **Editor technology.** Options are SwiftUI `TextEditor` with `AttributedString`, or a TextKit 2 wrapper (`UITextView` / `NSTextView`). Highlighting and live Markdown styling may need the latter. Check current SwiftUI and TextKit docs before deciding. (Spec 03)
2. **Highlighting engine.** Options are a library (e.g. Highlightr or Splash) or tree-sitter. Compare language coverage, size, and performance. (Spec 05)
3. **Sync model and attachments.** SwiftData + CloudKit has restrictions: no unique constraints, optional or defaulted properties, and large blobs should use external storage. Confirm what the current SDK supports, including whether CloudKit *sharing* is available, since that affects any later collaboration. (Spec 02)
4. **Markdown as truth vs. rich features.** Tables, checklists, and attachments must round-trip losslessly. Define the dialect (CommonMark + GFM extensions) up front. (Spec 03)
5. **Apple Notes import.** No public API exists. Possible routes are macOS scripting or export, which are limited. Confirm feasibility before promising it. (Post-v1)
6. **Pricing mechanics.** Paid upfront vs. a free download with a one-time unlock IAP. The IAP route allows a trial. Decide in Spec 09.
7. **Minimum OS version.** It affects which SwiftUI, SwiftData, and App Intents APIs are available. Decide in Spec 01.

## 7. Next step

Write **Spec 01 (Data model and storage)** and **Spec 02 (Sync)**, since everything else depends on them.
