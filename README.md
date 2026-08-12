# DocNote

PDF·HWP/HWPX 문서와 일반 메모, 벡터 필기를 한 곳에서 관리하는 한국어 Android 우선 Flutter MVP입니다.

## 현재 구현

- Material 3 기반 홈/문서/검색/설정 하단 내비게이션
- 새 메모 및 실제 필기 노트 생성·편집 흐름
- `UnifiedNoteEditor`에서 제목·본문·체크리스트·이미지 첨부·필기 모드를 하나의 노트로 편집
- 빠른 메모 생성 후 즉시 에디터 포커스, 자동 저장, 빈 메모 정리
- 홈·전체 문서·검색 결과가 공통 `openDocument` 경로로 문서 유형별 에디터를 엶
- 문서 공통 모델과 로컬 `SharedPreferences` 메타데이터 저장소
- 필기 획 JSON의 문서별 파일 저장, 임시 파일 교체 방식과 자동 저장 debounce
- 펜·형광펜·지우개·실행 취소·다시 실행·색상·굵기·전체 삭제
- Android 파일 선택으로 PDF를 앱 내부 `original` 폴더에 복사
- `pdfx` 실제 페이지 렌더링과 페이지별 투명 필기 레이어
- PDF 편집 화면 공통 `PdfDrawingToolbar` 1개와 페이지별 렌더링/필기 레이어 분리
- 보기 모드·필기 모드, 현재 페이지 선택, 페이지별 undo/redo
- 즐겨찾기, 제목·본문·문서 유형·즐겨찾기 검색 필터, 문서 이름 변경
- 휴지통 이동·복원·영구 삭제, 최근 열람 시각 기록
- 필기 노트 생성, 페이지 추가·삭제·이동 및 페이지별 저장
- PDF 가져오기 시 첫 페이지 썸네일 생성 및 문서 목록 미리보기
- `documents/{id}/original`, `working`, `annotations`, `thumbnails`, `exports`, `metadata`로 확장 가능한 저장 정책
- HWP/HWPX 엔진 인터페이스를 `lib/features/hwp/domain/hwp_engine.dart`에 분리

## 구조

`lib/app`, `lib/core`, `lib/features/{home,documents,notes,drawing,pdf,hwp,search,settings}`의 feature-first 구조를 기준으로 확장합니다. 현재 MVP의 빠른 실행 경로는 `lib/main.dart`에 있으며, 엔진과 저장소는 교체 가능한 경계를 가집니다.

## 주요 패키지

- `flutter_riverpod`: 앱 상태와 저장소 의존성 관리
- `go_router`: 라우팅 확장 지점
- `shared_preferences`: MVP 문서 메타데이터 영속화
- `file_picker`: Android Storage Access Framework 기반 파일 선택
- `pdfx`: PDF 페이지 렌더링 확장 지점
- `pdf`: 렌더링된 PDF 페이지와 필기 레이어를 새 PDF로 합성
- `share_plus`: Android 공유 시트 호출
- `path_provider`, `uuid`: 앱 전용 파일 저장 및 ID 생성 확장 지점
- `pdf_file_validator.dart`: 파일 존재·크기·확장자·PDF 헤더 검증

실제 패키지 버전은 `pubspec.lock`으로 고정됩니다. 패키지 다운로드가 가능한 환경에서 `flutter pub get`을 실행합니다.

## PDF와 필기

PDF 원본은 앱 내부 `documents/{id}/original`에 복사하고, 원본과 주석을 분리합니다. `pdfx`의 `PdfDocument.openFile`과 페이지별 `getPage().render()`를 사용하며, `ListView.builder`로 페이지를 필요할 때 생성합니다. 각 페이지는 `Image.memory`와 투명 `DrawingCanvas`를 `Stack`으로 겹칩니다.

파일 선택·복사·검증·문서 열기·페이지 가져오기·렌더링·해제 단계는 `docnote.pdf` 개발 로그에 경로, 문서 ID, 파일 크기, 페이지 번호, 요청 크기, 예외와 stack trace를 남깁니다. 사용자에게는 원인별 한국어 안내를 표시합니다.

필기 데이터는 이미지가 아니라 문서 ID·페이지 ID·도구·정규화 좌표·압력·색상·굵기·투명도·생성 순서·생성 시간을 가진 `Stroke` 모델입니다. `documents/{id}/annotations/page_1.json`처럼 저장하고, 화면 크기가 바뀌어도 페이지 크기에 맞춰 좌표를 복원합니다. 저장은 `.tmp` 파일을 먼저 flush한 뒤 교체합니다.

PDF 화면은 보기 모드와 필기 모드를 분리합니다. 보기 모드에서는 `InteractiveViewer`로 핀치 확대·축소와 이동을 하고 필기 입력을 차단합니다. 필기 모드에서는 확대된 변환 상태를 유지한 채 투명 캔버스가 입력을 받습니다. 두 손가락 제스처는 후속 팜 리젝션 개선 대상으로 남아 있습니다.

도구 모음은 페이지 위젯이 아닌 `PdfEditorPage`의 AppBar 아래 공통 영역에서 한 번만 생성됩니다. 페이지 위젯은 PDF 이미지, 필기 레이어, 입력 처리와 페이지별 저장만 담당합니다. undo/redo와 현재 페이지 필기 삭제는 선택된 페이지에만 적용됩니다.

## PDF 내보내기

`lib/features/pdf/data/pdf_export_service.dart`가 PDF를 페이지 단위로 열고, 각 페이지를 1600px 고해상도 PNG로 렌더링한 뒤 정규화된 Stroke를 같은 이미지 좌표에 합성합니다. 합성 이미지를 `pdf` 패키지로 새 PDF에 넣어 `documents/{id}/exports/{제목}_annotated_{timestamp}.pdf`에 임시 파일을 거쳐 저장합니다. 따라서 원본 PDF는 덮어쓰지 않습니다.

이 방식은 Android에서 안정적으로 동작하는 대신 내보낸 PDF의 텍스트 선택·검색·원본 벡터 정보가 이미지화된다는 제한이 있습니다. 원본 페이지 크기와 비율은 유지하며, 펜 색상·굵기·형광펜 투명도는 합성 이미지에 반영됩니다. 완료된 파일은 `share_plus`의 Android content URI 기반 공유 시트로 공유할 수 있습니다.

## HWP/rhwp

검증되지 않은 rhwp API를 추측해 사용하지 않았습니다. Flutter에서 직접 호출 가능한 공식/유지보수 패키지가 확인되지 않는 환경에서는 `HwpEngine` 인터페이스와 안전한 플레이스홀더로 앱 전체 흐름을 유지하고, 실제 rhwp 연동은 Rust FFI 또는 별도 Android 모듈을 검증한 뒤 연결합니다. HWP 본문 직접 편집과 100% 한컴오피스 동일 렌더링은 MVP 범위에서 제외합니다.

## 실행 및 검증

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
flutter build apk --debug
flutter build appbundle --release
```

Flutter 설치 디렉터리의 Git 소유권 검사로 CLI가 중단되는 환경에서는 저장소의 `.flutter-gitconfig`를 임시 전역 설정으로 지정해 실행할 수 있습니다. 이 파일은 전역 Git 설정을 영구 변경하지 않습니다.

## 수동 검증

1. Android 기기에서 새로 만들기 → 필기 노트를 선택합니다.
2. 펜·형광펜으로 필기하고 뒤로 가거나 앱을 백그라운드로 보냅니다.
3. 앱을 다시 열고 같은 필기가 복원되는지 확인합니다.
4. PDF 가져오기에서 실제 PDF를 선택하고 여러 페이지를 스크롤합니다.
5. 각 페이지 위에 필기한 뒤 문서를 닫고 다시 열어 페이지별 필기를 확인합니다.
6. 스타일러스 압력은 기기 지원 여부에 따라 전달되며, 손가락 입력도 동일한 캔버스에서 지원됩니다.
7. PDF 화면에서 보기 모드로 확대·이동한 뒤 필기 모드로 전환합니다.
8. 상단 PDF 아이콘을 눌러 필기 포함 PDF를 내보내고 공유 시트를 확인합니다.

메모 검증은 빠른 메모를 누른 직후 본문 입력, 뒤로 가기, 앱 재실행, 최근 노트 재진입, 제목·본문 수정, 즐겨찾기와 삭제까지 확인합니다.

## 제한사항 및 다음 우선순위

PDF 필기 내보내기는 구현되어 있지만 이미지 합성 방식이라 텍스트 검색·선택이 유지되지 않습니다. PDF 내부 텍스트 검색, 고급 팜 리젝션, 폴더 관리, 설정값 영속화, HWP 렌더러는 아직 미완성입니다. 실제 Android 기기와 외부 PDF 앱에서의 결과 확인이 필요합니다.
