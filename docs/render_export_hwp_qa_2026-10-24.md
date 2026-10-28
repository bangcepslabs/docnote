# PDF rendering / HWP preservation QA — 2026-10-24

## PDF

- Removed the duplicate export stroke renderer. Export now calls the editor's committed renderer through a logical-page-to-raster transform.
- Shared rendering preserves quadratic curves, per-pen pressure responses, pencil texture, opacity, shape geometry and endpoints. No sampling, input, history or persisted Stroke changes.
- Legacy clear-blend eraser strokes use an isolated ink layer so they do not clear PDF background pixels.
- Export raster image, picture and codec are explicitly released after composition.
- 20 deterministic image comparisons pass at 2x output scale: four pen types with varying pressure, highlighter, arrow, ellipse and triangle. These are automated raster comparisons, not a physical stylus pressure test.
- Existing suite plus renderer tests: 77 pass.

## HWP

- Pixel 7: existing QA HWP opened, 204 pages detected; next-page navigation rendered Korean content on page 2. Screenshot: `build/qa/hwp-page2.png`.
- Found save writing directly to the imported source. Changed save to `working/edited.hwp`, with temporary-file write and rename; open prefers an existing working file. Original source is not rewritten.
- Working file is HWP because the existing export callback explicitly requests HWP, including for HWPX inputs. The original HWPX is preserved; no claim of HWPX round-trip editing fidelity.
- File-store test passes: original preserved, first save/repeated save/reopen, empty export rejected, temporary file cleaned.
- Before-save original SHA-256: `fd9b502ea0a0f68ead52ace80cd9bc190d6b72c0a49579da255f8852a2e6feac`.
- Additional observed issue: library reports this HWP as 1 page while native editor detects 204. Metadata synchronization is not fixed in this change.
- Physical pressure input, all HWP formatting fidelity, and unsaved-edit exit handling are not certified by these tests.

## Final device run

- flutter analyze clean. 77-test suite plus the additional HWP store test passed (78 total).
- Final Debug x64 APK build succeeded in 49.9 seconds and was installed on Pixel 7.
- HWP save displayed the success message and produced `working/edited.hwp` (252416 bytes).
- Original SHA-256 after save is identical to the value above. Reopening loaded the working copy successfully and reported 204 pages.
- This run saved the existing QA document without editing its text; it is not certification of arbitrary HWP layout/editing round-trips.
- PDF changes have automated renderer coverage; a fresh exported PDF visual review with the final APK remains pending.
