# DocNote 디자인 시스템 v1

DocNote는 문서를 많이 보여주는 앱이 아니라, 노트북을 고르고 문서를 다시 여는 흐름이 편안하게 이어지는 paper-inspired productivity UI를 지향한다.

## Audit 요약

- Flutter 테마에는 공통 색상·반경·간격 토큰이 있으나 실제 Home과 문서 목록에서 20px 좌우 여백, 10/12px 간격, 14/16px 반경이 함께 사용되어 화면별 기준선이 달라진다.
- Home은 quick action, feature card, notebook, template, imported document가 한 흐름에 섞여 있어 notebook이 핵심인지 가져온 문서가 핵심인지 시선 우선순위가 약하다.
- Documents는 notebook 표지와 PDF/HWP preview가 같은 문서 카드 언어로 읽혀 콘텐츠 유형의 차이가 약하고, 제목·설명·filter·목록 사이의 vertical rhythm이 화면마다 달라진다.
- Search는 search field·filter·result row가 각각 다른 높이와 padding을 가져 탐색 흐름이 끊긴다. 결과 썸네일도 유형별 구분이 필요하다.
- Settings는 Material ListTile 중심으로 구성되어 있어 섹션 그룹과 supporting text의 위계가 약하다.
- New Notebook / Cover Picker / Template Picker는 이미 coverId와 pageStyle 개념을 가지고 있으므로 새 기능을 추가하지 않고, 선택 상태와 미리보기 비율만 공통화한다.
- Notebook editor, PDF editor, HWP editor는 로딩·오류·저장 상태를 실제로 가지고 있다. 향후 editor chrome은 44px touch target, 짧은 제목 ellipsis, 상태 메시지 위치를 공통화한다.

## Tokens

```css
:root {
  --bg: oklch(0.977 0.004 260);
  --surface: oklch(1 0 0);
  --surface-subtle: oklch(0.958 0.007 255);
  --fg: oklch(0.205 0.027 250);
  --muted: oklch(0.49 0.025 250);
  --border: oklch(0.90 0.012 250);
  --accent: oklch(0.52 0.115 247);
  --accent-soft: oklch(0.93 0.032 247);
  --success: oklch(0.52 0.12 150);
  --danger: oklch(0.53 0.15 25);
}
```

- Display: `SUIT`, `Noto Sans KR`, `Apple SD Gothic Neo`, sans-serif
- Body: `Noto Sans KR`, `Apple SD Gothic Neo`, `Malgun Gothic`, sans-serif
- Mono: `ui-monospace`, `SFMono-Regular`, `Consolas`, monospace

## Layout

- 화면 좌우 padding: 16px
- Header: 64px, 좌우 padding 16px, title baseline과 action center를 동일하게 맞춤
- Section gap: 24px
- Element gap: 4 / 8 / 12 / 16px
- Card padding: 16px
- Bottom navigation: 80px + `safe-area-inset-bottom`
- 모든 주요 조작 영역: 최소 44px
- Notebook row만 수평 스크롤을 허용하고, filter는 줄바꿈으로 처리한다.

## Type scale

- Screen title: 24px / 1.35 / 700
- Section title: 17px / 1.45 / 700
- Card title: 15px / 1.5 / 650
- Body: 14px / 1.7 / 450
- Metadata: 12px / 1.55 / 550
- Caption: 11px / 1.55 / 600

## Component rules

- AppHeader는 모든 root screen에서 같은 높이와 action target을 사용한다.
- SectionHeader는 title과 action의 baseline을 맞추고, section 간격은 24px로 고정한다.
- NotebookCard는 cover가 주인공이다. ImportedDocumentCard는 first-page preview가 주인공이다.
- Accent는 active navigation과 primary create action에만 사용한다. 일반 링크는 foreground + underline 또는 muted text로 처리한다.
- Radius는 8 / 12 / 16px 세 단계만 사용한다. 큰 radius를 모든 요소에 적용하지 않는다.
- Hover/focus/pressed 상태는 foreground 대비를 낮추지 않는다. 모든 버튼은 `:focus-visible` ring을 갖는다.
- 빈 상태는 과도한 일러스트 대신 다음 행동 하나와 짧은 설명을 제공한다. 로딩은 preview skeleton, 오류는 재시도 action을 제공한다.

## 확장 대상

New Notebook은 Cover Picker와 Template Picker를 같은 bottom sheet 내부의 단계형 선택으로 묶고, editor는 이 시스템의 header·toolbar·paper surface만 공유한다. PDF/HWP는 imported document card와 동일한 preview 문법을 사용하되, 편집 도구는 문서 위에 떠 있는 단일 tool panel로 제한한다.
