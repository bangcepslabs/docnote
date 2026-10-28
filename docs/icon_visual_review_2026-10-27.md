# 아이콘 및 디자인 검토 — 2026-10-27

## 확인한 문제와 수정

- Adaptive 아이콘과 legacy PNG가 불일치: 해상도별 PNG에 Flutter 로고가 남아 있었다. 노트/종이/책갈피 도형으로 통일했다.
- 기존 adaptive foreground가 원형 마스크에 너무 가깝게 배치되어 있었다. 중심 여백을 확보하고 장식을 단순화했다.
- Android 13 이상 테마 아이콘용 monochrome vector를 추가했다. 실제 런처의 테마 아이콘 활성화 검증은 별도로 남는다.
- 런처 이름을 `docnote`에서 `DocNote`로 정리하고 roundIcon을 연결했다.
- Android 12 이상 시작 화면에 아이콘과 테마 배경을 명시했다. 기존 dark launch 색상은 앱 배경과 같은 `#15171B`로 맞췄다. OS 시작 화면은 시스템 테마를 따른다.
- 다크모드 PDF 배지가 밝은 error 색상 + 흰 글자를 사용했다. 공통 파일 색상을 분리하여 PDF/HWP 흰 글자 대비를 각각 5.61:1 / 5.60:1로 확보했다.

## 범위

Home 정보 구조, 툴바, 생성 callback, 저장 및 필기 로직은 변경하지 않았다. 새로 만들기 실제 화면은 노트 preview와 빠른 작업 위계가 유지되어 구조를 변경하지 않았다.

## 검증

- `flutter analyze`: 통과.
- `flutter build apk --debug --target-platform android-x64`: 통과, Pixel 7 재설치 완료.
- `flutter test test/creation_presentation_test.dart`: 4개 통과.
- Android 리소스 XML 파싱: 통과. PNG 48/72/96/144/192px, Play 512px 확인.
- Pixel 7: 새 아이콘 런처 표시, 앱 실행, light 생성 시트, 시스템 dark Home 확인.
- 스플래시 순간의 화면 캡처는 앱 전환 이미지가 잡혀 시각 검증 근거로 사용하지 않았다.

## 리소스

- 생성: `python tools/generate_launcher_icons.py` (Pillow 필요)
- 스토어 아이콘: `store_assets/google_play/icon.png`
- 런처 전/후: `build/qa/icon-before.png`, `build/qa/icon-after.png`
- 생성 시트: `build/qa/create-review.png`
- 다크 배지 수정 전: `build/qa/home-dark-review.png`
- 다크 배지 수정 후: `build/qa/home-dark-after.png` — 실제 표시 확인 완료. 현재 앱 프로세스 로그에서 Flutter exception/overflow 없음. 검증 후 OS 테마를 기존 light로 복원했다.
