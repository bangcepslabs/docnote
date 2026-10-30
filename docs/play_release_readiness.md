# Google Play 출시 준비 점검

최신 점검일: 2026-10-30. 아래의 2026-10-06 항목은 당시 빌드의 기록이며, 현재 배포 산출물 판정은 바로 다음 절을 따른다.

## 최신 코드 기준 출시 검증 (2026-10-30)

- 기준 커밋: `e9d3e74` (`origin/main`). rhwp 0.8.7 연결, 미주 줄 간격 수정, 가상 layer ID 파서 수정 포함.
- `flutter test --no-pub`: 93개 통과. `flutter analyze --no-pub`: 문제 없음. 로그는 로컬 `build/release-qa-flutter-test.log`, `build/release-qa-analyze.log`.
- ARM 릴리즈 APK: `build/app/outputs/flutter-apk/app-release.apk`, 86,994,762 bytes, SHA-256 `f2edb1bbaaae801fac8c3e678b47de0afa880de051b43241199483aac20423d0`; APK v2 서명 확인.
- 최신 릴리즈 AAB: `build/app/outputs/bundle/release/app-release.aab`, 85,489,537 bytes, SHA-256 `d504ff7bbaa964a2d88688bd92276ae510e83120f7a3eab2059c326b50862e0a`. `jarsigner -verify` 통과. 자체 서명 인증서라 공인 체인·타임스탬프 경고는 있다.
- 릴리즈 APK 식별 정보: `com.bangceps.docnote`, versionCode 1, versionName 0.1.0, min API 24, target API 36.
- Pixel 7 x86_64 에뮬레이터의 같은 코드 디버그 빌드에서 긴 HWP 202쪽 마지막 미주와 QA PDF 2쪽 열기를 화면으로 확인했다. 기존 PDF 필기 오버레이도 표시됐다. 이는 ARM 릴리즈 실행 검증을 대신하지 않는다.
- 이번 점검에서 가져오기, 새 필기·저장, 수동 백업·복원, 삭제·복구, PDF 내보내기 전체 흐름을 새 빌드로 다시 실행하지 않았다. 기존 자동 테스트 및 이전 QA 기록이 있지만 최신 실기기 통과로 간주하지 않는다.
- **공개 출시 판정: 보류.** ARM 실기기에서 릴리즈 설치·핵심 편집/저장/재진입, 내부 테스트 트랙의 AAB 설치/업데이트, 최소 API 24 기기, 실제 사용자 HWPX와 암호화·손상 파일 오류 안내, 업로드 키의 별도 보관을 확인해야 한다.

## 코드 및 패키지에서 확인한 내용

- [x] 릴리즈 빌드 서명 설정: `android/key.properties` 및 `android/upload-keystore.jks` 사용. 두 파일은 Git에서 제외됨.
- [x] Android 앱 백업 정책: `android:allowBackup="false"`로 Android 클라우드 자동 백업 비활성화.
- [x] target API: 릴리즈 APK에서 target API 36, min API 24 확인.
- [x] 광고·분석·충돌 보고 SDK: 앱 의존성 목록에서 확인되지 않음.
- [x] 사용자 파일은 파일/사진 선택으로 가져오며 앱 서버 업로드 코드가 없음.
- [x] 앱 내 개인정보 처리방침 화면 및 본 문서 추가.
- [x] 실제 HWP 샘플: `third_party/flutter_rhwp/example/assets/korea_ai_action_plan_2026_2028.hwp` 존재.
- [x] 2026-10-06 Pixel 7 에뮬레이터에서 제공된 HWP 샘플을 가져와 열기 및 첫 페이지 렌더링 확인(204페이지).
- [x] 최신 릴리즈 산출물 생성: `build/app/outputs/bundle/release/app-release.aab` (90.1 MB), `build/app/outputs/flutter-apk/app-release.apk` (95.2 MB).
- [x] AAB/APK 업로드 서명 검증: 자체 업로드 인증서 SHA-256 `b665ca476931f98a8410f7f976f13f98094a04d467d0a0b80bf602171ddc2dc9`.
- [x] 릴리즈 APK 병합 manifest에서 `allowBackup=false` 확인.
- [x] `flutter analyze` 및 `flutter test` 통과(36 tests).
- [x] 테스트용 HWP 복사본을 Pixel 7 에뮬레이터에서 제거함.

## Play Console에 입력하기 전 완료할 항목

- [ ] Play Console의 internal test track에 현재 AAB를 업로드하고 설치/업데이트 흐름 확인.
- [x] 공개 개인정보 처리방침을 GitHub Pages에서 HTTP 200으로 확인: https://bangcepslabs.github.io/docnote/privacy-policy.html
- [ ] Google Play Data safety form을 실제 배포 AAB와 SDK 동작 기준으로 제출. 공유 시트로 사용자가 직접 외부 앱에 보내는 문서의 처리 항목을 폼 정의에 따라 확인.
- [ ] 스토어 등록 개발자명과 문의 연락처를 확정하고 배포 페이지에 표시.
- [ ] 앱 설명에 로컬 저장, 수동 백업, 백업 ZIP 비암호화, PDF 내보내기의 페이지 이미지화, HWP 호환 범위를 고지.
- [ ] 그래픽 에셋, 스크린샷, 콘텐츠 등급 및 대상 연령 등 Play Console 항목 작성.
- [ ] HWPX, 암호화/손상/대용량 HWP 파일의 지원 범위를 실문서로 확인하고 실패 안내 검증.
- [ ] 최소 지원 API 24 기기와 최신 Android 기기에서 설치, 문서 가져오기/삭제/복원, 수동 백업/복원, PDF 내보내기를 확인.
- [ ] 릴리즈 키와 비밀번호를 작업 PC 외부의 안전한 별도 저장소에 백업하고 복구 절차를 검증.
- [ ] Google Play에 이미 같은 applicationId가 등록되어 있다면 현재 Play 앱 서명/업로드 인증서와 새 키가 호환되는지 확인. 기존 로컬 APK는 Android Debug 인증서로 서명되어 있음.

## 릴리즈 산출물 주의사항

- 현재 앱 버전은 `0.1.0+1`이며 새 앱의 첫 Play 업로드라면 시작 버전으로 사용할 수 있습니다. 기존 Play 트랙에 같은 패키지의 더 높은 versionCode가 있다면 버전을 올려 다시 빌드해야 합니다.
- 개인정보 처리방침과 HTML 페이지는 커밋 `bb0a858`, 보안 설명 보완은 `2b9a29e`로 푸시했습니다. Pages 주소에서 정책 제목, 문의 이메일, 추가 암호화 미적용 안내까지 HTTP 200 응답으로 확인했습니다.
- 이번 업로드 인증서는 새 자체 서명 키입니다. Play Console의 기존 앱에 등록된 업로드 키가 있다면 지문이 일치하는지 확인하고, 다르면 업로드 키 재설정 절차를 먼저 진행해야 합니다.
- 업로드 키 파일과 비밀번호의 오프사이트 보관은 아직 완료되지 않았습니다. 키 백업 전에는 이 키를 유일한 운영 키로 취급해 배포하지 마세요.
- 현재 디버그 설치본은 Android Debug 인증서로 서명되어 릴리즈 서명 APK로 바로 업데이트할 수 없습니다. 테스트 데이터를 보존하려면 먼저 앱의 `.docnote` 백업을 내보낸 뒤 릴리즈 설치를 진행해야 합니다.

## 사용자 데이터 안내 초안의 경계

DocNote는 앱 자체 서버, 계정, 광고, 분석 및 원격 충돌 수집을 사용하지 않는 것으로 코드 의존성과 Android 설정을 점검했다. 사용자가 선택한 파일은 기기에 복사·처리된다. 사용자가 명시적으로 외부 공유를 실행하면 선택한 공유 대상 서비스가 파일을 처리할 수 있다. `.docnote` 백업은 암호화되지 않으므로 Data safety 답변과 스토어 설명에 이를 숨기거나 암호화 저장으로 표현하지 않는다.
