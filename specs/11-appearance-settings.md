# Spec 11 (Draft): Appearance Settings, Fonts, and Themes

Status: Draft v0.2 (2026-11-19). Scope confirmed: text font, code font, and code themes. There is no separate "font theme" (decided). Milestone: M1 for text fonts, M2 for code font and code themes.

## Status of the build (2026-11-19)

| Built | Notes |
|---|---|
| F1, F2, F3, F4, F5, F7 | Text font and code font (system designs or any installed font), size slider (a multiplier on Dynamic Type), fallback to the system font with an explanation, live preview |
| T1 to T7 | `CodeTheme` is a versioned `Codable` value with light and dark colors. Built in: Standard, Solarized, High Contrast. Unknown theme ids fall back to Standard. Every built-in theme is tested for WCAG AA contrast (4.5:1) in light and dark |
| S1, S2, S4 | Standard `Form`; open editors re-style at once; Reset to Defaults |
| S3 | `NSUbiquitousKeyValueStore` plus a local `UserDefaults` copy. **Not yet verified between two devices** |
| Entry points | macOS: Settings window (⌘,). iOS and iPadOS: Appearance button in the sidebar toolbar |

**Not built yet:** F6 line spacing (the setting exists in the data, but nothing uses it); theme bold and italic (themes carry them, the editor only applies color); Increase Contrast switching to the High Contrast theme automatically (T4 "pin or match system" is a plain picker for now); a font picker for the Mac that shows a font panel instead of a menu.

## Goal

Users choose how notes look: the **text font**, the **code font**, and a **code theme** (syntax colors). Appearance is a presentation choice. It never changes what is stored in a note.

## Principles

1. **Markdown stays pure.** Fonts and themes are applied at render time. They are not written into note content, so export, sync, and MCP/AI access see plain Markdown.
2. **Everything scales with Dynamic Type**, including user-chosen fonts (see "Dynamic Type").
3. **Themes are data, not code.** A theme is a small `Codable`, versioned value. The highlighting engine produces tokens, and the theme maps tokens to colors. This keeps the engine swappable (Spike 02).
4. **Contrast is enforced** (G6 in `00-platform-design.md`): every built-in theme must pass in light, dark, Increase Contrast, and Reduce Transparency.
5. **The note text area is the content layer.** Settings may preview themes there, but nothing gets glass (G2).

## What the docs say

| Topic | Finding |
|---|---|
| Font picking on iOS | `UIFontPickerViewController` lists system fonts and fonts the user installed. `Configuration` can filter by traits (for example monospace), by language, and can include individual faces. The result is a `UIFontDescriptor` **without a size** |
| Font picking on macOS | `NSFontPanel` and `NSFontManager`. SwiftUI also has a `fontPanel` text formatting control placement |
| SwiftUI picker | I found no single cross-platform SwiftUI font picker in the docs. Plan on a small wrapper per platform. **Verify** |
| Custom fonts and Dynamic Type | SwiftUI: `Font.custom(_:size:relativeTo:)` scales with a text style. UIKit: `UIFontMetrics.scaledFont(for:)`. The base font passed in must **not** already be scaled |
| Syncing small preferences | `NSUbiquitousKeyValueStore`: 1 MB total, 1024 keys, 1 MB per value, needs the key-value storage entitlement, and sync timing is not immediate. A local `UserDefaults` copy is kept when iCloud is unavailable |
| Syncing via the main store | A settings model in SwiftData syncs with notes, but the CloudKit schema is additive-only (see `00-open-questions.md`) |

## Requirements

### Fonts

| ID | Requirement |
|---|---|
| F1 | Setting for **text font**: system default, system designs (serif, rounded, monospaced), or any font from the picker |
| F2 | Setting for **code font**: monospace fonts only (picker filtered to monospace), default system monospaced |
| F3 | Setting for **text size** that works together with Dynamic Type, not instead of it |
| F4 | Fonts are stored by **PostScript name** plus family name. If a font is missing on a device (for example a user-installed font on one device only), fall back to the system font and show a hint |
| F5 | Code font changes apply to inline code and fenced blocks. Text font changes apply to everything else |
| F6 | Line spacing option for text and code |
| F7 | A live preview in settings that uses a real sample note |

### Code themes

| ID | Requirement |
|---|---|
| T1 | A set of built-in themes (at least one light and one dark, plus a high-contrast one). Final list to be decided with the highlighter spike |
| T2 | A theme maps **token kinds** (comment, string, keyword, number, type, function, and so on) to a color and an optional weight or italic, plus a code block background and a text color |
| T3 | Each theme defines light and dark variants, or declares itself fixed (for example a dark-only theme) |
| T4 | "Match system appearance" picks the light or dark variant automatically. Users can also pin a theme |
| T5 | Themes are versioned `Codable` values, so new token kinds can be added without breaking old themes |
| T6 | Unknown token kinds in a theme fall back to the base text color |
| T7 | A theme never changes the stored note, only rendering |

### Settings behavior

| ID | Requirement |
|---|---|
| S1 | Settings use standard SwiftUI forms and system pickers. No custom glass (G1, G3) |
| S2 | Changes apply immediately to the open editor with no relaunch |
| S3 | Appearance settings sync across the user's devices. Mechanism decided below |
| S4 | A "Reset to defaults" action |
| S5 | Works on every form factor in `00-platform-design.md`, including iPhone Duo |

## Design notes

**Where settings live.** Two options. Recommended: `NSUbiquitousKeyValueStore` with a `UserDefaults` mirror, because appearance data is tiny, a different system from the notes store, and it avoids permanently adding fields to the additive-only CloudKit schema. The trade-off is a second iCloud capability (key-value storage) and non-immediate sync timing. Alternative: a SwiftData `AppearanceSettings` model that syncs with notes. **Decided (2026-11-19):** `NSUbiquitousKeyValueStore` mirrored to `UserDefaults`. Add the iCloud key-value storage capability. Observe `didChangeExternallyNotification` to apply changes from other devices, and handle the account-change and initial-sync reasons it reports.

**Rendering path.** The editor session (Spec 03) reads an `@Observable` appearance object and rebuilds fonts and attributes when it changes. For the `AttributedString` `TextEditor`, fonts come from the environment and attributes. For TextKit 2, the text storage attributes are rewritten. Either way, this is why the editor spike must also test **changing fonts at runtime** (add to Spike 01).

**Font availability across platforms.** Fonts installed on a Mac are not on an iPhone. This is why F4 stores names plus a fallback and tells the user rather than failing silently.

**Bundled fonts.** Option to ship a small curated set (for example a few open-license monospace fonts) so code looks good by default everywhere. Needs license checks (open licenses allow bundling, but verify each) and adds app size. Not required for v1 if system fonts plus the picker cover the need.

## Acceptance criteria

- Changing any font or theme updates an open note immediately on iOS, iPadOS, and macOS.
- Chosen fonts scale with Dynamic Type up to the largest accessibility size, without clipping.
- Every built-in theme passes the contrast checks in G6.
- A font missing on a device falls back gracefully and is explained.
- Exporting a note to Markdown contains no font or theme information.
- Settings sync to a second device (when sync is available).

## Decided

- No separate font theme. "Theme" means the code color theme only. Preset bundles of fonts and a whole-note color theme are out of scope for v1 and can be proposed later.

## Dependencies

- Spike 01 (editor): runtime font change behavior.
- Spike 02 (highlighter): token kinds the engine can produce, which define the theme schema.
- Spec 03 (editor session), Spec 05 (code blocks), Spec 09 (whether some themes are part of the paid unlock).
