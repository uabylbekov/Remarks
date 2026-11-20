# Platform Design: iPhone Duo and Liquid Glass

Status: Draft v0.1 (2026-11-19). Cross-cutting: every feature spec must satisfy this one.

Sources: Apple Human Interface Guidelines ("Designing for iPhone Duo", "Materials: Liquid Glass", "Layout") and SwiftUI documentation, found through the Xcode documentation search. Items marked **Verify** were not confirmed in the docs.

## 1. Goals

1. The app adapts correctly to every iPhone Duo pose and display (outer, inner, partially folded, Split View).
2. The app looks native under Liquid Glass on iOS, iPadOS, and macOS, by using system components wherever possible.

## 2. iPhone Duo

### What the docs say
- Two displays: a compact-width outer display and a regular-width inner display, with a hinge and a *folding region* when partially open.
- Standard components adapt automatically: split views, alerts, menus, and sheets adjust to the fold.
- Toolbars, tab bars, and navigation controls move to the **side** on the outer display and on the inner display in landscape. The inner display in portrait keeps horizontal bars.
- Apple's own example for a Notes-style app: a split view with a list pane and a content pane, with the pane widths adjusting as the device folds.
- Relevant APIs named in the docs: `NavigationSplitView`, `ReservedRegion`, `ArrangementView`, `ToolbarItemVisibilityPriority`, `ToolbarVerticalCompressionBehavior`, `ToolbarOverflowMenu`, `ToolbarItemGroup`, and safe area insets. Device Hub in Xcode previews the device and its poses.

### Requirements

| ID | Requirement |
|---|---|
| D1 | Layout is driven by **size classes and safe areas**, never by device idiom, orientation, or fixed widths |
| D2 | Navigation uses `NavigationSplitView`: folders, note list, editor. The outer display collapses to one pane at a time, and the inner display shows two or three |
| D3 | The same functionality is reachable in every pose. Layout may change, features may not |
| D4 | Toolbar items have **both a title and a symbol**, are grouped with `ToolbarItemGroup`, and carry a visibility priority so frequent actions (New Note, Done) stay visible and the rest overflow |
| D5 | Do not override default bar placement or hard-code spacing between toolbar items |
| D6 | The editor tolerates **asymmetric** safe areas, because controls sit on one edge |
| D7 | Content stays clear of the folding region. Use `ReservedRegion` for custom elements the system does not move |
| D8 | Folding causes small adjustments only. Avoid dramatic rearrangement while the device folds |
| D9 | The keyboard accessory and formatting controls must work when the toolbar is on the side. Consider the formatting bar as part of the editor, not the window toolbar. **Verify** against the editor spike |
| D10 | In a grid layout (for example a gallery view of notes), prefer an even number of columns so content divides cleanly at the fold |

### Verify
- Which OS release introduces the Duo APIs (`ReservedRegion`, `ArrangementView`). We target 27, so this should be fine, but the docs search did not state availability.
- Whether `TextEditor` with `AttributedString` behaves correctly when its container resizes live and the fold changes the available area. Add this to the editor spike.

## 3. Liquid Glass

### What the docs say
- Liquid Glass is a **functional layer** for controls and navigation (tab bars, sidebars, toolbars) that floats above content.
- **Do not use it in the content layer.** Use standard materials for content backgrounds.
- Standard system components adopt it automatically. Custom use should be sparing.
- Two variants: `regular` (default, legible) and `clear` (only over visually rich media, with a dimming layer).
- Apply color sparingly, and prefer tinting the background of the primary action only.
- For multiple custom glass views, use `GlassEffectContainer`. Related APIs: `glassEffect(_:in:)`, `glassEffectUnion`, `glassEffectID`.
- Appearance changes with system settings, including Reduce Transparency and Increase Contrast.

### Requirements

| ID | Requirement |
|---|---|
| G1 | Use **standard SwiftUI components** (`NavigationSplitView`, toolbars, tab views, sheets) first. Do not recreate their glass by hand |
| G2 | The **note text area and code blocks are the content layer**. They get no glass. Use standard materials or plain backgrounds |
| G3 | Custom glass is limited to a small set of floating functional elements, for example a floating formatting bar or a quick-capture button, and always inside a `GlassEffectContainer` |
| G4 | Use the `regular` variant by default. `clear` is not used unless a spec justifies it |
| G5 | Accent color on glass is limited to the single primary action per screen |
| G6 | Syntax highlight colors must keep sufficient contrast in light, dark, Increase Contrast, and Reduce Transparency, including when content scrolls under glass bars |
| G7 | Widgets use accented rendering modes appropriately. Notes content in widgets should stay legible when the system tints it |
| G8 | Do not set legacy bar appearances that fight the system material. **Verify** whether any are needed for the editor |

## 4. Impact on the plan

| Area | Change |
|---|---|
| Spec 03 (Markdown editor) | Must include the Duo resize behavior (D6, D8, D9) and the "text area is content layer" rule (G2). Add both to the editor spike criteria |
| Spec 04 (Organization) | Navigation structure follows D2. Note-list grid follows D10 |
| Spec 05 (Code blocks) | Contrast requirement G6 and no glass behind code (G2) |
| Spec 06 (App Intents) | Not affected |
| Milestone M0 | Add the project checklist below |
| Milestone M5 | Duo and Liquid Glass checks are part of the release exit criteria |
| Testing | Preview and test in Device Hub across Duo poses, plus Reduce Transparency and Increase Contrast |

## 5. Project checklist for M0

Before feature work, confirm the project settings. These come from the resizability guidance and are read-only checks, not changes:

1. **Launch screen:** the target declares one. iOS 27 rejects App Store uploads without one (`ITMS-90870`, see TN3208).
2. **iPad orientations:** all four are supported, so the scene can resize.
3. **Full screen opt-out:** do not set `UIRequiresFullScreen`. iOS 27 ignores it and resizes the scene anyway (see TN3192).
4. **Scene lifecycle:** use the SwiftUI `App` lifecycle (already the case in `MyApp.swift`), so no UIKit scene migration is needed.

## 6. Acceptance criteria (applies to every feature spec)

- Works on iPhone, iPhone Duo (outer, inner, partially folded, Split View), iPad (including Split View and Stage Manager), and Mac with a freely resizable window.
- No fixed widths, no `UIScreen.main`, no idiom or orientation checks for layout.
- No custom glass in the content layer. Custom glass is justified in the feature spec.
- Passes with Dynamic Type at accessibility sizes, Reduce Transparency, and Increase Contrast.
