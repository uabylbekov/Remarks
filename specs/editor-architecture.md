# Editor implementation baseline

Decision: retain TextKit 2 for native text input and live Markdown presentation. SwiftUI owns navigation, system
menus, settings, and presentations. Do not replace this engine or change viewport ownership as part of styling fixes.

## Responsibilities

| Component | Owns | Must not own |
|---|---|---|
| NotesCore | Source parsing, syntax tokens, validated TextEdit transactions | View geometry, keyboard insets, persistence timing |
| EditorSession | Note identity, composition protection, undo/save integration, external edits | Keyboard layout, toolbar appearance |
| LivePreviewController and elements | Display-only paragraphs, syntax colors, element metrics | Rewriting source, view safe areas |
| EditorContainer and EditorViewport | Which safe areas the editor reaches under, navigation toolbar, screen presentations, bounded editor allocation | Parsing, native selection, content-height measurement |
| NativeEditorViewController (iOS) | Pinning native input to the allocated viewport, turning the safe area and the keyboard overlap into content insets, native child-controller containment | Parsing, saving |
| Native text view | Selection, marked text, native input, scrolling and caret reveal | SwiftUI navigation |
| TableViewRegistry | Stable SwiftUI table hosts, placement from TextKit geometry, cell bounds conversion, revealing focused cells through native scrolling | Keyboard height estimates or document mutation outside TextEdit |
| EditorCommandCatalog | Discoverable formatting commands shared across iOS toolbar surfaces | Executing commands or saving notes |
| SwiftUI detail view | Querying the selected note and giving EditorContainer its note identity | Editor chrome, text view content insets, keyboard frame calculations |

## Stable contracts

1. Stored Markdown is the only document source. Presentation never changes copy, undo, or sync content.
2. Markdown marks are always hidden once they take effect; there is no source-view mode. Fenced code is colored by
   its language. Unknown languages and code bodies over the existing 60,000 UTF-16-unit highlighting limit remain plain code deliberately.
3. A paragraph style is fully configured before an immutable copy enters an attributed string.
4. The editor is a scroll view, so it fills the whole area under the bars and the keyboard, and whatever overlaps it
   is its content inset, as with List, ScrollView and a UITextView in a navigation controller. SwiftUI owns the
   allocation: EditorViewport ignores every safe area on iOS (navigation bar, home indicator, keyboard). The native
   controller pins the text view to that allocation and sets `contentInsetAdjustmentBehavior = .always`, because
   `.automatic` ignores content shorter than the view. UIKit supplies the bars' safe area itself. The keyboard overlap,
   which UIKit's `keyboardLayoutGuide` reports, is added to the safe area through `additionalSafeAreaInsets`. Text then
   starts below the bars, scrolls under them and under the keyboard bar, and stays clear of the keyboard at rest. There
   is no outer ScrollView, keyboard notification handling, or toolbar-height constant.
5. Formatting is implemented by NotesCore TextEdit transactions and applied through the platform coordinator and
   EditorSession. Toolbar surfaces do not edit the model directly.
6. On iOS every formatting command and the attachment menu are in one place, the bar above the keyboard: a scrolling
   glass capsule built from EditorCommandCatalog with a separate Hide Keyboard button, floating with a gap above the
   keyboard. It is SwiftUI (`KeyboardFormattingBar`) hosted as the text view's input accessory, because a UIKit text view
   has no SwiftUI focus for `.keyboard`. The accessory reports its own fitting height and uses a flexible-height
   autoresizing mask, so a zero frame cannot pin it flat. The navigation bar carries only the note's menu. The Mac
   keeps its window toolbar.
7. Document toolbar commands are disabled while a table cell owns input. Cell editing
   must never accidentally apply a command to the document’s previous selection.
8. A note switch replaces the editor identity. Composition is not interrupted by appearance or model updates.
9. New block behavior belongs in a MarkdownElement; changing a block must not change safe areas, toolbar layout, or
   persistence. New formatting commands must be added to the shared catalog and covered by a transaction test.
10. Code cards use NSTextLayoutFragment top/bottom margins and actual text-line bounds. Hidden code fences retain
    normal font metrics through a same-length display projection. Never move the caret independently of its line.

## Rendering integration

The native editor remains TextKit 2, embedded through Apple's representable APIs. SwiftUI TextEditor does not supply
this application's custom block-fragment and interactive Markdown table behavior. The keyboard accessory uses
UIKit's supported inputAccessoryView because the responder is a UITextView. These are explicit platform adapters.

Tables retain a hosted SwiftUI grid positioned from the native layout's reserved attachment geometry. An attachment
view-provider experiment produced a generic file icon in the running app despite passing provider metadata checks;
it was removed. Do not adopt it based on metadata or compilation alone. Any future replacement must demonstrate
visible cells, editing, focus preservation, source integrity, and resizing on both platforms before replacing this path.

EditorContainer can disable Markdown rendering for isolated viewport fixtures. This uses the same native input and
session path, so container regressions can be tested independently from element rendering.

## Checks required for editor changes

EditorPresentationTests imports the app in the existing hosted test target. It verifies syntax colors,
UTF-16 offsets after edits, unchanged source, formatting command coverage, native code-card/caret containment, and
SwiftUI container allocation during portrait/landscape resizing. NotesCore tests cover parsing and transactions.
These are complementary to device checks.

For viewport or toolbar changes, check iPhone and iPad in portrait and landscape, narrow and wide columns, empty and
long notes, code, tables, attachments, software keyboard, hardware keyboard, and keyboard dismissal.
Confirm first/last lines and caret visibility. For rendering changes, also check macOS and light/dark appearance.
Use disposable/in-memory fixtures; do not type into an existing user note during validation.

This decision freezes ownership boundaries, not a claim of production readiness. A software-keyboard check blocked by
simulator configuration remains an open release check. Do not report it as passed from hardware-keyboard evidence.
