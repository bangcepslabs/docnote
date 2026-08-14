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
- 시스템/라이트/다크 테마를 지원하는 구조이므로 포인트 컬러는 절제해 사용한다.

Display: `"SUIT", "Noto Sans KR", "Apple SD Gothic Neo", sans-serif`  
Body: `"Noto Sans KR", "Apple SD Gothic Neo", sans-serif`  
Mono: `"SFMono-Regular", "Cascadia Code", monospace`
