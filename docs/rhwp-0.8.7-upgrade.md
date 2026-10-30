# rhwp 0.8.7 업데이트 검증

## 범위

- 기준 앱 커밋: `3926368` (기존 수정분, origin/main에 푸시 완료)
- 작업 브랜치: `upgrade/rhwp-0.8.7`
- upstream: `edwardkim/rhwp`, tag `v0.8.7`, commit `1a76570e833917d15817415a53c09ad61ab3203f`
- Flutter 플러그인 공개 API와 생성된 FRB 인터페이스는 유지한다.
- 원본 사용자 문서는 수정하지 않는다. 기본 연결부는 `bed77d1`로 로컬 main에 반영했으며, 아래 추가 호환성 검사에서 발견한 미주 문제를 후속 수정한다.

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
- 첫 0.8.7 연결 버전의 실제 문서 페이지 수: 원래 197쪽 → 2·3단 196쪽 → 1단 복원 197쪽. 이후 아래 미주 줄 간격 수정으로 202쪽이 되었다. 이전 엔진은 204쪽이었다.
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
- 이 단계의 기기 검증은 Pixel 7 x64 에뮬레이터였다. ARM release 빌드는 아래 후속 단계에서 확인했다. ARM 실기기 검증은 아직 수행하지 않았다.
- 새 엔진의 페이지 배치가 이전과 완전히 동일하다고 보장하지 않는다. 긴 HWP의 텍스트 보존 및 다단/표 회귀 테스트와 화면 표본을 확인했으며, 모든 문서 유형의 모든 페이지를 시각 비교한 것은 아니다.

핵심 연결부 및 위 회귀 검증은 통과했다. 출시 전에는 대표 사용자 문서의 페이지 배치와 ARM 실기기 동작을 추가 확인한다.

## 추가 문서 호환성 검사와 미주 수정 (2026-10-29)

에뮬레이터의 서로 다른 HWP 원본 4개를 로컬 QA 폴더로 복사했다. 원본 경로/해시는 로컬 manifest에만 기록하며 문서 내용이나 생성 SVG를 저장소에 포함하지 않는다. 외부에서 작성된 HWPX 원본은 이번 corpus에 없으며, HWP → HWPX 저장/재열기 경로를 검증했다.

| 표본 | 종류 | 수정 전 페이지 | 수정 후 페이지 | HWP/HWPX 재열기 텍스트·페이지 |
|---|---|---:|---:|---|
| sample-01 | 표 중심 주간 보고서 | 4 | 4 | 모두 동일 |
| sample-02 | 표 중심 주간 보고서 | 4 | 4 | 모두 동일 |
| sample-03 | 짧은 문서 | 1 | 1 | 모두 동일 |
| sample-04 | 긴 본문과 91개 미주 | 197 | 202 | 모두 동일 |

### 발견 및 수정

- 저장 왕복은 통과했지만, 긴 문서의 191~197쪽에서 본문 TextRun 270개가 물리적 종이 하단을 벗어났다. 192쪽과 마지막 쪽에서 줄 겹침·잘림도 시각적으로 확인했다.
- 원인: upstream의 `typeset/notes/endnotes/paragraph.rs`가 구분선 없음 + 미주 사이 여백 0을 근거로 문단의 저장된 `line_spacing`을 `-line_height / 10`으로 덮어썼다. 해당 문서는 높이 1200, 간격 720 HWP-unit의 정상적인 줄 정보를 갖고 있었다.
- 미주 사이 간격과 문단 줄 간격은 별개이므로 이 덮어쓰기를 제거했다. 원본 IR/저장 데이터는 바꾸지 않으며 fit 계산과 렌더링 모두 기존 줄 정보를 보존한다.
- 수정 후 총 211쪽의 본문 종이 경계 검사에서 밖으로 나가는 TextRun은 **0개**였다. 마지막 쪽의 미주 84~91이 겹치거나 잘리지 않고 표시되는 것을 확인했다.
- 수정 후 페이지 수는 202쪽이다. 구 엔진의 204쪽과 완전히 같지는 않으므로, 이를 원본 한컴 페이지 배치와의 완전 일치로 해석하지 않는다.

### 테스트와 증거

- `document_compat_qa.rs`: 외부 corpus 경로를 명시해야 실행되는 ignored 테스트 2개. 저장 왕복/표본 SVG 출력과 전체 본문 종이 경계 검사를 분리한다. `cfg(test)`에서만 연결된다.
- 기본 Rust 회귀 테스트: 25 passed / 3 ignored. corpus 테스트 2개는 별도로 실행하여 모두 통과했다.
- 표본 페이지 15개 × HWP/HWPX = 30쌍의 저장 전후 렌더 픽셀이 일치했다. 이는 동일 0.8.7 엔진 내 저장 전후 비교이며, 구 엔진과의 픽셀 비교는 아니다.
- 대표 표 페이지와 긴 문서의 본문/마지막 미주를 직접 이미지로 확인했다. 표본 SVG에는 래스터 그림이 없어, 실제 이미지가 많은 문서의 전체 시각 검증까지 완료한 것은 아니다.
- 로그: `build/rhwp087-paper-bounds.log`(수정 전 실패), `build/rhwp087-endnote-regression.log`, `build/rhwp087-corpus-fixed.log`.
- 로컬 결과: `build/qa/rhwp087-fixed/results.json`, `paper-bounds.json`, `pixel-comparison.json`.
- 시각 비교: `build/qa/rhwp087-roundtrip/sample-04-source-196.png`(수정 전 마지막 쪽), `build/qa/rhwp087-fixed/sample-04-source-201.png`(수정 후 마지막 쪽).

재실행 예:

```powershell
$env:DOCNOTE_COMPAT_INPUT = 'G:/Bang/DocNote/build/qa/rhwp087-corpus'
$env:DOCNOTE_COMPAT_OUTPUT = 'G:/Bang/DocNote/build/qa/rhwp087-fixed'
cargo test --manifest-path third_party/flutter_rhwp/rust/Cargo.toml --lib document_compat_qa -- --ignored --nocapture
```

입력/출력 폴더는 서로 달라야 하며 먼저 존재해야 한다. 원본 파일은 읽기만 한다.

## Pixel 7 마지막 쪽 런타임 오류 (2026-10-30)

수정된 202쪽 문서를 실제 앱에서 열고 마지막 쪽으로 이동하자 `FormatException: Positive input exceeds the limit of integer 18446744073709551615`가 표시됐다. Rust의 page layer tree에서 미주 가상 렌더 요소가 `section:0/para:18446744073709551615/char:0` 키를 갖고 있었다. 이 값은 Rust의 `usize::MAX` 센티널이며 실제 편집 가능한 문단 번호가 아니다.

Flutter `rhwp_layer_tree.dart`에서 안정 소스 키의 세 정수에 `int.tryParse`를 적용하고, 범위를 넘는 키를 주소 없는 가상 요소로 처리한다. 해당 렌더 요소를 지우지 않으므로 미주 본문은 계속 화면에 표시된다. `rhwp_layer_tree_large_id_test.dart`가 정상 문단과 가상 문단이 섞인 페이지를 재현하며 통과했다.

- Pixel 7 debug APK: 수정 전 실제 앱에서 202쪽 이동 시 예외 재현. 수정 후 같은 202쪽에서 미주 84~91과 본문이 렌더링되고 예외 화면이 나타나지 않았다. 캡처: `build/qa/rhwp087-final-page202.png`. 해당 실행의 앱 로그에서 `FormatException`, `RenderFlex`, `FATAL EXCEPTION`, `E/flutter` 항목이 없었다.
- Flutter 정적 분석: `flutter analyze --no-pub` 통과.
- Rust 기본 회귀: 25개 통과, 3개 ignored(현지 문서 입력 필요). corpus 검사 2개 별도 통과.
- 다단 편집 실제 문서: 202 → 201(2·3단) → 202쪽(1단 복원), 저장/재열기 일치 및 표/본문 비겹침 통과.
- ARM release APK: 최종 Flutter parser 수정까지 포함해 `flutter build apk --release --no-pub --target-platform android-arm,android-arm64` 성공. `build/app/outputs/flutter-apk/app-release.apk` (86,994,762 bytes), SHA-256 `f2edb1bbaaae801fac8c3e678b47de0afa880de051b43241199483aac20423d0`. `apksigner verify --verbose`에서 v2 서명과 signer 1개를 확인했다. ARM 실기기 실행은 아직 확인하지 못했다.
