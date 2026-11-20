# Spike 02: Highlighter (native regex grammar engine)

Status: **Complete (2026-11-19).** Decision: build our own grammar-driven highlighter on `NSRegularExpression`. Apple frameworks only, no packages.

## What was built

Code: `Notes/Notes/Spikes/SpikeGrammarEngine.swift`, `SpikeGrammars.swift`, `SpikeHighlightLab.swift`. Wired into the TextKit editors (B and C) so fenced blocks are highlighted by the language on the opening fence line.

- **Grammar** = a `Codable` value: name, aliases, `ignoresCase`, and an **ordered list of rules** (scope + regex pattern). Rule order is priority.
- **Engine** joins all rules into **one alternation** and scans once, left to right. Because the scan is single-pass, a comment or string consumes its text before any later rule can see it. (A first design idea, running each rule independently and merging, would let an apostrophe inside a comment start a bogus string. The single pass avoids that class of bug.)
- **Scopes (10):** comment, string, keyword, number, type, function, attribute, constant, property, variable. These are the token kinds a theme must style (Spec 11).
- **Constraint:** rule patterns must use non-capturing groups. The engine refuses a grammar whose capture-group count differs from its rule count.
- **Languages (9):** Swift, Python, JavaScript/TypeScript, JSON, Shell, SQL, Rust, Go, C/C++ (with aliases such as `js`, `ts`, `py`, `sh`, `zsh`, `rs`, `golang`, `objc`).

## Results

All timings are from a **debug build** on a MacBook Air, so release builds should be faster. Single runs.

**Correctness: 19 passed, 0 failed, 3 known limits (all predicted), 0 unexpected passes.** All 9 grammars compile.

| Area | Result |
|---|---|
| Keyword inside string or comment | Correct (not highlighted as keyword) |
| Multi-line block comments and multi-line strings (Swift, Python, Go raw strings) | Correct |
| Unterminated string | Stops at end of line, so it cannot swallow the rest of the block |
| Emoji and accented characters | UTF-16 ranges stay correct |
| Case-insensitive SQL, escaped `''` | Correct |
| JSON keys vs. values, numbers, constants | Correct |
| Decorators, attributes, preprocessor, macros, lifetimes vs. char literals | Correct for the cases tested |
| Template literals (JS) | Correct, but `${...}` content is not highlighted separately |

**Known limits (regex cannot do these, as expected):**
1. **Nested block comments** (Swift, Rust): the comment ends at the first `*/`. The rest of the comment is misread, then the engine recovers by the next statement.
2. **String interpolation containing quotes** (Swift `"a \("b") c"`): the string is split into two. Plain interpolation without nested quotes is fine.
3. **JavaScript regex literals**: not recognized, because `/` is ambiguous with division without parsing context. They stay unstyled.

Also not supported by design: shell heredocs, highlighting code inside interpolations, embedded languages (JS inside HTML), and HTML/CSS/Markdown-in-Markdown (nested grammars). These need a stack-based grammar, not a single regex.

**Performance (Swift, debug build):**

| Input | Time |
|---|---|
| 81 lines (3 KB) | 1.1 ms |
| 801 lines (31 KB) | 10 ms |
| 8,001 lines (314 KB) | 103 ms |
| One 9-line block inside a 9,000-line document | 0.11 ms |

Cost is linear in code size. Because we highlight per fenced block, a normal edit re-highlights one block, which is far below a frame.

## Decision and consequences

- **Go with our own engine.** It handles the languages notes users paste most, within known limits, with zero dependencies.
- **Quality bar:** "good enough", not editor-grade. Document the three known limits. Nested grammars (HTML, Markdown, JSX) are out of v1.
- **Grammar as data:** keep grammars as `Codable` values. Moving them to bundled JSON files later is mechanical, and would allow user-supplied grammars after v1.
- **Per-block highlighting:** highlight each fenced block separately using the language on its fence line. Unknown or missing languages are left unstyled. Consider auto-detection later, but not for v1.
- **Incremental strategy:** on an edit, re-highlight only the block containing the edit.
- **Theme schema (Spec 11):** themes map the 10 scopes to colors (plus background and base text color). Unknown scopes fall back to the base text color (T6).
- **Contrast:** the spike's colors are system colors and not tuned. Real themes must be checked against G6.

## Open items for Spec 05

- Language auto-detect when the fence has no info string.
- Handling of 4+ backtick fences, `~~~`, and fences inside lists (shared with the editor's scanner).
- A grammar-authoring guide and a test corpus per language.
- Whether to add HTML, CSS, YAML, Markdown, Kotlin, Java, PHP, Ruby, TOML, and Dockerfile for v1. Each is an hour or so of grammar work plus tests, except HTML and Markdown, which need nesting.
- Overlapping rules for lower-priority scopes, such as a type or function name inside a string, are already handled by the single pass.
