# rhwp 0.8.7 업데이트 검증

## 범위

- 기준 앱 커밋: `3926368` (기존 수정분, origin/main에 푸시 완료)
- 작업 브랜치: `upgrade/rhwp-0.8.7`
- upstream: `edwardkim/rhwp`, tag `v0.8.7`, commit `1a76570e833917d15817415a53c09ad61ab3203f`
- Flutter 플러그인 공개 API와 생성된 FRB 인터페이스는 유지한다.
- 원본 사용자 문서는 수정하지 않는다. 검증 완료 전 main에 병합하지 않는다.

## 연결부 변경

- vendored core 0.7.12 → 0.8.7 및 내부 contracts/chart/password-crypto 의존성 갱신.
- upstream의 svg2pdf 패치를 Rust workspace 루트에서 적용.
- 웹/CLI용 workspace 및 예제 진입점은 제외. core는 Flutter 공유 라이브러리에 rlib로 연결.
- 문단 분할의 metadata, 이미지의 cell path/위치, 표 행 높이, 객체 복사/HTML 출력의 cell path 인수를 명시.
- Flutter 전용 본문/셀 주석 및 범위 서식 API 보존.
- Flutter에서 사용하는 필드 메뉴는 하이퍼링크를 포함하므로, upstream의 누름틀 전용 조회/삭제와 구분하는 호환 API 추가.
- 네이티브 명령 오류를 WASM JsValue로 변환하는 경로를 제거. 잘못된 표 위치 등은 오류 문자열로 반환.
- 표 생성 이후 0번 컨트롤을 가정하지 않고 반환된 controlIdx를 사용.
- 그림 삽입 후 새 문단이 생긴다고 가정하지 않고 반환된 paraIdx/logicalOffset으로 커서를 이동.
- Flutter 표 선택에 필요한 layer-tree의 sectionIndex/paraIndex/controlIndex 메타데이터 보존.
- HWPX 하이퍼링크 수정 시 원문 parameters XML 캐시와 Command/Path 값을 함께 갱신.

## 확인한 회귀와 대응

첫 실행은 표 오류가 웹 전용 예외 변환으로 들어가 프로세스가 종료됐다. 네이티브 API로 연결한 뒤 테스트 전체를 실행할 수 있었다.

다음 실행 결과는 20 pass / 3 fail / 1 ignored였다. 실패 테스트를 제거하거나 기대값을 완화하지 않고 다음을 수정한다.

1. 하이퍼링크 필드 조회: upstream은 ClickHere 필드만 반환하므로 Flutter 호환 조회/삭제를 분리한다.
2. 초기 다단 변경이 뒤쪽 독립 ColumnDef의 줄 너비까지 변경하는 문제: 변경 대상 문단 범위만 reflow한다.
3. 넓은 inline 표와 옆 단의 본문 겹침: 기존 앱의 table reservation 처리를 새 typeset 모듈 구조에 이식한다.

## 검증 상태

- Flutter analyze: 최종 변경 기준 통과 (`flutter analyze --no-pub`, No issues)
- HWP 원본 보존/작업본/닫기 확인 Flutter 테스트: 7개 통과
- Rust 회귀 테스트: 25개 통과, 실제 문서 전용 ignored 1개는 별도로 실행하여 통과
- 실제 긴 HWP 복사본: 다단 2 → 3 → 1 변경, 본문 텍스트 보존, 저장/재열기 페이지 수 일치, 넓은 표/본문 비겹침 통과
- 새 엔진의 실제 문서 페이지 수: 원래 197쪽 → 2·3단 196쪽 → 1단 복원 197쪽. 이전 엔진 204쪽과 페이지 배치 결과가 달라졌다. 텍스트 보존 확인과 별개로 실제 화면도 검증한다.
- 추가 HWP/HWPX 하이퍼링크 재저장 회귀 테스트: 통과
- 잘못된 표 대상 요청이 네이티브 프로세스를 중단시키지 않고 오류를 반환하는 회귀 테스트: 통과
- Android x64 debug APK: 빌드 및 Pixel 7 설치 성공
- Pixel 7: 197쪽 HWP 열기, 한글 표지/본문 렌더링, 편집 메뉴, 화면 키보드 입력, 저장 후 닫기, 재열기 후 입력 내용 유지 확인
- Pixel 7 검증 구간 앱 로그에서 Flutter 예외/RenderFlex overflow/치명적 예외 없음
- 원본 파일 SHA-256 전후 동일: `fd9b502ea0a0f68ead52ace80cd9bc190d6b72c0a49579da255f8852a2e6feac`

## 재현 자료와 검증 범위

- 로그: 주 작업 폴더의 `build/rhwp087-tests-final.log`, `build/rhwp087-real-document.log`, `build/rhwp087-analyze-final2.log`, `build/rhwp087-apk-final.log`
- 캡처: `build/qa/rhwp087-open.png`, `rhwp087-edit-menu.png`, `rhwp087-input2.png`, `rhwp087-exit.png`, `rhwp087-reopen.png`
- APK: 업그레이드 worktree의 `build/app/outputs/flutter-apk/app-debug.apk`
- 화면 키보드로 입력한 QA 문자 `q`는 검증용 문서의 작업본에만 저장했다. 원본은 변경하지 않았다.
- ADB `input text`는 이 편집기에 반영되지 않아 화면 키보드 탭으로 검증했다. 입력 중 임시 표시와 확정 렌더링 전환은 별개이며, 모든 IME 조합/빠른 연속 입력까지 검증한 것은 아니다.
- 이번 실제 기기 검증은 Pixel 7 x64 에뮬레이터다. ARM 실기기 및 release 빌드 검증은 포함하지 않는다.
- 새 엔진의 페이지 배치가 이전과 완전히 동일하다고 보장하지 않는다. 긴 HWP의 텍스트 보존 및 다단/표 회귀 테스트와 화면 표본을 확인했으며, 모든 문서 유형의 모든 페이지를 시각 비교한 것은 아니다.

핵심 연결부 및 위 회귀 검증은 통과했다. 출시 전에는 대표 사용자 문서의 페이지 배치와 ARM 실기기 동작을 추가 확인한다.
