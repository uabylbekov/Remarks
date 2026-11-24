# AGENTS.md

Rules for AI coding agents working in the Remarks repo. Remarks is a Markdown notes app for Apple platforms (SwiftUI + a native text editor, CloudKit sync, App Intents, Spotlight).

## Definition of done

A task is done only when all of these hold. Say which you verified and which you couldn't (for example, device-only behavior).

- The project builds with no new warnings.
- New and existing tests pass; the change was made test-first.
- UI strings are localized in all supported languages.
- Accessibility checks for changed UI are done.
- Any spec in `specs/` affected by the change is updated.
- No unrelated changes are included.

## When to ask vs. decide

- Ask first when a change touches the data model, CloudKit schema, sync, public App Intents behavior, privacy declarations, or any user-visible behavior, or when an idiomatic replacement would change behavior.
- Decide on your own for naming, file placement, and implementation details within the requested scope.

## Project layout

- `Remarks/` — app target: UI, editor (`Editor/`), navigation (`Navigation/`), settings, intents shortcuts.
- `RemarksCore/` — platform-light logic: Markdown parsing/editing, notes store/service, sync, schema, intents entities, syntax highlighting. Keep it free of UI code.
- `RemarksCoreTests/` — tests for `RemarksCore`.
- `specs/` — product, design and architecture docs. Read the relevant spec before changing a feature (e.g. `03-editor.md`, `02-sync.md`, `06-app-intents.md`) and update it if behavior changes.
- `docs/` — public website (GitHub Pages: index, privacy, support). Don't touch unless asked.
- `Marketing/` — App Store metadata, screenshots, icon sources. Don't touch unless asked.
- `Icon.icon/` — app icon; edit only when asked.

## Workflow

- Do only what was asked. No unrelated refactors, renames, or formatting sweeps.
- Prefer Xcode MCP tools (`XcodeRead`, `XcodeGrep`, `XcodeUpdate`, `BuildProject`, `XcodeRefreshCodeIssuesInFile`) over shell commands for project files.
- Build after non-trivial changes; use `XcodeRefreshCodeIssuesInFile` for fast checks.
- Search Apple docs (`DocumentationSearch`) before using newer APIs (Liquid Glass, FoundationModels, App Intents, recent SwiftUI). Don't assume older patterns are still right.
- Commit or push only when asked.
- Commit messages: no `Co-Authored-By` line, no AI attribution or "Generated with" footer. Same for PR descriptions.

## Git and GitHub

- Remote: `origin` (github.com/uabylbekov/notes). `develop` is the working branch; `main` is release-only and updated through a pull request from `develop`. Never commit or push directly to `main`.
- Never force-push, rewrite published history, or delete branches without being asked. Don't use `--no-verify` or skip hooks.
- Commit messages: imperative, sentence case, no type prefix, under about 72 characters in the subject (e.g. "Fix keyboard timing on iPhone"). Add a body only when the reason isn't obvious from the diff; explain why, not what.
- One logical change per commit. Don't mix refactors, moves, or formatting with behavior changes. Tests ship in the same commit as the change they cover.
- Stage files explicitly by path; never `git add -A` or `git add .`. Check `git status` first, and leave unrelated staged or modified files (icons, Marketing moves) out of the commit.
- Never commit secrets, `.DS_Store`, build products, or `xcuserdata`.
- Pull requests: title in the same style as commit subjects. The description says what changed, why, and how it was verified (tests run, devices checked, anything not verified), and links related specs or issues. Keep each PR focused on one change.
- Pushing, opening or merging a PR, commenting on GitHub, or changing repo settings is outward-facing: do it only when asked, each time. Approval for one push or PR doesn't carry over to the next.
- Git hooks live in `.githooks/` (tool-agnostic, apply to every agent and person). Enable them once per clone with `git config core.hooksPath .githooks`. They reject AI attribution in commit messages, commits on `main`, `.DS_Store`/`xcuserdata` files, pushes to `main`, force pushes, and remote branch deletion. Hooks can't stop `git add -A` or `--no-verify`, so those rules rely on you following this file. Never bypass a hook; if one blocks you, fix the cause.
- `gh` isn't installed on this machine; use plain `git`, or ask before installing it.

## Root causes and custom code

- Fix the root cause, never patch. No delays, retries, flags, or special cases that hide a symptom. If the real fix is larger than the task, explain it before starting.
- If you find a workaround or custom code in the area you're working on that idiomatic SwiftUI/Swift can replace, analyze it and replace it, but only when behavior is provably unchanged and there are no side effects:
  - Read the custom code first and note what it really does (focus, selection, undo, keyboard timing, iPad/Mac differences). Past fixes often exist for a reason; check git history.
  - Confirm the system API behaves the same (use `DocumentationSearch`).
  - Cover behavior you can't verify by reading with a test or a `specs/device-test-checklist.md` item.
  - One replacement per change, so it is easy to review and revert.
- If the idiomatic version would change behavior in any visible way, stop and ask first.
- Don't go hunting for replacements in unrelated files; propose a separate cleanup instead.

## Code style

- Always prefer idiomatic SwiftUI and Swift: system components, standard modifiers, built-in navigation/toolbars/menus, and framework APIs. Build a custom solution only when the platform offers no workable option, and say why in a short comment.

- Swift, 4-space indentation. PascalCase types, camelCase members.
- Use `async`/`await`; avoid Combine.
- Concurrency: Swift 6 strict concurrency. Mark UI types `@MainActor`; make anything crossing actors `Sendable`. Never silence a warning with `@unchecked Sendable`, `nonisolated(unsafe)`, or `assumeIsolated` without a stated reason; fix the isolation design instead.
- Performance: notes and the editor can be large. No synchronous parsing, rendering, or I/O on the main thread. Measure with `xctrace`/Instruments before and after any change made for performance; don't optimize on a guess.
- No force unwraps (`!`, `try!`, `as!`) outside tests.
- Match surrounding code: naming, comment density, idioms. Comment only non-obvious logic.
- SwiftUI: `@State private var` for local state, `let` for constants, prefer `@Observable` over `ObservableObject`.
- Put logic that doesn't need UIKit/AppKit/SwiftUI in `RemarksCore` so it is testable.

## Design

- Follow the Apple Human Interface Guidelines. The result should look like Apple built it: native, quiet, and familiar, with no generic "AI-generated" styling.
- Use system components, semantic colors (`.primary`, `.secondary`, `Color(.systemBackground)`), system materials, SF Symbols, and text styles (`.body`, `.headline`) instead of fixed sizes and hex colors.
- Use system spacing and standard layout margins. Don't invent custom padding scales, corner radii, or shadows.
- Avoid decoration that serves no purpose: gradients, glows, heavy shadows, emoji as icons, colorful cards, hero banners, and excessive animation.
- Adopt Liquid Glass through the standard system components and APIs; don't fake it with custom blur or overlay stacks. Search the docs for current guidance first.
- Use standard navigation (`NavigationSplitView`, `NavigationStack`), toolbars, menus, context menus, swipe actions, sheets, and confirmation dialogs with their usual HIG behavior.
- Write UI copy the way Apple does: short, plain, sentence-style capitalization for body text, title-style for buttons and menu items, no exclamation marks, no marketing tone.
- Check HIG for the platform (iPhone, iPad, Mac) before adding any new pattern, and respect each platform's conventions (e.g. keyboard shortcuts and menu bar on Mac and iPad).

## Platforms and cross-platform

- The app targets multiple Apple platforms. Guard platform-specific code with `#if os(...)` / `canImport` and keep both paths compiling.
- Accessibility is part of done for any UI change: it must work with Dynamic Type (including accessibility sizes), VoiceOver, Reduce Motion, Increase Contrast, sufficient contrast, and Dark Mode. Run the accessibility audit skills (Dynamic Type, VoiceOver, contrast) on changed views.

## Data, sync and schema

- Notes are Markdown text plus attachments; CloudKit is the sync layer. Never change stored fields or CloudKit schema (`CloudKitSchema.swift`, `NotesSchema.swift`) without a migration plan and a spec update (`01-data-model.md`, `02-sync.md`).
- Never delete or rewrite user content destructively. Deletions go through Recently Deleted.
- Don't log note content or other user data.

## Editor

- The editor is native (see `specs/03-editor.md`, `specs/editor-architecture.md`). Edits to Markdown behavior (lists, tables, code blocks, inline styles) belong in `RemarksCore` with tests; keep view controllers thin.
- Rendering resources (KaTeX, Mermaid, fonts) are vendored; don't upgrade or edit them casually. Keep license and version files in sync if you do.

## App Intents and Spotlight

- Follow `specs/06-app-intents.md` and the existing intents (Write Note, Update Note, etc.). Entity IDs must stay stable. `AppEnum` raw values must never be renumbered.
- Intent `perform()` is not main-actor: hop explicitly when touching UI state.

## Localization

- All user-facing strings go through string catalogs (`Localizable.xcstrings`, `AppShortcuts.xcstrings`, `InfoPlist.xcstrings`, and the `RemarksCore` catalogs). No hardcoded UI strings.
- Supported languages: en-US, de-DE, fr-FR, ja, ko, zh-Hans, zh-Hant. When adding strings, add translations for all of them (use the translation skills/tools).

## Testing (TDD: tests are the spec)

- Work test-first. For every feature, behavior change, or bug fix: write a failing test that states the expected behavior, run it and confirm it fails for the right reason, then write the minimum code to make it pass, then refactor with tests green.
- Test names are for code review: a reviewer should understand the intended behavior from the names alone, without reading the bodies. Use the `@Test("...")` display name as a plain sentence stating the behavior and condition (e.g. `"Pressing return on an empty bullet removes the bullet"`), not a method name or `test1`. Group related tests in a `@Suite` named for the type or feature. One behavior per test.
- Tests are the source of truth for behavior. If code and a test disagree, work out which one is wrong. Don't edit a test just to make it pass; change a test only when the intended behavior changes, and say so.
- Bug fixes start with a regression test that reproduces the bug. This also confirms the root cause (see "Root causes and custom code").
- Before replacing custom code with an idiomatic version, pin the current behavior with tests first, then swap the implementation with the tests unchanged.
- Use Swift Testing (`import Testing`, `@Test`, `#expect`) for unit tests; XCUIAutomation for UI tests.
- Put logic in `RemarksCore` so it can be tested without UI. Keep views thin. When something can only be checked on a device, add it to `specs/device-test-checklist.md`.
- Tests must be deterministic: no real network, no real CloudKit, no sleeps. Use in-memory stores and injected dependencies.
- Run the relevant tests (`RunSomeTests`) after every step; run `RunAllTests` before finishing any change to shared logic. Report failures as they are; don't skip or disable tests.

## Privacy and release

- Keep `PrivacyInfo.xcprivacy` (app and core) accurate when adding APIs that require reason declarations or data collection.
- Don't add third-party dependencies or network calls without asking.
- App Store copy lives in `Marketing/Metadata/`; screenshots in `Marketing/Screenshots/`. Don't edit these as a side effect of code changes.
- Never commit secrets, signing material, or `.DS_Store` files.
