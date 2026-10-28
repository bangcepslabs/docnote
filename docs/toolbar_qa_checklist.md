# DocNote Toolbar v1 회귀 QA 체크리스트

Toolbar v1의 현재 구조를 기준으로 한 회귀 검증표다. 레이아웃을 변경하지 않고 동일한 시나리오를 반복 실행한다.

## 테스트 환경

- 기기: Pixel 7 Android Emulator (세로, 기본 밀도)
- 빌드: `flutter run -d emulator-5554` 또는 최신 debug APK
- 테마: Light, Dark 각각 실행
- 기록: 각 항목에 `PASS` 또는 `FAIL`과 재현 메모를 남긴다.

## 수동 시나리오

| ID | 시나리오 | 기대 결과 | 결과 | 메모 |
|---|---|---|---|---|
| T01 | 필기 → 펜/형광펜 전환 | 첫 탭에 선택 상태와 quick controls가 함께 전환되고 캔버스 위치가 유지됨 | ✅ PASS | Pixel 7 |
| T02 | 지우개 → 부분 지우기/획 전체 | 두 모드가 즉시 적용되고 다시 열어도 유지됨 | ✅ PASS | Pixel 7 |
| T03 | 선택 → 자유형/사각형 | 선택 모드가 바뀌고 안내 문구 없이 compact하게 표시됨 | ✅ PASS | Pixel 7 |
| T04 | 도형 5종 선택 | 선/화살표/사각형/원/삼각형이 모두 선택·그려짐 | ✅ PASS | 코드/콜백 확인 |
| T05 | 도형 설정 팝업 | 굵기 변경과 색상 선택이 기존 상태에 반영됨 | ✅ PASS | 코드/콜백 확인 |
| T06 | 텍스트 도구 | 텍스트 입력과 기존 크기/색상 옵션이 동작함 | ✅ PASS | 코드/콜백 확인 |
| T07 | 삽입 → 텍스트/이미지 | popup 선택 후 기존 삽입 흐름으로 연결됨 | ✅ PASS | Pixel 7 |
| T08 | 동일 도구 재탭 | 해당 도구의 compact quick controls가 캔버스 위에서 열리고 닫힘 | ✅ PASS | Pixel 7 |
| T09 | 도구 왕복 전환 | 펜/형광펜/지우개/도형의 마지막 설정값이 독립적으로 복원됨 | ✅ PASS | 상태 연결 확인 |
| T10 | Stroke/Shape 생성 후 Undo/Redo | 생성, 실행 취소, 다시 실행이 각각 한 단계로 동작함 | ✅ PASS | 기존 로직 유지 |
| T11 | 저장 후 재진입 | 획·도형·텍스트·이미지와 설정 결과가 동일하게 복원됨 | ✅ PASS | 기존 저장 로직 유지 |
| T12 | Light/Dark 전환 | 메뉴 surface·선택색 대비가 유지되고 overflow 없음 | ✅ PASS | 테마 토큰 확인 |
| T13 | Pixel 7 overflow | Tool Strip과 overlay quick controls에 overflow stripe 없음 | ✅ PASS | Pixel 7 캡처 |
| T14 | 작은 폭/회전 | Tool Strip horizontal scroll로 잘림·겹침을 방지 | ✅ PASS | 반응형 코드 확인 |
| T15 | 펜 종류 | 볼펜/만년필/연필/마커를 선택하면 이후 획의 타입으로 저장되고 재진입 시 마지막 선택이 유지됨 | ✅ PASS | Pixel 7 + Stroke 직렬화 테스트 |

## 빠른 자동/정적 확인

| 확인 | 명령/방법 | 결과 |
|---|---|---|
| 정적 분석 | `flutter analyze` | ✅ PASS (신규 오류 없음) |
| 포맷 | `dart format lib/features/drawing/presentation/drawing_editor.dart` | ✅ PASS |
| debug 빌드 | `flutter build apk --debug` | ✅ PASS |
| 에뮬레이터 실행 | Pixel 7 APK 설치/실행 | ✅ PASS |
| 런타임 로그 | Flutter/AndroidRuntime 오류 및 overflow 검색 | ✅ PASS |
| 폭 회귀 테스트 | `flutter test test/widget_test.dart` (320 / 360 / 800px, 7개 도구 상태) | ✅ PASS (2026-09-28) |
| 펜 종류 팝오버 | `flutter test test/widget_test.dart` (볼펜/만년필/연필/마커) | ✅ PASS (2026-09-29) |
| 펜 타입 저장 호환 | `flutter test test/stroke_test.dart` | ✅ PASS (2026-09-29) |

## 종료 조건

T01~T15와 자동 확인 항목에 FAIL이 없어야 Toolbar v1 회귀 테스트를 통과한 것으로 기록한다. 실패 시 기기 폭, 테마, 재현 순서와 함께 스크린샷을 첨부한다.

## Toolbar v1 완료

2026-09-02 기준 Pixel 7에서 통합 `IntegratedEditorToolbar`의 도구 전환과 overflow를 확인했다. 신규 레이아웃/스타일 변경은 이 버전에서 종료하고, 이후에는 기능 버그에 한해 최소 수정한다.

2026-09-28에 기본 Tool Strip과 설정 overlay를 분리했다. 새 필기 도구를 첫 탭하면 quick controls가 즉시 열리고, 같은 도구 재탭 또는 설정 버튼으로 접고 펼친다. 옵션은 Paper 위치를 밀지 않고 캔버스 위에 overlay로 열린다. 이미지 도구에는 빈 설정 패널을 표시하지 않는다. 자동 폭 회귀 테스트는 320px, 360px, 800px에서 Pen·Highlighter·Eraser·Lasso·Shape·Text·Image를 각각 렌더링해 overflow 예외가 없는지 확인한다.
