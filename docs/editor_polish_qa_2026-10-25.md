# Editor polish and remaining quality work — 2026-10-25

## Implemented

- PDF: toolbar 60dp to 52dp on mobile; destructive page clear moved into page actions popup with existing confirmation callback retained. Removed text/image/sticker menu entries whose callbacks did nothing. Existing tools, presets, Undo/Redo and horizontal scrolling preserved.
- HWP mobile status: neutral page number typography, compact `current / total`, Korean fit/previous/next tooltips. Navigation and zoom callbacks unchanged.
- HWP metadata: resolve native page count and persist to library without changing modified timestamp. Metadata failures do not prevent the document from opening.
- HWP lifecycle: close a document returned by asynchronous open if the widget was already disposed.

## Verification

- PDF toolbar tests: 320/412/840dp, Light/Dark, 52dp height, horizontal scroll to actions, clear callback, no placeholder image/text actions: six cases pass.
- Full test suite: 84 pass, including rerun after the metadata follow-up. flutter analyze clean.
- Pixel 7 screenshot checks: `build/qa/pdf-design25.png`, `build/qa/hwp-design25.png`. No visible overflow in these captured screens.
- Home and the established notebook toolbar layout remain unchanged.
- Final Debug x64 build succeeded (201.7 seconds), installed on Pixel 7. Opened the QA HWP and returned to Home: library now displays `HWP · 204페이지` instead of 1. This validates the page-count callback with the native document.

## Not yet certified

- All editor dialogs in all themes, rotations and tablet sizes.
- HWP unsaved-edit exit safety, embedded document-tab close, and save-vs-edit concurrency.
- HWP editing fidelity across varied real-world source files.
- Physical stylus pressure/latency and release-device performance.
- Final PDF export visual check after shared renderer integration (automated renderer comparisons already passed).

This is a bounded improvement pass, not a claim that every app issue is resolved.
