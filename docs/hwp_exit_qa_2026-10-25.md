# HWP exit protection — 2026-10-25

## Changes

- HWP/HWPX editor routes intercept back navigation and ask whether to continue editing, discard unsaved edits or save then close.
- Workspace HWP tab close uses maybePop so nested route guards are respected. Loading/error routes still close when there is no guard.
- Save failure retains the editor. Repeated exit requests while a dialog/save is active are ignored.
- The native editor blocks pointer interaction and releases keyboard focus while saving.
- Successful host save marks the native editor controller clean as well as host state, so subsequent edits can mark the document dirty again.
- Imported original preservation and working-copy save behavior remain unchanged.

## Automated verification

- 320/840dp, Light/Dark: cancel, failed save, successful save, dialog layout.
- Nested first-route close: discard and clean close.
- Delayed save: no second save or premature close.
- Full suite: 90 passing tests; flutter analyze clean.

## Limits

- Process kill/crash recovery is not provided by an exit confirmation.
- Real stylus input and all native HWP formatting remain outside this pass.
- System dialogs and native editor menus require further interaction coverage; this is not all-app QA certification.

## 2026-10-26 runtime follow-up

- Cold-started Pixel 7. ADB text input had not proved a real edit; instead used the existing Page options > Two columns action on the QA HWP to create a native edit.
- Back showed the save confirmation. Continue editing retained the editor; a second back followed by discard returned to Home.
- Working-copy SHA-256 stayed `c310dc2d022bfbb2fcf1fd4441e7ad35cec6a5f548772f4d06636d3c9d7101ee`; original SHA-256 stayed `fd9b502ea0a0f68ead52ace80cd9bc190d6b72c0a49579da255f8852a2e6feac`. No test edit was saved.
- Screenshot: `build/qa/hwp-exit26.png`.
- Added scrollable content to the exit/page-jump dialogs, and Korean page/column/zoom tooltips and page-jump validation text. Exit tests now cover 320x640 portrait and 840x420 landscape in Light/Dark. All 90 tests pass; analysis clean.
- Important separate observation: changing this complex QA document to two columns produced overlapping text in the native preview. Discard restored the existing file; this test verifies exit safety, NOT column-layout fidelity. Native reflow remains a known issue to investigate before certifying structural HWP editing.
- Actual save-and-close and native Android failure injection remain unverified; automated save success/failure cases pass.
- Reopened the QA document after discard and visually confirmed its original single-column presentation (`build/qa/hwp-restored26.png`). Final Debug build succeeded in 175.5 seconds.
