# DocNote 브랜드 스펙

기존 `lib/core/theme/docnote_theme.dart`의 Material 3 색상과 간결한 Android 문서 앱 구조를 기반으로, 밝은 종이 표면과 차분한 청색 포인트를 사용한다.

```css
:root {
  --bg: oklch(0.977 0.004 260);
  --surface: oklch(1 0 0);
  --fg: oklch(0.205 0.027 250);
  --muted: oklch(0.49 0.025 250);
  --border: oklch(0.90 0.012 250);
  --accent: oklch(0.52 0.115 247);
}
```

- 기존 상수: accent `#2f6eaa`, page `#f6f7f9`, ink `#17212c`
- 표면은 흰색과 page 회색을 중심으로 사용한다.
- Material 3의 8/12/16px 반경과 4/8/12/16/24px 간격 스케일을 유지한다.
- 문서·노트·PDF·HWP를 하나의 라이브러리 흐름에서 다루고, 파일 형식은 색보다 라벨과 썸네일로 구분한다.
- 앱 아이콘은 청색 노트 커버, 흰 종이, 작은 코랄 책갈피를 사용한다. 작은 크기에서 식별하기 어려운 텍스트·장식·그림자는 넣지 않는다.
- Android adaptive/legacy 아이콘과 Play 아이콘은 `tools/generate_launcher_icons.py`에서 동일한 도형 정의로 생성한다. Android 13 테마 아이콘은 별도 단색 벡터를 사용한다.
- 런처 표시 이름은 `DocNote`로 통일한다. 시작 화면은 light `#F7F8FA`, dark `#15171B`를 사용한다.
- 홈 제목에는 같은 생성 소스로 만든 `assets/brand/docnote_mark.svg`를 사용한다. 심벌은 장식용으로 중복 읽지 않으며 제목과 검색 버튼의 공간을 확보한다.
- Adaptive foreground는 108dp의 이동 여백을 유지한다. 정적 PNG는 중앙 72dp 영역을 출력하여 스토어/구형 런처에서 심벌이 지나치게 작아지지 않게 한다.
- 시스템/라이트/다크 테마를 지원하는 구조이므로 포인트 컬러는 절제해 사용한다.

Display: `"SUIT", "Noto Sans KR", "Apple SD Gothic Neo", sans-serif`  
Body: `"Noto Sans KR", "Apple SD Gothic Neo", sans-serif`  
Mono: `"SFMono-Regular", "Cascadia Code", monospace`
