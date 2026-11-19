# 탐색기 (Explorer for Mac)

macOS 에서 Windows 11 파일 탐색기처럼 동작하는 파일 관리자입니다.
Windows 에서 넘어와 Finder 가 낯선 사용자를 위해 만들었습니다.

## 빌드와 실행

```sh
scripts/build-app.sh            # build/Explorer.app 생성 (release, ad-hoc 서명)
open build/Explorer.app         # 홈 폴더로 시작
open build/Explorer.app --args /path/to/folder   # 시작 폴더 지정
swift test                      # Core 단위 테스트
```

요구 사항: macOS 14 이상, Xcode 16 이상 (Swift 6 툴체인).

## Finder 와 다른 점

| Windows 습관 | 이 앱 | Finder |
|---|---|---|
| Enter 로 열기 | Enter = 열기 | Return = 이름 바꾸기 |
| F2 이름 바꾸기 | F2 | Return |
| 잘라내기 → 붙여넣기 | Cmd+X → Cmd+V (Cmd+⌥+V 도 지원) | Cmd+C → Cmd+⌥+V 만 |
| Backspace 뒤로 | ⌫ = 뒤로, ⌥↑ = 상위 폴더 | Cmd+[ / Cmd+↑ |
| Delete 휴지통 | ⌦(Fn+⌫), Cmd+⌫, Ctrl+D | Cmd+⌫ |
| 주소 표시줄 직접 입력 | Cmd+L, ⌥D, F4. `~`, `\`, `%USERPROFILE%` 허용 | Cmd+Shift+G 대화상자 |
| 폴더 우선 정렬 | 모든 정렬에서 폴더가 먼저 | 설정 필요 |
| 새 텍스트 문서 | 새로 만들기 메뉴 | 없음 |
| 경로 복사 | 우클릭 또는 Cmd+Shift+C | ⌥ + 우클릭 |
| 같은 폴더 붙여넣기 | "이름 - 복사본" | "이름 copy" |
| 폴더 덮어쓰기 | 병합 (Windows 와 같음) | 대상 폴더 교체 |

Ctrl 조합은 대부분 Cmd 와 같게 받습니다.
예외로 Ctrl+클릭은 macOS 대로 컨텍스트 메뉴입니다.

전체 단축키와 기능 목록은 [docs/SPEC.md](docs/SPEC.md) 를 봅니다.

## 문서

| 문서 | 내용 |
|---|---|
| [docs/research.md](docs/research.md) | Windows 탐색기와 Finder, 대안 앱 비교 조사 |
| [docs/SPEC.md](docs/SPEC.md) | 기능 정의서와 완료 기준 |
| [docs/review-core.md](docs/review-core.md) | Core 리뷰와 재검증 기록 |
| [docs/review-ui.md](docs/review-ui.md) | UI 리뷰와 재검증 기록 |

## 구조

| 모듈 | 역할 |
|---|---|
| `Sources/ExplorerCore` | 파일 작업, 정렬, 탐색 기록, 주소 해석, 검색, 폴더 감시. Foundation 만 사용 |
| `Sources/Explorer` | AppKit UI. 탐색 창, 주소 표시줄, 자세히·아이콘 보기, 미리 보기, 속성 창 |
| `Tests/ExplorerCoreTests` | Core 단위 테스트 |
