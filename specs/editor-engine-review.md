# Editor and live-preview engine review

Reviewed and refactored on 2026-11-23. Scope: native editor adapters, EditorSession, TextKit live-preview invalidation and projection, MarkdownDocument/InlineScanner, syntax highlighting, tables, attachments, and the math/diagram renderer. TextKit 2 remains responsible for native input, selection, undo, and scrolling; stored Markdown remains unchanged by presentation.

## Root causes corrected

| Area | Finding | Final behavior |
| --- | --- | --- |
| Parsing | Display and inline math were discovered through a second regex parser and masked with replacement characters for emphasis. Block parsing, formatting state, and Return handling could disagree. | Display math is a MarkdownDocument kind, backed by the same top-level fence scanner as code. Inline math is an InlineSpan kind and protects its literal contents from emphasis. RichMarkdown projects these parsed structures into render requests; it no longer implements another grammar. |
| Editing cost | Any changed rich-preview range escalated to a full-document attribute redraw, including ordinary edits before an equation. | TextKit receives the parser's affected range. Math-body edits remain incremental. Display-delimiter edits deliberately reparse the document because a delimiter can pair with a distant formerly unmatched delimiter. |
| Composition | Renderer/attachment callbacks could invalidate attributes while native marked text was active; sync and appearance changes could also replace or restyle composing text. | One invalidation gate defers async redraws. Marked paragraphs use native storage without a display projection. Sync, source-mode changes, and appearance updates wait for composition to finish; the latest requested state wins. |
| Persistence | Debounced saves had no explicit scene-background flush. | Inactive/background scene updates flush committed edits through the existing save path; uncommitted marked text is excluded. |
| Scheduling | Canceling and restarting a renderer allowed late completions to mutate a replacement worker's state or cache. | Each worker has a generation token. Obsolete results cannot publish, notify a new request, or clear the replacement worker. |
| Windows and typography | Pending requests were coalesced by source/style globally, allowing one window's width to replace another's. Repeated formulas at heading/body sizes also needed separate subscriptions. | Each editor owns subscriptions by content and style. Only its obsolete pending sizes are removed. Exact widths and font sizes in other consumers remain independent. |
| WebKit lifecycle | Readiness was polled; all render failures were remembered as invalid source, including process and navigation failures. | Navigation delegates resolve readiness and failures with bounded timeouts. Process termination resets the backend. Transient failures get one fresh-backend retry and a short expiring backoff; invalid syntax and explicit size limits are remembered separately. Resolved render timers are cleared. |
| Cache | Eviction was insertion ordered; replacing an entry could count its cost twice; a fixed scale estimate did not reflect the real bitmap. | A separate LRU cache owns the global 32 MB budget, accounts for actual bitmap bytes, and counts replacement keys once. Resizing can reuse a fitting cached image while the final snapshot renders. |
| Inline geometry | A fixed baseline offset raised inline equations above surrounding text; all snapshots used the body font size. | The HTML renderer measures each equation's text baseline. TextKit uses that baseline and the element's font size; both baseline and size scale together during resizing. |
| Line endings | Caret-at-end logic did not consistently recognize CR and Unicode paragraph/line separators. | Native LF, CRLF, CR, U+2028, and U+2029 endings are covered by parser and preview regression tests. A caret beyond the terminating newline does not reopen a math block. |

## Responsibilities after refactoring

- `MarkdownDocument`, `CodeBlockScanner`, and `InlineScanner`: source structure and literal-region precedence. `MathElement` handles editable display-math source.
- `LivePreviewController`: source selection and display-only projection, scoped invalidation, composition deferral, and element geometry.
- `EditorSession`: note identity, external edits, appearance/source-mode deferral, validated edits, undo integration, and save lifecycle.
- `RichPreviewRenderer`: per-editor subscriptions, coalescing, serial scheduling, failure policy, and generation-safe cancellation.
- `RichPreviewCache`: bounded reusable images and recency.
- `RichPreviewWebRenderer`: local WebKit navigation, process recovery, source rendering, snapshot limits, and baseline measurement.

## Verification

- macOS build succeeded. Full suite: 530 results; 518 passed, zero unexpected failures, three expected failures, nine iOS-only results not run on Mac.
- iPhone 18 Pro simulator build succeeded. 51 targeted engine/parser/renderer/transaction results passed, with no failures.
- Existing incremental/full-parse equivalence tests include math delimiters. Additional tests cover math/code precedence, escaped dollars and subscripts, native line endings, scoped math-body parsing, composition with sync and changing appearance/source mode, background saves, independent window widths and font sizes, late canceled completions, transient versus permanent failures, LRU accounting, cached note reopening, rapid resizing, and baseline scaling.
- Visually inspected the native Mac editor with prose, inline/display equations, a diagram, syntax-colored code, and a table. Rechecked inline fractions and heading equations after correcting baseline measurement.
- Removed the newly introduced cache constant's actor-isolation warning and the existing actor-isolated static fixture warnings in editor tests.

## Verification limits and retained constraints

Physical-device IME sessions, software/hardware keyboard transitions, and long-session memory behavior still need hands-on verification; controlled composition and scheduler tests do not substitute for those checks. The three expected failures are not newly fixed by this review.

A new equation or diagram still needs its first asynchronous snapshot; revisiting a cached note can reuse its completed preview immediately. Snapshots remain static, offline, and bounded by input, graph, dimensions, time, and shared cache limits. Unsupported/invalid syntax remains editable source. This refactor does not add unsupported diagram interactions or change the stored Markdown format.
