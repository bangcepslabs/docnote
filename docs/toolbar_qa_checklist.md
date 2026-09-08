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
| T01 | 필기 → 펜/형광펜 전환 | Active menu만 전환되고 위치·캔버스가 유지됨 | ✅ PASS | Pixel 7 |
| T02 | 지우개 → 부분 지우기/획 전체 | 두 모드가 즉시 적용되고 다시 열어도 유지됨 | ✅ PASS | Pixel 7 |
| T03 | 선택 → 자유형/사각형 | 선택 모드가 바뀌고 안내 문구 없이 compact하게 표시됨 | ✅ PASS | Pixel 7 |
| T04 | 도형 5종 선택 | 선/화살표/사각형/원/삼각형이 모두 선택·그려짐 | ✅ PASS | 코드/콜백 확인 |
| T05 | 도형 설정 팝업 | 굵기 변경과 색상 선택이 기존 상태에 반영됨 | ✅ PASS | 코드/콜백 확인 |
| T06 | 텍스트 도구 | 텍스트 입력과 기존 크기/색상 옵션이 동작함 | ✅ PASS | 코드/콜백 확인 |
| T07 | 삽입 → 텍스트/이미지 | popup 선택 후 기존 삽입 흐름으로 연결됨 | ✅ PASS | Pixel 7 |
| T08 | 동일 도구 재탭 | 통합 toolbar 내부 quick preset이 유지되고 별도 bar가 생성되지 않음 | ✅ PASS | Pixel 7 |
| T09 | 도구 왕복 전환 | 펜/형광펜/지우개/도형의 마지막 설정값이 독립적으로 복원됨 | ✅ PASS | 상태 연결 확인 |
| T10 | Stroke/Shape 생성 후 Undo/Redo | 생성, 실행 취소, 다시 실행이 각각 한 단계로 동작함 | ✅ PASS | 기존 로직 유지 |
| T11 | 저장 후 재진입 | 획·도형·텍스트·이미지와 설정 결과가 동일하게 복원됨 | ✅ PASS | 기존 저장 로직 유지 |
| T12 | Light/Dark 전환 | 메뉴 surface·선택색 대비가 유지되고 overflow 없음 | ✅ PASS | 테마 토큰 확인 |
| T13 | Pixel 7 overflow | 통합 Tool Strip/QuickPresetStrip에 overflow stripe 없음 | ✅ PASS | Pixel 7 캡처 |
| T14 | 작은 폭/회전 | Tool Strip horizontal scroll로 잘림·겹침을 방지 | ✅ PASS | 반응형 코드 확인 |

## 빠른 자동/정적 확인

| 확인 | 명령/방법 | 결과 |
|---|---|---|
| 정적 분석 | `flutter analyze` | ✅ PASS (신규 오류 없음) |
| 포맷 | `dart format lib/features/drawing/presentation/drawing_editor.dart` | ✅ PASS |
| debug 빌드 | `flutter build apk --debug` | ✅ PASS |
| 에뮬레이터 실행 | Pixel 7 APK 설치/실행 | ✅ PASS |
| 런타임 로그 | Flutter/AndroidRuntime 오류 및 overflow 검색 | ✅ PASS |

## 종료 조건

T01~T14와 자동 확인 항목에 FAIL이 없어야 Toolbar v1 회귀 테스트를 통과한 것으로 기록한다. 실패 시 기기 폭, 테마, 재현 순서와 함께 스크린샷을 첨부한다.

## Toolbar v1 완료

2026-09-02 기준 Pixel 7에서 통합 `IntegratedEditorToolbar`의 도구 전환과 overflow를 확인했다. 신규 레이아웃/스타일 변경은 이 버전에서 종료하고, 이후에는 기능 버그에 한해 최소 수정한다.
