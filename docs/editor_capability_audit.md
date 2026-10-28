# Editor capability audit

Last reviewed: 2026-09-28

This document is a product gap audit, not a claim of feature parity with any
third-party product. DocNote uses its own UI, local storage, and assets.

## Implemented and connected

| Area | Current DocNote behavior | Verification target |
| --- | --- | --- |
| Pen | Pressure-aware vector strokes with smoothed pressure samples, deterministic pencil grain on committed/exported strokes, color/width presets, selectable ballpoint/fountain/pencil/marker behavior, autosave, undo/redo | Draw each type, reopen, export |
| Highlighter | Independent color, width, opacity, vector persistence | Draw over ink/PDF, reopen |
| Eraser | Partial and whole-stroke modes with independent size state | Both modes, undo/redo |
| Lasso | Freeform/rectangle selection plus direct tap selection of strokes, shapes, text and images; move, duplicate, delete, resize and rotate selected objects; in-document copy, cut and paste with new IDs, offset placement, autosave and undo/redo | Mixed-object selection, clipboard actions, save/reopen |
| Shapes | Line, arrow, rectangle, ellipse and triangle; outline color/width, optional translucent fill and dashed outline; pen Draw-and-Hold recognition for line/rectangle/ellipse | Create, hold, style, select, move, reopen |
| Text | Inline text, multiline editing, size, color, bold, italic, underline and alignment | Korean IME, edit, save/reopen |
| Images | Insert, select/move/resize/rotate and rectangular crop | Insert, crop, save/reopen |
| Editor control deck | Direct Pen, Eraser, Highlighter, Lasso, Shape, Text and Image actions with tool-specific quick controls | Phone/tablet, light/dark, overflow |

## Deliberate gaps — do not present these as implemented

| Priority | Capability | Current limitation | Safe implementation direction |
| --- | --- | --- |
| P1 | Object editing menu | A contextual menu appears near a lasso selection for copy, cut, paste, duplicate, rotate (shape/image), page-center alignment, delete, shape style, text color and image crop; the clipboard is intentionally in-memory and document-scoped (not the system clipboard) | Keep selection model; add only valid actions near its bounds |
| P1 | Shape appearance | Fill and dashed outline are supported; connectors, text-inside-shape and a shape library are not | Extend `DrawingShape` only with backward-compatible defaults |
| P1 | Text formatting | Bold, italic, underline and alignment are supported; font family, lists and line-spacing controls are not | Preserve Korean-capable fallback and use backward-compatible defaults |
| P1 | Image editing | Rectangular crop is supported; no freehand crop or filters | Keep attachment and `DrawingImage` model; add non-destructive crop data only |
| P2 | Writing behavior | Selectable pen types, pressure-aware vector strokes with short pressure smoothing, conservative Draw-and-Hold recognition, and optional low/medium/high input stabilization are supported; stylus-only mode is not | Validate Android stylus APIs before exposing stylus-priority controls |
| P2 | Page workflow | Page navigator has thumbnails, add-at-end, insert-empty-after-selection, duplicate, drag reorder, move buttons, single/multi delete, persistent per-page bookmarks, and named page sections with page assignment, rename and jump navigation. Page labels follow reorder/insert/delete and are stored as document-scoped local metadata. | Consider nested sections only after validating real notebook workflows. |
| P3 | Audio / synced replay | Not implemented | Separate feature: permission, local audio files, timeline and retention policy |
| P3 | Elements / tape / laser | Not implemented | Separate domain features; do not add inactive toolbar icons |

## Implementation order

1. Run editor regression tests and resolve only confirmed defects in the current tools.
2. Add a contextual object menu using the existing lasso selection IDs and undo snapshots.
3. Add backward-compatible shape appearance options and test PDF export.
4. Expand text formatting only after Korean IME and object selection regression tests pass.
5. Treat audio, elements and replay as separate, explicitly scoped releases.

## Reference baseline

Goodnotes documents direct toolbar access for pen, eraser, highlighter, shape,
lasso, image and text, plus a contextual object menu and more advanced optional
tools. DocNote matches the first group at the core workflow level, but does not
claim the latter advanced feature set yet. References: official Goodnotes
support articles for the [Android/Windows/Web toolbar](https://support.goodnotes.com/hc/en-us/articles/7378598719759-Get-Started-With-Goodnotes-for-Android-Windows-and-Web), [Lasso and object editing](https://support.goodnotes.com/hc/en-us/articles/7353695644175-Select-Move-and-Edit-Content-With-the-Lasso-Tool), and [Pen settings](https://support.goodnotes.com/hc/en-us/articles/7353756785679-Write-and-customize-ink-with-the-Pen-tool).
