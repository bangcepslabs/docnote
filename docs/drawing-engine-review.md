# Drawing Engine 1차 코드 리뷰

이번 단계에서는 필기 알고리즘·저장 포맷은 유지한 채 pointer 입력에서 editor 전체 rebuild가 발생하는 경로를 계측하고 최소 범위로 줄였다.

## 현재 pipeline

1. `DrawingCanvas`의 `Listener`가 pointer down/move/up을 직접 수신한다 (`drawing_editor.dart:4151`).
2. `_start`에서 정규화 좌표와 pressure를 첫 점으로 저장한다 (`:526`).
3. `_move`마다 정규화하고 이전 점과의 제곱 거리 `0.0000015` 미만이면 마지막 점만 pressure로 갱신한다. 그 외에는 point를 추가하고 canvas notifier만 증가시킨다.
4. `_end`에서 `Stroke` 벡터 객체를 만들고 snapshot을 history에 넣은 뒤 500ms debounce 저장을 예약한다 (`:575`, `:246`).
5. `StrokePainter`는 정적 이미지·도형·텍스트·확정 stroke를 picture로 캐시하고, active stroke/선택 상태만 매 paint마다 그린다. active stroke는 매 paint 시 임시 `Stroke` 객체를 생성한다.
6. 일반 stroke는 midpoint 기반 quadratic Bézier로 렌더링한다 (`_paintSmoothStroke`, `:4486`). 저장 좌표는 변경하지 않고 화면 렌더링만 부드럽게 한다.
7. `StrokePainter.shouldRepaint`는 revision과 활성 상태를 비교해 실제 변경 시에만 repaint한다.

## 현재 상태 평가

- Stylus/touch: Flutter `PointerEvent.pressure`를 수집하며 펜 stroke 폭에 반영한다. 플랫폼에서 pressure가 0/1로만 전달되는 경우에도 동작하는 fallback은 별도 정규화 없이 기본 폭에 가까운 결과가 된다.
- Sampling: 근접 move 이벤트를 병합해 point 폭증을 일부 억제한다. 임계값은 정규화 좌표 기준이므로 페이지 크기/화면 밀도에 따라 실제 픽셀 간격이 달라질 수 있다.
- Smoothing: midpoint quadratic path가 이미 적용되어 직선 연결보다 각짐이 줄어든다. 다만 pressure 변화에 따른 variable-width path를 하나의 `Path` strokeWidth로 그려 폭 전환이 구간별로만 반영된다.
- Repaint: pointer move는 canvas notifier를 통해 drawing layer만 갱신하며 editor subtree 전체 rebuild를 피한다. 정적 객체는 picture cache에서 재사용한다.
- Eraser: 입력 중 snapshot을 보관하고 pointer up에서 한 번 history에 기록한다. 이동 중 지우기 hit-test 비용은 stroke 수에 비례한다.
- Undo/Redo: 최대 80개의 전체 페이지 snapshot을 보관한다. snapshot은 리스트만 얕게 복사하므로 객체 불변성이 유지되는 현재 모델에서는 안전하지만, 큰 point 배열이 매 작업마다 참조되며 향후 deep copy가 들어가면 메모리 비용이 커질 수 있다.
- PDF: PDF 렌더링/페이지 bitmap과 필기 canvas가 같은 화면 subtree에서 합성되므로, PDF 자체 latency와 stroke repaint 비용을 분리 측정해야 한다.

## 개선 우선순위 제안

### P0 — 계측 후 repaint 범위 축소

pointer move 빈도, frame time, active point 수, paint 소요 시간을 Pixel 7 profile mode에서 먼저 측정한다. 이후 active stroke를 별도 `ValueListenable`/`CustomPainter` subtree로 분리하거나 `shouldRepaint`에 데이터 identity 비교를 도입해 정적인 저장 stroke·문서 preview의 재도색을 막는 것이 1순위다. 동작/저장 모델은 유지할 수 있다.

### P1 — 입력 샘플링을 화면 독립적으로 보정

현재 정규화 거리 임계값을 실제 페이지 픽셀 또는 devicePixelRatio 기반으로 환산하고, 시간 간격/속도도 함께 고려한다. 빠른 획은 최소 간격을 유지하면서 끊김을 줄이고, 느린 획은 저주파 jitter를 제한하는 방식이 안전하다. 기존 저장 좌표 호환을 위해 저장 전처리 단계에서만 적용한다.

### P1 — 렌더링 smoothing/pressure 개선

현재 quadratic midpoint를 유지한 채 pressure를 인접 샘플에 보간하고, 필요할 때만 variable-width mesh/path를 도입한다. 먼저 ballpoint/highlighter에 한정해 A/B 비교하고, pencil/fountain은 별도 튜닝한다.

### P2 — 대용량 페이지 최적화

stroke 수가 많은 페이지에서는 페이지별 spatial bounds/index를 캐시해 eraser·lasso hit-test 후보를 줄이고, 정적 stroke layer를 캐시한다. 페이지 전환 시 캐시를 폐기하며 저장 포맷은 건드리지 않는다.

### P2 — history 메모리 측정 및 압축 검토

80 snapshot의 실제 메모리를 측정한 뒤 필요할 때만 command/delta history 또는 point 배열 공유를 검토한다. Undo semantics를 바꾸는 리팩터링은 계측 이후 별도 작업으로 분리한다.

## P0 1차 적용 결과

- `canvasRevision`을 `CustomPainter`의 repaint listenable로 연결했다. `_start`/`_move`/shape preview/eraser 변경은 notifier만 증가시키므로 `DrawingEditor` 전체 `setState`를 거치지 않는다.
- `StrokePainter`에 revision 기준을 추가하고 `shouldRepaint`가 revision·활성 도구 상태가 바뀔 때만 true가 되도록 했다. mutable list 참조 비교는 사용하지 않는다.
- debug/profile에서 pointer move 수, editor build 수, painter paint 수, active point 수, stroke 중 build+raster 평균/최대 frame time을 `[DrawingPerf]` 로그로 확인할 수 있다.
- Pixel 7 adb swipe 측정 예: `moves=20`, `points=20`, `editorBuilds=2`, `painterRepaints=7`, 평균 18.87ms, 최대 29.82ms. 단일 측정치이므로 전후 절대 비교가 아닌 계측 경로 검증용이다.

## 남은 병목 및 다음 단계

정적 picture 캐시는 `staticRevision`이 증가할 때(페이지 로드/확정 객체 변경)에만 재생성된다. 포인터 이동 중에는 `canvasRevision`만 증가해 active layer와 선택 오버레이만 다시 그린다. 캐시는 painter delegate 수명 동안 유지되며 페이지 크기 변경 시 안전하게 폐기된다. 이미지가 매우 많은 페이지에서는 picture raster 비용과 eraser/lasso hit-test가 여전히 남은 병목이다. 이번 단계에서는 smoothing, sampling, pressure, eraser/lasso 알고리즘, history 구조와 저장 포맷을 변경하지 않았다.

## P0 2차 계측

정적 picture 재생성과 active repaint를 별도 콜백으로 계측한다. `[DrawingPerf]` 로그에 `staticPainterRepaints`, `activePainterRepaints`, `staticObjectPaintCount`를 추가했으며, 연속 포인터 이동에서는 static 카운터가 증가하지 않고 확정/페이지 변경 시에만 증가한다. 실제 100/500/1000 stroke workload는 앱 데이터에 따라 편차가 커 자동 생성하지 않았고, Pixel 7에서 기존 페이지 필기 경로를 smoke 검증했다.

Pixel 7 측정 예: `moves=108 points=108 editorBuilds=2 painterRepaints=52 staticPainterRepaints=1 activePainterRepaints=52 staticObjectPaintCount=9 avg=17.39ms max=31.23ms`. 한 획 동안 정적 레이어가 1회만 생성되고 pointer move에 따른 static object 재순회는 발생하지 않았다.

## P0 3차 입력 파이프라인 분석

- `PointerMoveEvent.localPosition`과 pressure를 사용하며 coalesced/predicted event API는 사용하지 않는다.
- baseline에서는 기존 정규화 거리 제곱 기준 `0.0000015`를 그대로 사용한다. 실제 픽셀 거리는 계측만 하며 sampling 동작은 변경하지 않았다. 시간 기반 샘플링은 없다.
- pressure는 `StrokePoint`에 저장되고 기존 폭 계산에 사용된다. pressure curve는 변경하지 않았다.
- midpoint quadratic smoothing은 매 paint 시 현재 point list에서 Path를 재구성하며, incremental Path cache는 아직 적용하지 않았다.

노트 메뉴의 `DEBUG: 100/500/1000 strokes`는 저장하지 않는 in-memory fixture다. `DEBUG: replay baseline (5x)`는 고정 좌표·8ms 간격으로 동일한 `_start`/`_move`/`_end` 경로를 재생한다. `straightSlow`, `straightFast`, `circle`, `zigzag`, `handwritingLike`를 workload별 warm-up 1회 후 5회 실행하며 `[DrawingBenchmark]` 로그를 남긴다. release에서는 `kDebugMode` 조건과 debug-only 메뉴 때문에 실행 경로가 노출되지 않는다.

현재 확보된 Pixel 7 실측 baseline(기존 페이지, 짧은 swipe 1회)은 다음과 같다.

| workload | rawMoves | storedPoints | editorBuilds | staticRepaints | activeRepaints | staticObjects | avgFrame | maxFrame | elapsed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| existing (9 static objects) | 108 | 108 | 2 | 1 | 52 | 9 | 17.39ms | 31.23ms | 901ms |
| 100 / 500 / 1000 fixture | replay 경로 준비 | 앱에서 `DEBUG: replay baseline (5x)` 실행 후 로그 집계 | | | | | | | |

이 수치는 sampling/smoothing 변경 전 기준으로 보관하며, 다음 단계에서 동일 replay 입력으로 Before/After를 채운다.

Replay 결과 로그에는 raw/accepted/rejected 및 reduction rate, point distance(평균/최소/최대/누적), path build count/평균/최대 μs, editor/static/active repaint, static object paint count, frame 평균/p95/최대, stroke elapsed가 포함된다. 아래 수치는 Pixel 7 Debug에서 workload별 warm-up 제외 5회 평균과 최악값을 확정한 값이며, Profile은 별도 실행 시 같은 표 형식으로 추가한다.

| Workload | Replay | Runs (warm-up 제외) | Raw | Accepted | Rejected | Path avg μs | Frame avg | P95 | Max |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | straightSlow | 5 | 79 | 80 | 0 | 43 | 6.88ms | 11.97ms | 26.53ms |
| 100 | straightFast | 5 | 23 | 24 | 0 | 32 | 9.92ms | 16.23ms | 29.54ms |
| 100 | circle | 5 | 96 | 97 | 0 | 41 | 12.87ms | 19.20ms | 37.29ms |
| 100 | zigzag | 5 | 79 | 80 | 0 | 42 | 9.71ms | 18.90ms | 26.32ms |
| 100 | handwritingLike | 5 | 119 | 120 | 0 | 43 | 11.96ms | 18.12ms | 35.66ms |
| 500 | straightSlow | 5 | 79 | 80 | 0 | 37 | 14.36ms | 19.64ms | 30.17ms |
| 500 | straightFast | 5 | 23 | 24 | 0 | 25 | 12.82ms | 20.38ms | 29.85ms |
| 500 | circle | 5 | 96 | 97 | 0 | 38 | 14.69ms | 19.33ms | 27.75ms |
| 500 | zigzag | 5 | 79 | 80 | 0 | 32 | 9.70ms | 14.18ms | 27.75ms |
| 500 | handwritingLike | 5 | 119 | 120 | 0 | 40 | 16.51ms | 20.81ms | 30.80ms |
| 1000 | straightSlow | 5 | 79 | 80 | 0 | 36 | 12.10ms | 18.77ms | 26.84ms |
| 1000 | straightFast | 5 | 23 | 24 | 0 | 28 | 14.75ms | 17.58ms | 27.49ms |
| 1000 | circle | 5 | 96 | 97 | 0 | 42 | 16.22ms | 21.53ms | 64.24ms |
| 1000 | zigzag | 5 | 79 | 80 | 0 | 41 | 15.65ms | 25.25ms | 68.62ms |
| 1000 | handwritingLike | 5 | 119 | 120 | 0 | 44 | 16.36ms | 23.28ms | 33.30ms |

이번 Debug/Pixel 7 baseline에서는 모든 preset의 `rejectedNearPoints=0`(reduction 0%)이었고, active point 수가 24~120인 범위에서 `pathBuildAvgUs`는 약 25~44μs였다. workload(100→1000 committed strokes)에 따른 static repaint/object paint 증가는 관찰되지 않았다(두 값 모두 stroke 중 0). incremental Path 적용 후 geometry build 비용은 감소했지만 frame spike 검증이 남아 있어 후속 priority는 active repaint/frame scheduling으로 둔다. sampling은 필기 품질 A/B 없이 threshold를 바꾸지 않는다. Profile mode 수치는 별도 실행 환경에서 동일 replay를 돌려 추가한다.

## P0 3차 2단계 — incremental active Path

active stroke만 runtime `Path` cache를 사용하도록 변경했다. 새 point가 추가되면 이전 point를 다시 순회하지 않고 마지막 midpoint quadratic segment와 endpoint만 append한다. 2점 이하 stroke 및 근접 point 위치 변경 시에는 기존 painter 경로를 사용해 시작/끝점과 baseline 시각 결과를 보존한다. cache는 `Stroke` 저장 모델에 포함되지 않으며 pointer-up에서 active list가 비워지면 다음 stroke에서 초기화된다. committed stroke의 static picture, pressure 저장/폭 계산, sampling threshold, smoothing 수식은 변경하지 않았다.

추가 계측: `fullPathRebuildCount`, `incrementalSegmentBuildCount`, `incrementalBuildAvgUs`, `incrementalBuildMaxUs`. 동일 deterministic replay를 다시 실행한 뒤 각 workload/preset별 Before/After를 아래 표에 확정한다.

| Workload | Replay | Before path avg μs | After full rebuild | After incremental segments | After incremental avg μs | Before frame avg/p95/max | After frame avg/p95/max |
|---:|---|---:|---:|---:|---:|---|---|
| 100 | all presets | 25–43 | 1.0 | 20.2–116.6 | 2–8μs | 6.88–12.87 / 11.97–19.20 / 26.32–37.29ms | 7.78–16.19 / 13.00–31.84 / 24.61–109.69ms |
| 500 | all presets | 25–40 | 1.0 | 20.6–115.8 | 2–8μs | 9.70–16.51 / 14.18–20.81 / 27.75–30.80ms | 12.44–17.84 / 19.29–28.11 / 28.32–124.07ms |
| 1000 | all presets | 28–44 | 1.0 | 20.0–115.4 | 2–8μs | 12.10–16.36 / 17.58–25.25 / 26.84–68.62ms | 14.69–17.12 / 20.76–25.07 / 31.76–87.96ms |

최종 Pixel 7 Debug 결과에서 full rebuild는 각 stroke의 초기 cache 생성 1회뿐이었고, incremental segment 수는 accepted point 수(24→120)와 일관되게 대응했다. incremental geometry build는 2~8μs로 기존 25~44μs full path build보다 감소했다. 다만 frame p95/max는 preset과 workload에 따라 개선·악화가 섞였고 handwritingLike/zigzag에서 max spike가 커진 경우가 있었다. 결론은 **2. 효과는 확인됐지만 frame 회귀 가능성이 있어 구조상 유지 가치 있음**이다. 다음 우선순위는 **B. active repaint/frame scheduling** 하나를 추천한다. sampling은 `rejectedNear=0%`이므로 아직 우선하지 않는다.

## P0 3차 3단계 — frame spike 원인 분리 계측

- `FrameTiming`에서 build/raster/total duration을 stroke별로 수집하고 평균·p95·최대를 집계한다.
- active painter 전체 시간, overlay 시간, incremental append 시간을 hot path에서 메모리 누적 후 stroke 종료 시에만 출력한다.
- `activeRevisionUpdates`와 `activePainterRepaints`를 함께 기록해 notifier/coalescing 비율을 확인한다.
- debug/profile 메뉴의 `DEBUG: legacy full path` 토글로 동일 replay에서 legacy와 incremental을 비교할 수 있다. Profile에서는 대표 workload(500/1000 + circle/handwritingLike)만 실행하도록 범위를 줄인다.

이번 계측은 sampling, scheduling, pressure, raster cache, Eraser/Lasso, Undo를 변경하지 않는다. instrumentation OFF A/B와 Profile 실행은 별도 측정 환경에서 수행하며, 현재 Pixel 7 Debug 결과만으로 raster 또는 UI thread regression을 단정하지 않는다.

### Profile + instrumentation A/B 실측 (Pixel 7, warm-up 1회 제외 5회 평균)

Profile APK에서 동일한 deterministic replay를 실행했다. `incremental+on`은 계측을 켠 상태, `incremental+off`는 hot-path stopwatch/counter를 끈 상태, `legacy+off`는 full-path painter와 계측 OFF 상태다. FrameTiming은 세 조건 모두 수집했다.

| Mode | Workload | Replay | Build avg/p95/max ms | Raster avg/p95/max ms | Total avg/p95/max ms | Active paint avg/max μs | Incremental append avg/max μs | Rev updates / active repaints |
|---|---:|---|---|---|---|---|---|---|
| incremental+on | 500 | circle | 0.38/0.49/2.78 | 16.20/18.29/25.51 | 16.58/18.64/25.78 | 22/84 | 1/15 | 97 / 58.0 |
| incremental+on | 500 | handwritingLike | 0.37/0.49/3.77 | 16.16/18.46/21.03 | 16.54/18.83/21.32 | 23/159 | 1/134 | 120 / 72.2 |
| incremental+on | 1000 | circle | 0.43/0.54/3.65 | 16.24/18.61/26.65 | 16.67/19.13/27.12 | 24/269 | 1/85 | 97 / 57.8 |
| incremental+on | 1000 | handwritingLike | 0.44/0.56/3.34 | 16.26/18.56/29.50 | 16.70/19.03/29.86 | 23/122 | 1/27 | 120 / 71.6 |
| incremental+off | 500 | circle | 0.37/0.51/2.41 | 16.18/18.75/25.18 | 16.55/19.16/25.49 | — | — | — / — |
| incremental+off | 500 | handwritingLike | 0.38/0.50/2.87 | 16.24/18.57/22.47 | 16.62/18.94/22.88 | — | — | — / — |
| incremental+off | 1000 | circle | 0.46/0.57/3.77 | 16.35/19.14/28.53 | 16.81/19.56/28.95 | — | — | — / — |
| incremental+off | 1000 | handwritingLike | 0.45/0.58/6.62 | 13.24/16.74/24.88 | 13.69/17.38/25.24 | — | — | — / — |
| legacy+off | 500 | circle | 0.40/0.49/3.17 | 16.26/18.61/29.38 | 16.66/19.38/29.76 | — | — | — / — |
| legacy+off | 500 | handwritingLike | 0.38/0.49/3.15 | 16.00/18.30/20.57 | 16.38/18.71/20.93 | — | — | — / — |
| legacy+off | 1000 | circle | 0.46/0.58/3.33 | 16.06/22.31/35.08 | 16.52/22.84/35.49 | — | — | — / — |
| legacy+off | 1000 | handwritingLike | 0.49/0.62/6.00 | 16.22/19.05/29.24 | 16.71/19.77/29.60 | — | — | — / — |

`instrumentation OFF`에서는 hot-path paint/append 카운터가 의도적으로 기록되지 않으며 FrameTiming 자체는 유지된다. ON→OFF에서 Profile의 build 평균은 약 0.37~0.46ms로 거의 동일했고, raster/total p95는 대부분 18~20ms 범위였다. 즉 Debug에서 관찰된 큰 spike는 계측만으로 설명되지 않지만, Profile에서 incremental이 legacy보다 일관되게 악화되는 패턴도 확인되지 않았다. 1000 circle의 legacy raster/total max(35.08/35.49ms)가 incremental+on(26.65/27.12ms)보다 높아 incremental 경로의 회귀 근거는 없다. 다만 emulator 스케줄링에 따른 단발성 max 변동은 남아 있다.

### Frame spike 판정 및 다음 우선순위

- Profile 기준으로 `buildDuration`은 낮고 안정적이며, spike의 주된 변동은 raster/total 쪽에서 나타난다.
- instrumentation ON/OFF 차이는 작아 계측 overhead가 주원인이라고 보기는 어렵다.
- incremental geometry 비용은 1~2μs 평균으로 유지되고, legacy 대비 frame p95/max가 반복 악화되지 않았다.

따라서 incremental Path는 **유지 확정**한다. 다음 최적화 우선순위는 **B. raster/drawPath 최적화**로 둔다. 단, 이번 단계에서는 raster 경로를 변경하지 않고 원인 계측만 완료했다. activeRevision batching/throttling도 아직 적용하지 않았다.

Pixel 7에서는 Profile APK로 deterministic circle/handwritingLike replay를 완료했고, 실제 화면에서 toolbar/canvas가 정상 표시되는 것을 확인했다. 수동 필기 회귀는 직선·원·지그재그 gesture smoke까지 확인했으며, 한글 IME(`가나다`)와 압력 변화는 실제 스타일러스/키보드 입력이 필요한 항목으로 별도 수동 확인이 남아 있다.

#### Counter-preserving instrumentation OFF 재실행

revision/repaint 단순 카운터는 instrumentation OFF에서도 수집하도록 조정한 뒤 동일 Profile APK 조건으로 재실행했다. 시간 측정(stopwatch)과 geometry 상세 카운터만 OFF다.

| Mode | Workload | Replay | Build avg/p95/max | Raster avg/p95/max | Total avg/p95/max | Rev updates / active repaints |
|---|---:|---|---|---|---|
| incremental+on | 500 | circle | 0.41/0.65/4.12 | 15.82/18.69/23.42 | 16.23/19.16/23.84 | 97 / 58.0 |
| incremental+on | 500 | handwritingLike | 0.36/0.44/3.28 | 16.21/18.98/30.29 | 16.56/19.48/30.68 | 120 / 72.0 |
| incremental+on | 1000 | circle | 0.45/0.57/4.65 | 16.30/18.93/27.15 | 16.74/19.39/27.62 | 97 / 57.6 |
| incremental+on | 1000 | handwritingLike | 0.42/0.55/3.59 | 16.20/18.40/22.29 | 16.62/18.98/22.76 | 120 / 71.4 |
| incremental+off | 500 | circle | 0.37/0.44/5.19 | 16.15/18.33/21.04 | 16.53/18.64/21.42 | 97 / 57.2 |
| incremental+off | 500 | handwritingLike | 0.35/0.46/2.48 | 14.26/16.69/28.47 | 14.60/17.04/28.70 | 120 / 71.2 |
| incremental+off | 1000 | circle | 0.43/0.51/3.86 | 16.26/18.44/27.04 | 16.69/19.21/27.59 | 97 / 57.8 |
| incremental+off | 1000 | handwritingLike | 0.42/0.53/3.44 | 15.90/18.47/22.80 | 16.33/18.86/23.40 | 120 / 72.0 |
| legacy+off | 500 | circle | 0.37/0.49/2.38 | 15.64/18.18/20.93 | 16.01/18.59/21.40 | 97 / 58.4 |
| legacy+off | 500 | handwritingLike | 0.36/0.45/2.53 | 16.15/18.44/22.29 | 16.51/18.77/22.65 | 120 / 72.0 |
| legacy+off | 1000 | circle | 0.45/0.54/5.47 | 16.16/18.13/20.52 | 16.61/18.67/20.86 | 97 / 58.4 |
| legacy+off | 1000 | handwritingLike | 0.43/0.55/4.16 | 14.17/19.19/35.74 | 14.60/19.61/36.13 | 120 / 71.6 |

이 재실행에서도 OFF와 ON의 frame 분포가 비슷했고, incremental은 legacy 대비 Profile p95가 일관되게 높아지지 않았다. 따라서 판정은 **1. incremental Path 유지**이며, 다음 단일 우선순위는 **B. raster/drawPath 최적화**다. 이번 단계에서 scheduling/throttling은 적용하지 않았다.

### RepaintBoundary 적용 후 Profile 재측정

`DrawingCanvas`에 `RepaintBoundary`를 적용한 최신 Profile APK에서 같은 진단을 다시 실행했다. 500 circle은 total `4.97ms avg / 6.64ms p95 / 11.07ms max`까지 낮아졌고, 다른 workload는 emulator 상태에 따라 `13~17ms avg` 범위로 변동했다. 1000 circle은 `16.09 / 19.65 / 37.17ms`, 1000 handwritingLike는 `16.70 / 18.49 / 22.65ms`였다. ON/OFF/legacy 간 p95는 일관된 악화가 없었고 active revision/repaint도 각각 약 97/58, 120/71회로 동일한 패턴을 유지했다. 단일 500 circle 저하는 확인되지만 emulator 변동 가능성이 있어 추가 raster 최적화의 효과로 단정하지 않고, 현재 `RepaintBoundary` 격리를 유지한다.

### Raster 구간 계측

다음 단계로 렌더링 결과 변경 없이 `canvas.drawPicture`와 active `canvas.drawPath` 구간의 stopwatch를 stroke 종료 시 집계하도록 추가했다. `[DrawingBenchmarkAggregate]` 로그에 `pictureDrawAvgUs/MaxUs`, `activePathDrawAvgUs/MaxUs`가 포함되며, instrumentation OFF에서는 두 시간 계측만 비활성화된다. 이를 통해 raster spike가 정적 picture 합성인지 현재 획 geometry draw인지 분리할 수 있다.

Profile 실측에서 `pictureDrawAvgUs`는 약 `108~169μs`, `activePathDrawAvgUs`는 약 `13~15μs`로 측정되어 정적 picture 합성이 우선 조사 대상이다. 단, 계측 ON/OFF 간 raster 편차가 있어 stopwatch 자체의 영향도 함께 고려해야 하며, 이번 단계에서는 렌더링 알고리즘을 변경하지 않았다.

### Raster 경로 최종 점검

현재 구조를 재점검한 결과 static picture는 `staticRevision` 변경 시에만 생성되고, pointer move에서는 active `RepaintBoundary`만 무효화된다. `drawPicture`는 이미 캐시된 picture를 합성하는 단일 호출이며, active stroke가 static object를 다시 순회하지 않는다. 따라서 picture를 매 frame 다시 녹화하거나 전체 canvas를 재구성하는 불필요한 경로는 확인되지 않았다.

Profile 계측의 `pictureDrawAvgUs`(약 108~169μs)와 `activePathDrawAvgUs`(약 13~15μs)를 비교하면 정적 합성이 상대적으로 크지만, 전체 raster frame(약 14~16ms)의 작은 일부다. picture를 `ui.Image`로 변환하는 추가 캐시는 메모리·해상도 변경·PDF 페이지 전환 복잡도를 늘리는 반면 현재 측정값 대비 이득이 불확실하다. 이번 단계에서는 동작 변경 없이 현재 static/active boundary와 `isComplex/willChange` 힌트를 유지하는 것으로 결론 내렸다. 다음 raster 개선은 실제 Profile trace에서 GPU raster 병목이 재현될 때만 제한적으로 진행한다.

### Static/Active painter layer 분리

`StrokePainter`를 static-only와 active/overlay 용도로 분리해 `Static Drawing Layer`는 `staticRevisionNotifier`에만 repaint되고, pointer move에서는 active painter만 갱신되도록 구성했다. static picture는 저장 객체 변경 시에만 재생성·합성되며 active layer는 committed object를 순회하지 않는다. Debug APK 빌드와 Pixel 7 설치/실행을 확인했다.

각 레이어를 독립 `RepaintBoundary`로 감싸 raster 무효화 범위도 분리했으며, static에는 `isComplex=true/willChange=false`, active에는 `isComplex=false/willChange=true` 힌트를 적용했다. 최신 Debug APK 빌드가 성공했다.

### Active revision frame-aligned coalescing

pointer move마다 active `ValueNotifier`를 즉시 증가시키던 경로를 frame-aligned invalidation으로 보정했다. 포인터 좌표와 pressure는 기존과 동일하게 이벤트마다 `active` 컬렉션에 기록하고, 화면 갱신 요청만 `SchedulerBinding.scheduleFrameCallback`으로 한 프레임에 최대 1회 발행한다. 입력 데이터·저장 포맷·필기 알고리즘은 변경하지 않았다.

stroke 시작은 즉시 repaint해 첫 점을 표시하고, stroke 종료 시 예약된 invalidation을 flush해 마지막 segment가 보인 뒤 commit되도록 했다. 예약 callback에는 generation token을 사용해 pointer-up flush 이후 stale callback이 중복 notifier를 발행하지 않도록 했다. 선택 상태, shape preview, eraser, lasso 등 즉시 반영이 필요한 비-pointer-move 경로는 기존 동기 갱신을 유지한다.

변경 후 계측에서 `activeRevisionUpdates`/`activePainterRepaints`는 raw move 수가 아니라 실제 frame invalidation 수를 나타내며, 정적 레이어 repaint/object paint에는 영향을 주지 않는다. Flutter analyze는 기존 9개 lint/info만 보고했고 컴파일 오류는 없었다. Debug APK를 재빌드해 Pixel 7(emulator-5554)에 설치·실행했다. Profile 수치는 동일 deterministic replay를 재실행한 뒤 추가한다.

Pixel 7 debug 수동 swipe 1회에서 `moves=85`, `activeRevisionUpdates=44`, `activePainterRepaints=42`로 확인됐다. 포인트는 `acceptedPoints=85`로 입력 손실 없이 유지됐고 `staticPainterRepaints=0`이었다. 같은 stroke의 frame 평균은 3.34ms, 최대 5.45ms였으며, coalescing 전보다 notifier 업데이트가 포인터 이벤트 수보다 낮게 기록됐다. 단일 swipe는 통계적 benchmark가 아니므로 방향성 검증용으로만 사용한다.

동일 Pixel 7 Debug replay를 coalescing 적용 후 재실행했다. `500/circle`은 `activeRevisionAvg=60.8`, `activeRepaintsAvg=59.6`, frame `12.66ms avg / 18.71ms p95 / 59.13ms max`였고, `500/handwritingLike`는 `75.4 / 73.6`, `10.96 / 18.41 / 42.54ms`였다. `1000/circle`은 `61.4 / 60.0`, `17.18 / 21.33 / 62.81ms`, `1000/handwritingLike`는 `76.2 / 74.6`, `14.37 / 20.87 / 45.97ms`였다. accepted point 수(`97`/`120`)는 그대로 유지됐다. max frame은 에뮬레이터 변동성이 있어 단일 실행으로 개선을 단정하지 않지만, active revision이 raw move(96/119)보다 낮게 유지되는 것을 확인했다.

### Undo snapshot 메모리 계측

Undo/Redo semantics와 최대 80개 제한은 유지하면서, debug/profile에서 history가 보유한 point·객체 수를 기반으로 한 런타임 메모리 추정치를 추가했다. `[DrawingPerf]`에 `undoDepth`, `redoDepth`, `undoEstimateKb`, `redoEstimateKb`가 출력된다. 이 값은 VM 객체의 정확한 heap 사용량이 아닌 비교용 추정치이며 release 동작에는 포함되지 않는다. snapshot은 기존처럼 불변 domain 객체를 공유하므로 변경되지 않은 stroke의 point 배열을 중복 복사하지 않는다. 실제 사용 workload에서 추정치가 비정상적으로 커지는 경우에만 delta/command history를 별도 검토한다.

Pixel 7에서 기존 1페이지에 짧은 swipe를 1회 작성한 실측은 `undoDepth=1`, `redoDepth=0`, `undoEstimateKb=9.9`, `redoEstimateKb=0.0`이었다. 현재 workload에서는 snapshot 메모리가 작고 domain 객체 공유가 유지되므로 즉시 delta history로 교체할 근거는 확인되지 않았다.

### Active raster hot-path allocation 보정

active stroke를 그릴 때 frame마다 생성하던 `Paint`와 임시 `DateTime`을 `StrokePainter` 수명 동안 재사용하도록 변경했다. Paint 속성(색상·alpha·strokeWidth)은 매 paint마다 현재 상태로 덮어쓰므로 결과와 pressure 처리에는 영향을 주지 않는다. 임시 Stroke의 timestamp는 runtime 표시용이어서 고정 sentinel을 사용하며 저장되는 committed Stroke에는 적용되지 않는다.

이 변경은 geometry/path 알고리즘이나 Canvas layer 구조를 바꾸지 않는 소규모 allocation 감소다. `flutter analyze`와 Debug APK 빌드, Pixel 7 설치·실행을 완료했다. raster 개선 여부는 동일 Profile replay를 다시 실행해 active paint 시간과 p95/max를 비교한다.

### Debug benchmark 상태 격리

Replay benchmark가 실행될 때 사용자의 현재 페이지와 Undo/Redo history를 메모리에 보관하고, 모든 workload가 끝나거나 오류가 발생해도 `finally`에서 원상 복원하도록 보정했다. 따라서 benchmark stroke가 실제 문서, 자동 저장, Undo stack을 오염시키지 않는다. fixture는 계속 debug/profile에서만 실행된다.

### Long-stroke benchmark

debug/profile 메뉴에 `long stroke benchmark`를 추가했다. `longCurve250`, `longCurve500`, `longCurve1000`은 동일한 곡선 path를 각각 250/500/1000 point로 재생하며, 기존 `_start → _move → _end` 입력 경로와 동일한 painter/계측을 통과한다. warm-up 1회 후 5회 평균이 집계되고 incremental/legacy 토글에 따라 label을 구분한다. 실행 전후 페이지와 history는 복원되므로 사용자 문서에 영향을 주지 않는다.

첫 실행에서 `longCurve1000`의 근접 point 병합이 endpoint 변경으로 오인되어 full rebuild가 반복되는 문제를 확인했다(`fullRebuild≈23`, `incrementalSegments≈11,605`). endpoint 좌표 변경 감지를 제거하고 point count/첫 점/페이지 크기만 cache reset 기준으로 사용하도록 보정했다. 이제 근접 point는 기존 path를 재생성하지 않고 다음 accepted point에서 tail segment만 이어간다. 저장 시 committed stroke는 여전히 최종 point 전체로 렌더링되며, drawing algorithm과 저장 포맷은 변경하지 않았다.

보정 후 Pixel 7 Debug 재측정에서 `longCurve1000`은 `fullRebuildAvg=1.0`, `incrementalSegmentsAvg=942.4`로 accepted point(`946`)와 정상 대응했다. `longCurve250/500`도 각각 `fullRebuildAvg=1.0`, `incrementalSegmentsAvg=246.8/496.8`이었다. 1000-point 결과의 frame은 `20.96ms avg / 33.78ms p95 / 310.04ms max`로 emulator scheduling spike가 남았지만, geometry cache가 전체 재생성되는 현상은 제거됐다. 250/500 point는 각각 `18.69/31.72/85.14ms`, `19.08/29.58/103.37ms`였으며 동일 환경 반복 측정 시 max 변동을 함께 고려해야 한다.

### Pressure-aware rendering

압력 범위가 실제로 변하는 Pen stroke에 한해 midpoint quadratic segment를 구간별로 그리며 각 segment의 평균 pressure를 stroke width에 반영하도록 추가했다. pressure 변화가 거의 없는 일반 입력은 기존 incremental Path를 사용하므로 성능·화면 결과를 유지한다. Highlighter와 저장 모델은 변경하지 않았다. 스타일러스가 pressure를 0/1 또는 고정값으로 전달하는 환경에서는 기존 고정 굵기 경로로 동작한다.

에뮬레이터에서도 압력 경로를 재현할 수 있도록 `DEBUG: pressure stroke benchmark`를 추가했다. 기존 long-curve 좌표를 동일하게 재생하되 pressure를 고정 주기로 `.1~1.0` 사이에서 변화시켜 variable-width 렌더러와 frame 계측을 검증한다. 이 fixture 역시 benchmark 종료 후 페이지와 history를 복원하며 release 경로에는 노출되지 않는다.

초기 pressure replay에서는 segment마다 `drawPath`를 호출해 1000 point에서 active paint 평균이 약 1.31ms까지 증가했다. 인접 구간을 0.5px 굵기 bucket으로 묶어 하나의 Path로 batch draw하도록 보정했다. pressure 변화 표현은 유지하면서 Canvas draw 호출 수를 줄이는 방식이며, 다음 Profile replay에서 개선 폭을 확인한다.

#### Pressure replay After (Pixel 7 Debug, batching 적용)

동일한 `longCurve250/500/1000` deterministic pressure replay를 warm-up 1회 제외 5회 평균으로 재실행했다. pressure stroke는 variable-width 경로를 사용하므로 incremental segment counter는 0이며, `fullPathRebuildCount=0`은 active painter가 매 frame 전체 Path를 재생성하지 않고 pressure segment batch를 사용하는 것을 의미한다.

| Workload | Raw / Accepted / Rejected | Active paint avg / max μs | Frame avg / p95 / max ms | Stroke elapsed avg / max ms |
|---:|---:|---:|---:|---:|
| 250 | 249 / 250 / 0 | 249 / 4,478 | 18.14 / 32.78 / 220.72 | 2,747 / 3,016 |
| 500 | 499 / 500 / 0 | 336 / 2,882 | 19.32 / 28.09 / 91.67 | 5,436 / 5,589 |
| 1000 | 999 / 946 / 54 | 549 / 19,812 | 20.45 / 29.71 / 208.89 | 10,756 / 10,907 |

초기 segment별 drawPath 측정치(250/500/1000 active paint 평균 약 465/759/1,310μs)와 비교하면 batching 후 약 249/336/549μs로 각각 약 46%/56%/58% 감소했다. 1000-point의 frame p95도 초기 36.46ms에서 29.71ms로 낮아졌고, 평균 frame은 25.79ms에서 20.45ms로 개선됐다. 다만 에뮬레이터 raster scheduling에 따른 단발성 max spike(250: 220.72ms, 1000: 208.89ms)는 남아 있어 이를 필기 엔진 회귀로 단정하지 않는다. pressure 폭 변화·시작/끝점·저장 포맷은 유지했으며, 다음 우선순위는 추가 알고리즘 변경보다 Profile 동일 replay와 실제 스타일러스 품질 확인이다.

### Lasso bounds 사전 필터링

Lasso 확정 시 선택 다각형의 normalized bounds를 먼저 계산하고, 각 stroke/shape/text/image의 bounds가 겹치지 않으면 기존 point-in-polygon 및 segment 교차 검사를 건너뛴다. 실제 선택 판정 알고리즘과 저장 포맷은 변경하지 않았으며, 경계가 겹치는 후보에 대해서만 기존 정밀 검사를 수행한다. 객체가 많은 페이지에서 멀리 떨어진 객체의 geometry 검사량을 줄이는 목적이다. Eraser는 부분 지우기 의미를 보존하기 위해 이번 단계에서 bounds shortcut을 추가하지 않았다.
