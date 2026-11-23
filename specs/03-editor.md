# Spec 03: Markdown Editor

Status: **Implemented in part (2026-11-19), written after the first build.** Milestone: M1 (core), M2 (code).
Depends on: Spec 01, `spikes/01-editor-spike.md`, `spikes/02-highlighter-spike.md`, `00-platform-design.md`.

Current ownership and regression requirements: [Editor implementation baseline](editor-architecture.md). This
supersedes the historical keyboard-bar and source-mode presentation descriptions below.

## Decisions (already made)

- TextKit 2 text view (`UITextView` / `NSTextView`) wrapped for SwiftUI.
- Live styling: visible, editable Markdown markers in a muted color; code in a monospace font with syntax colors on the normal background. Tables and checkboxes remain rendered controls, with whole-note source editing available from the Note menu.
- Markdown text is the only source of truth. All styling is display-only (content storage delegate and a layout fragment), so selection, copy, undo, and sync always see the real characters.
- Syntax highlighting uses the native regex grammar engine (`NotesCore`).
- Apple frameworks only.

## Where things live

| Piece | Location | Notes |
|---|---|---|
| Fence scanner (`CodeBlockScanner`) | `NotesCore` | Pure, tested |
| Highlighter (`SyntaxEngine`, `SyntaxGrammars`) | `NotesCore` | 9 languages, pure, tested |
| Formatting logic (`MarkdownEditing`, `MarkdownCommand`) | `NotesCore` | Pure, tested. Returns a `TextEdit` and never touches UI |
| Live preview (`LivePreviewController`, `CodeBlockFragment`) | App, `Editor/` | UI only |
| Text view wrappers (`NoteEditor`) | App, `Editor/` | iOS and macOS |
| Keyboard bar (`MarkdownAccessoryView`) | App, `Editor/` | iOS only |
| Colors and fonts (`EditorTheme`) | App, `Editor/` | Placeholder for Spec 11 |

## Behavior implemented

| ID | Behavior | Status |
|---|---|---|
| E1 | Edits are written to the note with `Note.setBody` after 400 ms of no typing, and immediately when editing ends or the editor goes away | Done |
| E2 | Switching notes rebuilds the editor, so text and undo history never leak between notes | Done |
| E3 | Outside editing, the editor follows the stored note (so changes that arrive by sync appear). While the user is editing, incoming text never replaces the text under the cursor | Done |
| E4 | A new empty note takes focus | Done |
| E5 | Smart quotes, smart dashes, and text replacement are off, because they would corrupt Markdown and code | Done |
| E6 | Fenced code blocks: fences hidden unless the caret is inside the block, full-width background, code font, syntax colors by fence language | Done |
| E7 | `#` headings: sized and bold, marks hidden unless the caret is on the line | Done |
| E8 | **iPhone keyboard bar**: code block, inline code, heading, bold, italic, strikethrough, bullets, numbered list, checklist, quote, link, and hide-keyboard. Scrolls sideways | Done, needs device testing |
| E9 | Shortcuts (hardware keyboard on iPad, Mac): ⌘B bold, ⌘I italic, ⌘E inline code, ⌘K link, ⌥⌘C code block | Done, needs device testing |
| E10 | Formatting commands go through the text input system, so undo and redo work | Done, needs device testing |

| E11 | **Inline styles**: bold, italic, strikethrough, inline code, and links are styled, and their marks hide unless the caret is on that line. Nested styles work (bold containing italic). Code spans keep their contents literal | Done (render-verified on Mac and iPhone) |
| E12 | **Return continues lists**: bullets, numbered lists (counting up), checklists (new item unchecked), and quotes, keeping indentation. Return on an empty item ends the list. Return in the middle of an item splits it. Code blocks and text being composed keep default behavior | Done, logic unit-tested, needs device testing |
| E13 | **Tappable checkboxes**: `- [ ]` and `- [x]` show a drawn box when the line is not being edited. Tapping or clicking the box toggles it without moving the caret. Checked items are struck through and dimmed | Drawing verified. Tap handling needs device testing |
| E14 | Code blocks have rounded outer corners, inner padding, and inset text, with the background spanning the full width | Done (render-verified) |

### Keyboard bar behavior

- **Code block** inserts a fenced block and leaves the caret right after the opening ``` so a language can be typed. On a blank line it becomes the block, on a line with text it goes after that line, and on a selection it wraps the selected lines.
- **Inline marks** (bold, italic, strikethrough, inline code) wrap the selection. With no selection they insert a pair with the caret between. Pressing again inside an empty pair, or with markers around the selection, removes them.
- **Heading** cycles `#`, `##`, `###`, plain.
- **Lists and quote** toggle on every non-empty selected line. Switching between bullet, checklist, and numbered replaces the old mark.
- **Link** inserts `[selection]()` with the caret in the parentheses, or `[]()` with the caret between the brackets.

## Known gaps (to build)

1. Plain bullets and numbered lists still show raw `-` and `1.`. Draw bullets, and style block quotes (a bar instead of `>`), tables, and horizontal rules.
2. Tapping a link does not open it yet. Image syntax is not rendered.
3. A checked item's text starts slightly further right than an unchecked one (the `x` is a different width than a space).
4. `~~~` fences, fences inside lists or quotes (the scanner handles ``` only).
5. A language label on code blocks, and auto-indent inside code on Return.
6. Tab and Shift-Tab to indent and outdent list items.
6. Dynamic Type changes are not re-applied to code fonts while the editor is open.
7. Fonts and themes from Spec 11 (settings).
8. Attachment and image syntax (Spec 07).
9. Find in note, spell check options for code, and an editor toolbar for the Mac.
10. ~~Local snapshots before an incoming sync overwrites a body (Spec 02, S2).~~ Dropped with Version History (2026-11-21).

## Acceptance tests

Automated (done, in `NotesCoreTests`): formatting commands (including out-of-range selections, emoji, and empty notes), fence scanning, and all grammar cases.

To run on devices (not yet verified):

1. On an iPhone, create a note and tap the ``` button: a block appears and the caret is after the fence. Type `swift`, press Return, type code: it is colored.
2. Move the caret out of the block: the fences disappear. Move it back in: they reappear.
3. Undo and redo after using each keyboard button.
4. Select text across a hidden fence and copy: the pasted text contains the real ``` lines.
5. **Japanese or Chinese input** keeps working while the highlight pass runs.
6. Resize the Mac window and the iPad Split View while typing.
7. Edit on one device, wait, and see the change on another without the cursor jumping on the device being edited.
8. Type 20,000 characters of mixed prose and code: no visible lag.
9. Rotate and use Dynamic Type at accessibility sizes: text and the keyboard bar stay usable.
10. On iPhone Duo (inner and outer display): the keyboard bar and editor adapt, and nothing sits under the camera region.
