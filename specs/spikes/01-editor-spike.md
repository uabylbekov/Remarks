# Spike 01: Editor (TextEditor + AttributedString vs. TextKit 2)

Status: **Complete (2026-11-19). Decision: TextKit 2 editor with live preview.** The user ran the Mac app (option C) and reported it looks good with the known gaps listed under Spike 01b. Remaining gaps are implementation work for Spec 03, not open questions. Not individually reported back: IME input and live window resize, so keep those as acceptance tests in Spec 03.

## Cleanup note (2026-11-19)

Option A (`TextEditor` + `AttributedString`) was removed from the spike app after the decision, and `SpikeAttributedEditor.swift` was deleted. Switching to it in the picker was noticeably laggy for the user. The cause was not measured. Everything below that mentions A describes what was tested before removal.

## Setup

- Code: `Notes/Notes/Spikes/` (inside the app target so it builds and previews). **Delete before M0.**
- Test note: ~50,000 characters (and 200,000 for timing), prose plus fenced Swift blocks.
- Highlighter: a throwaway regex tokenizer. It exercises the editors and says nothing about which highlighting engine to choose (that is a separate spike).
- Option A: `TextEditor(text: Binding<AttributedString>, selection: Binding<AttributedTextSelection>?)`. After a 150 ms debounce it recolors tokens and assigns the whole `AttributedString` back.
- Option B: TextKit 2 text view (`UITextView(usingTextLayoutManager: true)` / `NSTextView`) in a representable. After a 150 ms debounce it edits `foregroundColor` on the text storage in place.

## Measured

All timings come from **debug builds** (unoptimized), single runs, so treat them as order-of-magnitude. Pure compute was run on macOS.

| Step | 50k chars | 200k chars |
|---|---|---|
| Tokenize (regex) | 3.0 ms | 9.0 ms |
| Apply colors to `AttributedString` | 6.0 ms | 25.4 ms |
| Apply colors to `NSMutableAttributedString` | 0.3 ms | 1.0 ms |
| `String(attributedString.characters)` | 0.01 ms | 0.03 ms |

- The `AttributedString` path is roughly 20x slower than in-place text storage edits, but both are small next to a 150 ms debounce. Not a blocker at note sizes we expect.
- End-to-end footer readings from the previews (include the state update): A 9.2 ms (Mac), 21.4 ms (Duo outer), 14.2 ms (Duo inner). B 20.5 ms (Duo outer), 7.6 to 7.9 ms (Duo inner). These are single, noisy samples.

## Verified

- Both editors render correctly highlighted code on **macOS** and on the **iPhone Duo** simulator, outer and inner display, portrait and landscape.
- `Range<AttributedString.Index>(NSRange, in:)` exists, and `AttributedTextSelection()` initializes with defaults. Both compile and run.
- The preview tool offers Duo variants (Display: Outer/Inner, Orientation, Dynamic Type, Increase Contrast), so Duo checks can be done without hardware.
- Neither text area uses glass (G2 in `00-platform-design.md`).

## Not verified (needs interactive testing)

These are the criteria that actually decide the choice, and I could not test them from static renders:

1. **Typing latency** on the 50k note, especially while a highlight pass lands.
2. **Undo/redo integrity.** A reassigns the whole `AttributedString`, which may disturb the undo stack. B edits attributes in place and should not.
3. **Caret and selection after a highlight pass** in A. Does `selection` survive `text = updated`?
4. **IME and marked text** (for example Japanese or Chinese input) during a highlight pass.
5. **Live resize and folding**, meaning partial-fold poses, not just the two displays.
6. **VoiceOver and Dynamic Type** at accessibility sizes.
7. **Layout around the Duo camera region** (the preview showed a black circle at the top right of the outer display, and text can run under it).

## Observations

- B first shows uncolored text for one frame, then colors it. A static snapshot taken immediately after launch caught the uncolored frame. After a 3 s delay it matched A. In a real app, highlight the initial text before first display to avoid a flash.
- A and B used different default font sizes, so line spacing differs. Not a real difference between the approaches.
- B needs two platform wrappers (UIKit and AppKit). A is one SwiftUI view.

## Preliminary lean (not a decision)

- **A** is far less code and fast enough. Its risk is editing integrity: undo, caret, and IME when the whole string is reassigned.
- **B** keeps attribute changes out of undo and selection by construction, at the cost of two wrappers and less SwiftUI-native behavior.
- ~~Choose after items 1 to 4 above are tested. If A passes all four, prefer A.~~ Superseded by the live-preview decision below.

## Decision driver: live preview (2026-11-19)

Running the spike as a real app showed that raw-source coloring is not the look we want. **Decided:** Bear/Obsidian-style live preview.

- Prose uses the text font. Code blocks use the code font on a block background.
- Markdown marks (the ``` fences, `#`, `**`, and so on) are **hidden except on the line being edited**.

What this needs from the editor:

| Need | TextKit 2 (B) | `TextEditor` + `AttributedString` (A) |
|---|---|---|
| Different fonts per range (text vs. code) | Yes, attributes on the text storage | Yes, attributes |
| Code block background spanning the block | Custom layout fragment or paragraph decoration (to be built) | No API found for block backgrounds. Unverified |
| Hide marks except on the active line | Substitute or restyle paragraphs per selection (to be built) | No API found for hiding characters. Unverified |
| Keep Markdown text as the source of truth | Yes, because hiding is presentation only | Same, if hiding were possible |

**Lean (updated):** B, because live preview depends on custom layout, which TextKit 2 provides. A would have to demonstrate block backgrounds and hiding before it is a candidate, and I found no API for either. This is a lean, not a proof: the hiding and block-background techniques have not been prototyped yet.

**Next editor spike (Spike 01b):** prototype in B (1) hiding fence lines when the caret is outside the block, (2) a code block background, (3) separate text and code fonts, (4) the caret moving into and out of a hidden region without jumping, and (5) selection, copy, and undo still operating on the real Markdown text.

## Spike 01b: live preview in TextKit 2 (2026-11-19)

Code: `Spikes/SpikeLivePreview.swift`, wired into `SpikeTextKitEditor(livePreview: true)`. The host picker option is "C: Live preview".

**Technique (no characters are ever changed):**
- A line scanner finds fenced blocks in the Markdown text.
- `NSTextContentStorageDelegate.textContentStorage(_:textParagraphWith:)` returns a restyled copy of each paragraph for display only. The stored text is untouched, so selection, copy, undo, and the Markdown source of truth are unaffected by design.
- Hidden marks: transparent color, 1 pt font, and (for whole fence lines) a 0.01 pt line height, so the line takes almost no space.
- Fonts: prose font for prose, code font for code lines, bold sized fonts for headings.
- Code block background: `NSTextLayoutManagerDelegate` returns a custom `NSTextLayoutFragment` subclass that fills the full container width. It overrides `renderingSurfaceBounds`, because otherwise the wider fill is clipped.
- Active region: on a selection change, the paragraph delegate is re-run for the old and new caret lines and the old and new code blocks, using `NSTextStorage.edited(.editedAttributes, …)` inside `performEditingTransaction`.

**Verified (static renders):**

| Check | Result |
|---|---|
| Fence lines hidden outside the caret region | Works on macOS and iPhone Duo (inner display, landscape) |
| Full-width code block background | Works on both |
| Separate text and code fonts | Works on both |
| `#` markers hidden on inactive headings, shown on the active line | Works. The first heading kept its `# ` because the caret starts on that line |
| Syntax colors still apply on top | Works |
| One shared implementation for UIKit and AppKit | Yes. Only the text view and selection callbacks differ. A first iOS build failed because `UITextView` has no `textContentStorage`. It is reached through `textLayoutManager.textContentManager` |

**Not verified (needs hands-on testing in the real Mac app, picker option C):**
1. Click or arrow into a code block: do the fences appear, and does the caret stay put?
2. Arrow up or down through a hidden fence line: does the caret get stuck or skip an invisible line?
3. Select text across a hidden fence and copy it: does the clipboard contain the real ``` lines?
4. Undo and redo after typing in and around a block.
5. Type a new ``` line to create a block, and delete one.
6. Scrolling performance and layout invalidation cost on the 50k note.

**Known gaps in the spike (not problems with the approach):**
- No rounded corners or inner padding on the code block, and no language label.
- Only `#` headings are handled. Bold, italic, links, lists, quotes, and tables are not styled or hidden yet.
- The fence scanner is line-based and does not handle fences with 4+ backticks, `~~~`, or fences inside lists.
- The hidden fence line still exists as a near-zero-height line, so the caret can land on it.

**Verdict so far:** TextKit 2 can do live preview with modest code (about 240 lines for fences and headings). The open risk is caret and selection behavior around hidden lines, which only interactive testing can answer.

## Interactive results so far (user, running as a real Mac app)

- Typing did **not lag** (the user did not specify which editor, so treat as both until stated).
- Code highlighting works. Fence marks remain visible and prose uses the code font, which is the raw-source look and what led to the decision above.
- Not yet reported: undo/redo, cursor stability, input methods, and live resize. The earlier shortcut failure (⌘Z/C/V/A) was in the preview canvas, which has no menu bar. `allowsUndo` was missing in B on macOS and is fixed.

## Findings about the project itself

| Finding | Action |
|---|---|
| Deployment targets are already 27.2 for iOS and macOS | Matches the minimum OS decision |
| `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | Pure logic (highlighter, parser) must be marked `nonisolated` or live in the `NotesCore` package, which has its own setting |
| Supported platforms included visionOS (`xros`), device family `1,2,7` | **Resolved 2026-11-19:** visionOS removed. `SUPPORTED_PLATFORMS` is now `iphoneos iphonesimulator macosx` and `TARGETED_DEVICE_FAMILY` is `1,2`. Build verified. Easy to add back later |
| `INFOPLIST_KEY_UILaunchScreen_Generation` is empty | M0 checklist item: add a launch screen setting |
| Bundle ID is a placeholder (`devplaceholder.*`) | Set a real bundle ID before the iCloud container is created |
| `DEVELOPMENT_TEAM` is set | A team is configured. Whether it is a paid program is not confirmed |
