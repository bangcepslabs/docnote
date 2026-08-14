# DocNote 디자인 시스템 v2

DocNote는 파일 목록보다 노트북 생성, 종이 선택, 문서 열람과 편집이 자연스럽게 이어지는 paper-inspired productivity 제품으로 보이도록 설계한다.

## Layout

- 모바일 좌우 padding: 16px
- 태블릿 좌우 padding: 24px
- 기준 spacing: 4 / 8 / 12 / 16 / 20 / 24 / 32px
- Root header: 64px, 태블릿 72px
- Section gap: 24px
- Card gap: 8px
- Bottom navigation: 76px + safe-area inset
- 모든 주요 조작 영역은 44px 이상

## Typography

- Screen title: 24px / 1.35 / 650
- Section title: 17px / 1.45 / 650
- Card title: 14–15px / 1.45 / 600
- Body: 14–15px / 1.65–1.75 / 400
- Metadata: 12px / 1.5 / 400
- Display: Noto Sans KR, Apple SD Gothic Neo
- Body: Pretendard, Noto Sans KR, Apple SD Gothic Neo

## Surfaces and radius

- Background: `--bg`
- Primary surface: `--surface`
- Quiet surface: `--subtle`
- Border: `--border`, 기본 상태에서는 낮은 대비
- Radius: 8px preview, 12px control, 14px card, 20px sheet
- Shadow는 bottom sheet와 overlay처럼 깊이 관계가 필요한 경우에만 사용

## Actions

- Primary: `--accent` fill, 생성 흐름의 핵심 action 하나만 사용
- Secondary: surface + soft border
- Quiet: border 없는 ghost control
- Active: `--accent-soft` 배경 + `--fg` 텍스트
- Focus: accent outline, 기본 border와 혼동되지 않도록 분리

## Create flow

- Create Sheet는 modal bottom sheet이며 handle, title, action row를 공유한다.
- 새 노트북은 표지·속지 선택으로 이어지는 가장 중요한 첫 action이다.
- PDF/HWP 가져오기는 imported document preview 규칙으로 확장한다.
- 빠른 메모는 노트북 생성과 구분되는 가벼운 입력 경험으로 둔다.

## Notebook creation

- New Notebook: 제목 → 표지 → 속지 → 생성
- Cover Picker: 2열 모바일, 3열 태블릿; 실제 커버 비율과 category chip 사용
- Paper Picker: 2열 모바일, 3열 태블릿; 실제 종이 패턴 preview 사용
- 선택 상태는 강한 그림자보다 accent border와 선택 라벨로 전달

## Editor extension

- HWP/PDF/Memo editor는 문서 canvas가 중심이고 toolbar는 compact하게 유지한다.
- 모드 탭은 가로 overflow 대신 우선순위가 높은 도구만 노출하고 나머지는 sheet로 보낸다.
- Bottom sheet는 content-driven height, safe-area padding, 20px top radius를 사용한다.
- PDF annotation과 HWP tool panel은 동일한 icon button, option row, selected state를 공유한다.

## States and accessibility

- Empty, loading, error 상태는 같은 state panel 구조를 사용한다.
- 파일명은 `min-width:0`, ellipsis, 별도 type metadata로 처리한다.
- 모든 icon-only control에 accessible label을 부여한다.
- `:focus-visible` ring을 유지하고, reduced motion에서는 transition을 제거한다.
- Search native cancel UI는 제거하고, 입력값이 있을 때만 quiet clear button을 노출한다.
