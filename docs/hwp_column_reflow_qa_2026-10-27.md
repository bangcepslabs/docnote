# HWP column reflow QA — 2026-10-27

## Scope and causes

- `set_column_def_native` previously recomposed/paginated existing line segments without reflowing them for the new column width. Imported full-width line breaks could therefore cross into an adjacent column.
- `ColumnDef.raw_attr` also retained the imported column count/type/same-width flags. The serializer preferred these stale bits, so reopening could use different columns from the editor.
- Reflow the affected initial column range, recalculate subsequent paragraph positions, then reuse existing composition/pagination/cache invalidation. Do not reflow line widths after a later explicit column definition.
- Update only edited raw attribute bits, preserving direction/reserved bits. No changes to Flutter toolbar, drawing engine, original-file storage policy or undo implementation.
- Refresh native editor page-count status after immediate/deferred edits and history restoration; previously it retained the opening count even after repagination.

## Automated verification

- Rust regression: 1 → 2 → 3 → 1 columns, narrower stored line widths, increased line count, non-overlapping consecutive line positions, content preservation, save/reopen page-count equality.
- Rust regression: later column range retains its line breaks/widths; native snapshot restore reproduces pre-edit exported bytes.
- Explicit ignored test can run against a local disposable copy using `DOCNOTE_HWP_QA_INPUT`; no user file is modified or included as a fixture.
- Local 204-page QA document: 2 columns = 202 pages, 3 columns = 202 pages, subsequent 1 column = 203 pages. Saved/reopened counts match each edited state. Text remains unchanged. Reflow is not guaranteed to reconstruct imported manual layout exactly by switching back to one column; Undo/discard restores the original instead.
- `flutter analyze`: no issues.
- HWP working-copy/exit tests: 7 passed.

## Runtime verification

- Rebuilt native Debug APK and installed on Pixel 7. Applied Page options > 2 columns to the same QA document, inspected first page and next body page.
- Body lines now wrap into their columns instead of retaining full-page line widths. Capture: `build/qa/hwp-columns-body27.png`.
- **Remaining defect:** the cover's fixed-position, full-width decoration/title overlaps newly reflowed body content on page 1. This is NOT a complete column-layout fidelity fix. Capture: `build/qa/hwp-columns-after27.png`; prior result: `build/qa/hwp-exit26.png`.
- Native Edit > Undo restored the single-column cover/body arrangement. Capture: `build/qa/hwp-undo27.png`.
- Discarded test edits. Native save/reopen was tested on disposable host copies; no changed column layout was saved into the device working copy.
- Final Debug build including page-count refresh succeeded. Pixel 7 status now changes `1 / 204` → `1 / 202` after two columns → `1 / 204` after Undo → `1 / 202` after Redo.
- Discarded final test edits; SHA-256 remained unchanged: original `fd9b502ea0a0f68ead52ace80cd9bc190d6b72c0a49579da255f8852a2e6feac`, working copy `c310dc2d022bfbb2fcf1fd4441e7ad35cec6a5f548772f4d06636d3c9d7101ee`.

## Test commands

```powershell
cargo test --manifest-path third_party/flutter_rhwp/rust/Cargo.toml --lib column_reflow
$env:DOCNOTE_HWP_QA_INPUT = 'G:\Bang\DocNote\build\qa\hwp-column-source.hwp'
cargo test --manifest-path third_party/flutter_rhwp/rust/Cargo.toml --lib column_reflow_qa_document -- --ignored --nocapture
flutter test test/hwp_working_store_test.dart test/hwp_exit_guard_test.dart
flutter analyze
flutter build apk --debug --target-platform android-x64
```

Host Rust testing reports an incremental-cache access warning; tests execute successfully. Android build is separate and does not use that host test binary.

## Cover overlap follow-up

The cover title/decorations in the QA document are a full-width inline table (`treat_as_char`, `TopAndBottom`), not independent fixed-position shapes. Its absolute width remains wider than an individual column. Existing cross-column space reservation excluded inline tables.

- Empty paragraph reflow now preserves valid original line metrics and accounts for inline table height/margins. Previously it replaced even a table-host paragraph with a default short line.
- The production typesetter reserves the occupied height of whole, body-wide inline tables for following columns on the same page. Reservation resets on a new page.
- Layout obtains the actual rendered table bottom after laying out its own column and applies the existing exclusion path to subsequent columns. The table itself is not shifted, scaled or hidden.
- On these pages, pagination follows the same paragraph-position correction as layout. A paragraph continuing in the next column also subtracts the reserved height from its remaining space.
- Scope: whole `TopAndBottom` inline tables in the first column meeting the existing body-wide criterion (at least 80% of body width). This is not a general rewrite of arbitrary overlapping shapes or fragmented tables.

Verification before emulator installation:

- Rust host suite: 23 passed, 1 explicit local-fixture test ignored by default.
- Local-fixture run: 4 column tests passed, including the real QA copy.
- Synthetic 2/3-column fixture and QA cover: body text bounds do not intersect the table and do not extend below the column. These are render-tree geometry assertions, not just line-count assertions.
- QA copy: 2 columns = 203 pages; 3 columns = 203; back to 1 column = 204. Save/reopen page counts match and body text is retained.
- Flutter analysis: no issues.
- Native Debug APK build succeeded (211.2 seconds), installed on Pixel 7. Visual verification follows below.

### Pixel 7 results

- Applied 2 columns: cover table/title/decorations remain visible; right-column body starts below the table, with no overlap. `build/qa/hwp-cover-fixed27.png`.
- Inspected next body page: normal full-height flow resumes, without carrying the cover reservation onto page 2. `build/qa/hwp-cover-body-fixed27.png`.
- Applied 3 columns: both subsequent columns avoid the cover table. `build/qa/hwp-cover-three-fixed27.png`.
- Undo twice restores original 204-page single-column arrangement (`build/qa/hwp-cover-restored27.png`); Redo returns to 203-page two-column layout.
- Discarded test edits. Original and working-copy SHA-256 still match the values above. No test edit was saved on device.
- Current-process log scan: no Flutter exceptions, RenderFlex overflow or native LAYOUT_OVERFLOW messages during this run.
- The specific previously recorded cover/body overlap is resolved. Changing an entire section to multiple columns still reflows dates, labels and body text; this is not a promise of unchanged page design or universal HWP layout equivalence.
