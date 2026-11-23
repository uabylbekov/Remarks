# Equations and diagrams

The editor previews LaTeX math and Mermaid diagrams offline. Source mode, copy, undo, sync, and Markdown export retain the original text.

- Inline math: `$x^2 + y^2$`.
- Display math: `$$x^2 + y^2$$` on its own line, or opening and closing `$$` lines around a multiline equation.
- Diagrams: a fenced code block whose language is `mermaid`.
- Use Equation and Diagram in the Mac Format/More menus or the iOS keyboard formatting bar to insert editable examples.
- Place the caret in a preview to edit its source; move outside it to preview again. Invalid or unfinished syntax remains editable source.

```mermaid
flowchart LR
    A[Start] --> B[End]
```

Rendering uses bundled KaTeX 0.19.1 and Mermaid 12.3.0 from their official npm distributions. Resources and MIT licenses are in `Notes/Editor/RenderingResources`. KaTeX CSS references the adjacent WOFF2 fonts. Keep scripts, CSS, fonts, version markers, and licenses together when upgrading; rerun RichMarkdownTests and RichPreviewTests on both platforms.

An app-scoped nonpersistent WKWebView renders snapshots serially into native TextKit attachments; it is not the editor surface. Content Security Policy blocks network requests. KaTeX trust is disabled; Mermaid uses strict security, disables HTML flowchart labels, and rejects configuration directives and remote content. Inputs, graph edges, render time, snapshot dimensions, and cache memory are bounded. The renderer warms when the library appears, and its 32 MB snapshot cache survives editor teardown so revisiting notes can reuse completed previews. Each editor releases only its own pending callbacks; other windows continue rendering. Previews are static; diagram links are not interactive.

The core parser owns math/code precedence and inline delimiter escaping. Renderer scheduling, WebKit navigation/process recovery, and the shared LRU cache have separate owners; see [editor-engine-review.md](editor-engine-review.md). Inline equations carry a measured baseline and respect their surrounding element's font size.
