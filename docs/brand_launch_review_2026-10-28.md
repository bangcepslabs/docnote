# 로고 및 첫 화면 검수 — 2026-10-28

## 변경

- 정적 PNG에 adaptive foreground의 108dp 이동 여백까지 포함되어 심벌이 작게 보이던 문제를 수정. 중앙 72dp 영역으로 출력한다. Adaptive XML의 안전 여백은 변경하지 않는다.
- 같은 도형 정의에서 홈용 SVG를 생성하여 런처/시작 화면/홈의 브랜드 표현을 연결했다.
- 홈 제목 옆 26×30dp 심벌, 9dp 간격, semibold 워드마크. 심벌은 중복 음성 읽기에서 제외하고 제목은 Flexible/ellipsis로 제한한다.
- Home 정보 구조, 문서 데이터, 툴바 및 기능 로직은 유지했다.

## 검증

- flutter analyze: 문제 없음.
- navigation_layout_qa_test: 14개 통과 (320~1200px, 라이트/다크, 글자 1.3배).
- Debug APK 빌드 성공 및 Pixel 7 설치.
- 실제 콜드 실행에서 라이트/다크 Android 시작 화면 로고와 배경을 캡처 확인.
- 실제 Home의 브랜드 심벌, 제목, 검색 버튼 정렬 확인.
- 현재 앱 프로세스에서 Flutter 오류/overflow 로그 없음. OS 테마는 기존 light로 복원.
- 이번 검수는 Debug 실행으로 출시 빌드 시작 속도 평가를 대신하지 않는다. 구형 런처 PNG는 파일 검증이며 별도 구형 기기 실행은 하지 않았다.

## 캡처

- 변경 전 Home: build/qa/launch-review28.png
- 변경 후 Home: build/qa/brand-home28.png
- 시작 화면 light: build/qa/brand-start28.png
- 시작 화면 dark: build/qa/brand-start-dark28.png
- 스토어 아이콘: store_assets/google_play/icon.png
