# 주요 화면 디자인 정리

## 변경

- 하단 내비게이션: 전체 셀 배경 대신 아이콘 주변 44×28dp 표시. 실제 버튼 영역은 56dp 높이로 유지. 선택 배경은 160ms 전환하며 시스템 애니메이션 비활성화 설정을 따른다.
- 홈: 섹션 제목을 16/18dp semibold로 정리하여 문서와 제목의 위계를 조정.
- 홈/문서/검색: `_LibraryFilterChip`으로 모양, 간격, 색상과 텍스트를 공유. 각 화면의 필터 상태/callback은 유지.
- 생성 시트: 제목과 작업 카드의 과한 bold를 semibold로 정리.
- 설정: 그룹 외곽선 제거, 얇은 내부 구분선, 작은 보조 섹션 제목, 중립색 아이콘으로 정리.

수정 소스는 `lib/main.dart`. 편집기/툴바/저장/문서 데이터는 이번 변경에 포함하지 않았다.

## 검증

- `flutter analyze`: 문제 없음.
- `flutter test test/navigation_layout_qa_test.dart test/creation_presentation_test.dart`: 18개 통과.
- 화면 테스트: 320/360/390/412/430px 모바일, 840×420, 1200×800, light/dark, 글자 크기 1.3배.
- Debug x64 APK 빌드 및 Pixel 7 설치 완료.
- Pixel 7 실제 Home/Documents/Search/Settings와 dark Documents/Create Sheet 확인. 현재 프로세스 로그에 Flutter exception/overflow 없음.
- OS night mode는 검증 후 원래 light로 복원.
- 태블릿은 이번 작업에서 위젯 레이아웃 테스트로 검증했으며 실제 태블릿 에뮬레이터 캡처는 하지 않았다.

## 캡처

- `build/qa/home-polish.png`
- `build/qa/documents-polish.png`
- `build/qa/search-polish.png`
- `build/qa/settings-design-before.png`
- `build/qa/settings-polish.png`
- `build/qa/create-dark-polish.png`
