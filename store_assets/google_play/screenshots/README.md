# Google Play screenshots

2026-10-30 기준 동일 소스의 서명된 x86_64 릴리즈 APK를 별도 Pixel 7 / Pixel Tablet QA 에뮬레이터에 설치해 촬영했다. 사용자 데이터는 사용하지 않았다. `build/qa`의 원본 PNG에서 화면 가장자리의 에뮬레이터 포커스선이 있으면 외곽 2픽셀만 제거하고 JPEG 품질 95로 저장했다. 앱 UI를 합성하거나 수정하지 않았다.

## Phone

1080 × 2160 JPEG, 세로 1:2.

1. `phone/01-home-library.jpg` — 노트 표지와 HWP 첫 페이지 미리보기가 있는 홈.
2. `phone/02-notebook-editor.jpg` — 텍스트·획과 통합 툴바가 보이는 노트 편집기.
3. `phone/03-hwp-document.jpg` — HWP 문서 첫 페이지와 페이지 이동.
4. `phone/04-create-sheet.jpg` — 새 노트·빠른 필기·문서 가져오기 메뉴.
5. `phone/05-search-results.jpg` — 노트 검색 결과.

## Tablet

1920 × 1080 JPEG, 가로 16:9.

1. `tablet/01-tablet-home.jpg` — 태블릿 홈과 최근 문서.
2. `tablet/02-tablet-documents.jpg` — HWP와 노트 표지가 있는 문서 라이브러리.
3. `tablet/03-tablet-notebook-editor.jpg` — 문서 탭과 통합 툴바가 보이는 노트 편집기.
4. `tablet/04-tablet-create-sheet.jpg` — 태블릿 새로 만들기 메뉴.
5. `tablet/05-tablet-search.jpg` — 태블릿 검색 결과.

스토어 업로드 전 Play Console 미리보기에서 텍스트 판독과 이미지 순서를 다시 확인한다. 출시 트랙에 올릴 AAB는 ARM 실기기 및 내부 테스트 검증이 아직 필요하다.
