# Explorer UI 독립 코드 리뷰

**결론: Critical 0건, High 3건, Medium 8건, Low 2건이며, 재현된 High 3건으로 SPEC DoD 4번을 통과하지 못한다.**

- 기준 커밋: `db8f25fdbaf95c1884bca18656af23ab374752eb` (2026-11-19 리뷰 시작 시 최신 커밋).
- 대상: `Sources/Explorer/**` 전체. 기준: `docs/SPEC.md` 3·4장, `docs/research.md` 6장.
- `Sources/ExplorerCore/**`는 해당 커밋의 API 계약과 재현 실행에만 사용했다. 다른 에이전트의 작업 중 변경 및 Core 자체 결함은 이 리뷰의 대상이 아니다.
- 소스 수정 및 git commit 없음. 아래 줄 번호는 기준 커밋의 줄 번호다.

## 발견 표

| ID | 심각도 | 파일:줄 | 문제 | 근거 / 재현 | 수정 제안 |
|---|---|---|---|---|---|
| H1 | High | `Sources/Explorer/ConflictDialog.swift:23`, `:30`; `Sources/Explorer/BrowserActions.swift:128` | 동명 원본들의 충돌 결정을 같은 대상 경로 키로 저장해서, 앞 항목에 대한 **건너뛰기**가 뒤 항목의 **덮어쓰기**로 바뀐다. 건너뛴 원본까지 이동·소실된다. | **하네스 재현.** `a/same.txt`, `b/same.txt`, 기존 `dest/same.txt`를 준비하고 두 원본을 이동. 첫 질문에 건너뛰기, 둘째에 덮어쓰기를 응답했다. 결과는 성공이지만 `a/same.txt`와 `b/same.txt` 모두 없어지고 대상에는 둘째 내용만 남았다. 첫 원본 내용은 남지 않았다. 검색 결과에서 동명 항목을 다중 선택하면 가능한 경로다. SPEC F8 위반. | 원본별로 식별되는 작업 계획에 결정을 저장한다. 대상 URL만 받는 콜백에 하나의 딕셔너리를 넘기는 방식을 바꾸고, 배치 안의 동일 대상도 사전에 별개 충돌로 처리한다. 건너뛰기로 답한 원본에는 작업을 실행하지 않는다. |
| H2 | High | `Sources/Explorer/BrowserActions.swift:196`, `:199`, `:212`, `:215`; `Sources/Explorer/AppState.swift:63` | 연속 Undo/Redo를 각각 detached task로 실행해, 의존하는 파일 작업의 역순 실행을 보장하지 않는다. 실패한 기록도 사라져 중간 상태에 멈춘다. | **하네스 재현.** `initial.txt → renamed.txt` 후 그 파일을 포함한 1,001개 항목을 다른 폴더로 이동했다. `undo(nil)`를 연속 두 번 호출하면 첫 역작업이 `renamed.txt`를 복구하기 전에 둘째가 이를 찾다가 실패한다. 최종적으로 `renamed.txt`만 복구되고 `initial.txt`는 없으며 Undo 스택은 0개였다. 빠른 Cmd+Z 및 다른 창의 Undo도 동일한 공유 스택을 사용한다. SPEC F7 위반. | 모든 창이 공유하는 파일 작업 큐에서 Undo/Redo와 일반 변경 작업을 순서대로 실행한다. 실행 중에는 다음 기록을 꺼내지 않거나 큐에만 넣는다. 성공 시에만 두 스택 사이를 이동한다. |
| H3 | High | `Sources/Explorer/BrowserViewController.swift:185`, `:270`, `:289`; `Sources/Explorer/BrowserActions.swift:137` | 폴더 이동 시 주소·현재 위치는 바꾸지만 이전 목록과 선택을 로딩 완료까지 활성 상태로 둔다. 새 위치를 보고 실행한 삭제·잘라내기·이름 변경이 이전 폴더 항목에 적용될 수 있다. | **하네스 재현.** A의 `selected.txt`를 선택하고 B로 `navigate`한 직후 `currentURL`은 B인데 `selectedURLs`는 여전히 A의 파일이며 삭제 메뉴 검증도 `true`였다. B가 느린 디스크·대형 폴더라면 이 구간이 길어진다. 세대 번호 검사는 늦은 결과의 덮어쓰기는 막지만 이 선택 불일치는 막지 못한다. | 다른 위치로 이동할 때 이전 선택·목록을 동기적으로 비우고 로딩 상태를 표시한다. 또는 표시 목록의 위치/세대와 현재 위치가 일치할 때만 변경 명령 및 드롭을 허용한다. |
| M1 | Medium | `Sources/Explorer/BrowserActions.swift:196`, `:203`, `:212`, `:219` | Undo/Redo가 실패해도 먼저 pop한 기록을 복구하지 않아, 일시적 충돌을 해결한 후 다시 시도할 수 없다. | **하네스 재현.** A를 B로 이름 변경한 뒤 A 자리에 다른 파일을 생성하고 Undo. Core가 덮어쓰기를 거부해 B는 그대로지만 Undo 기록 수는 4→3으로 줄었다. 충돌 파일을 치워도 원래 이름 변경의 Undo를 다시 할 수 없다. H2의 동시 실행 없이도 발생한다. | 직렬화한 작업의 성공을 확인한 뒤 기록을 제거한다. 작업이 변경 없이 실패하거나 롤백된 경우 원래 스택과 순서를 유지한다. |
| M2 | Medium | `Sources/Explorer/BrowserActions.swift:87`, `:98`; `Sources/Explorer/ClipboardBridge.swift:41` | 비동기 이동 완료가 그 사이 새로 복사한 클립보드까지 무조건 비운다. | **하네스 재현.** A를 잘라내어 붙여넣기를 예약하고 완료 전에 B를 복사했다. 완료 전 읽기는 B, A 이동 성공 후 읽기는 빈 값이었다. `finishCutPaste()`는 작업을 시작한 대지의 `changeCount`나 소유권을 검사하지 않는다. Finder 호환 이동 붙여넣기에도 적용된다. | 붙여넣기 시작 시 대지 버전을 캡처하고, 완료 시 같은 버전일 때만 대지와 해당 cut 상태를 정리한다. 새 클립보드 내용은 보존한다. |
| M3 | Medium | `Sources/Explorer/KeyCommands.swift:54`, `:65`; `Sources/Explorer/FileListController.swift:164` | 텍스트 편집 상태를 계산하지만 F3/F4/F5 처리에는 적용하지 않는다. F5가 이름 편집 중에도 새로고침을 실행해 입력을 버린다. | **하네스 재현.** `selected.txt`를 F2 경로로 편집하여 `draft.txt`를 입력한 상태에서 F5 이벤트를 handler에 전달했다. `isEditingText == true`인데 이벤트를 소비했고, 재로딩 후 `isRenaming == false`, 디스크에는 원래 이름만 남았다. SPEC 4장 및 research 6장의 입력 우선 정책 위반. | 기능키 처리 전에 텍스트 편집 여부를 검사한다. 편집/조합 중에는 파일 명령을 실행하지 않고 입력기로 넘긴다. 메뉴 키 상당 처리에도 같은 정책을 적용한다. |
| M4 | Medium | `Sources/Explorer/FileListController.swift:30`, `:138`, `:182` | 보기 전환 시 이미 변경된 `mode`로 선택을 읽어서, 사용 중이던 보기의 선택을 잃거나 다른 보기의 오래된 선택을 되살린다. | **하네스 재현.** 자세히 보기에서 table의 `selected.txt`를 사용자 선택 경로로 선택하고 큰 아이콘으로 전환하니 선택이 빈 배열이 됐다. `mode.didSet → applyMode → selectedURLs`가 새 보기인 collection의 선택을 읽는다. 사용자 선택 변경 때 두 보기의 선택을 동기화하지 않는다. | `oldValue`에 해당하는 보기에서 선택을 캡처해 `applyMode`에 전달하거나, URL 기반 선택 모델을 별도로 유지한다. |
| M5 | Medium | `Sources/Explorer/BrowserViewController.swift:256`; `Sources/Explorer/BrowserActions.swift:179`, `:185`, `:332` | 검색 결과에서 새 폴더/파일을 만들면 `reload`가 `selecting`과 `rename`을 버려 즉시 이름 편집이 시작되지 않는다. 검색어에 안 맞으면 생성한 항목도 보이지 않는다. | **하네스 재현.** `*.txt` 검색 중 새 텍스트 문서를 생성했다. 파일 생성은 성공했지만 검색을 재시작할 뿐 `isRenaming == false`였다. 새 폴더도 같은 코드 경로다. SPEC의 P0 F5·F6은 생성 직후 이름 편집을 요구한다. | 생성 시 검색을 종료하고 생성 위치에서 항목을 선택·편집하거나, 검색 완료 후 생성 결과를 선택하고 이름 편집을 이어갈 수 있도록 결과 의도를 보존한다. |
| M6 | Medium | `Sources/Explorer/KeyCommands.swift:81`, `:136`; `Sources/Explorer/MainMenu.swift:61` | SPEC 4장이 명시한 Cmd+D 복제가 없다. Ctrl+D의 휴지통 동작만 구현했다. | **정적 확인.** 전체 UI에 복제 action/메뉴 항목이 없고, Cmd+D는 global handler와 목록 key handler 모두 처리하지 않는다. 같은 폴더 복사 API가 있어도 이 단축키로 연결되지 않는다. | 선택 항목을 같은 부모에 복제하는 명령을 추가하고 Cmd+D에 연결한다. Ctrl+D는 기존 휴지통 동작을 유지한다. |
| M7 | Medium | `Sources/Explorer/NavigationPane.swift:32`, `:157`; `Sources/Explorer/BrowserViewController.swift:264`, `:311` | 한 번 읽은 탐색 트리의 children을 무효화하지 않는다. 생성·삭제·이름 변경 후 F5나 자동 새로고침을 해도 트리에는 오래된 폴더가 남는다. | **정적 확인.** `loadChildrenInBackground`는 `children != nil`이면 반환하고, 펼침 처리도 같은 조건으로 로딩을 건너뛴다. F5·디렉터리 변경 콜백은 중앙 목록만 읽는다. 빈 폴더를 펼쳐 children이 `[]`가 된 뒤 하위 폴더를 만들어도 그 노드는 계속 펼칠 수 없는 상태다. N6/N3 탐색 경로가 중앙 목록과 불일치한다. | 현재/변경된 위치의 트리 캐시를 무효화하고 펼쳐진 노드를 갱신한다. F5에도 트리 재조회 경로를 제공하면서 선택·펼침 상태를 보존한다. |
| M8 | Medium | `Sources/Explorer/BrowserViewController.swift:365`, `:319`; `Sources/Explorer/FileListController.swift:163` | 검색 배치마다 전체 누적 결과를 메인 스레드에서 다시 정렬하고 두 보기 모두 `reloadData`한다. 1만 개 결과에서 UI 작업이 크게 누적된다. | **Debug 하네스 측정.** 합성 결과 10,000개를 실제 `appendSearchResults`에 200개씩 50회 전달하니 메인 스레드에서 7.51초가 걸렸다. 같은 항목 한 번 정렬은 0.27초였다. 매번 누적 전체를 처리하므로 총 255,000개 분량의 배열을 정렬·선택 스캔·리로드한다. 디스크 검색 시간은 이 수치에 포함하지 않았다. 출시 빌드는 미측정이다. | 배치를 합쳐 표시 빈도를 제한하고, 누적 정렬은 백그라운드에서 세대 검사와 함께 수행한다. 정렬된 배치 병합 또는 차이 갱신을 사용하고 활성 보기만 갱신한다. |
| L1 | Low | `Sources/Explorer/BrowserViewController.swift:208`, `:399`; `Sources/Explorer/BrowserActions.swift:364` | 루트에서도 상위 폴더 버튼과 메뉴가 활성화되고 내 Mac으로 이동한다. | **정적 확인.** 버튼/메뉴의 조건은 `!isThisMac`뿐이고, 부모가 없으면 `Location.thisMac`으로 이동한다. SPEC N2의 "루트에서 비활성"과 다르다. | 루트 여부를 버튼·메뉴·키 명령에 공통 적용한다. 이 동작을 의도한 경우 먼저 명세를 변경한다. |
| L2 | Low | `Sources/Explorer/AddressBar.swift:128` | 경로 조각의 하위 폴더 메뉴가 200개에서 조용히 잘린다. | **정적 확인.** 정렬 결과에 `prefix(200)`을 적용하고 더 보기/페이지/검색 항목이 없다. 201번째 이후 폴더는 SPEC N4의 메뉴로 이동할 수 없다. | 항목을 추가 로딩하거나 더 보기/검색을 제공하고, 제한이 있음을 표시한다. |

## 검증과 범위

- 기준 커밋을 `/tmp/explorer-review-ui/baseline/`에 추출하여 검토했다. 격리 사본에서 `swift build --scratch-path /tmp/explorer-review-ui/build`가 경고 없이 성공했다. 환경은 macOS 26.4 arm64, Swift 6.2.4, 빌드 SDK 26.2다.
- 재현 코드는 `/tmp/explorer-review-ui/harness-src/`, 최종 로그는 `/tmp/explorer-review-ui/harness-final.log`에 있다. H1~H3, M1~M5, M8은 하네스에서 재현했고 나머지는 정적 확인이다. 재현 실패를 정상 통과로 취급한 XCTest 결과가 아니라, 위에서 설명한 실제 상태·파일 내용·스택·시간을 출력하는 별도 실행 파일이다.
- 하네스는 임시 사본의 진입점을 교체하고 private 함수 두 개(`GlobalKeyHandler.handle`, `appendSearchResults`)의 접근 제한만 완화했다. 대지는 전용 이름의 `NSPasteboard`, 앱 지원 경로는 `/tmp`로 바꿨다. 재현 파일 작업은 모두 `/tmp/explorer-review-ui/` 아래에서 실행했으며 사용자 클립보드는 사용하지 않았다.
- 늦은 폴더/검색 결과는 `loadGeneration`으로 검사한다. UI 갱신은 MainActor로 복귀하며, `windowWillClose → tearDown`에서 검색 취소·watcher 중지·알림 해제 경로를 확인했다. 이 범위에서 별도의 확정된 main 외부 UI 접근이나 watcher 누수는 찾지 못했다. 아이콘은 표시 셀에서 요청하지만 `NSWorkspace.icon(forFile:)` 호출 자체는 main의 동기 호출이어서 느린 볼륨 실측은 별도로 필요하다.
- 영구 삭제에는 명시적 확인 시트가 있고 삭제 대상 URL은 확인 전에 캡처한다. 인라인 이름 편집의 확장자 제외 선택, Enter 확정·Esc 취소 코드를 확인했다. 드래그 정책의 같은 볼륨 이동·다른 볼륨 복사·Option 복사 및 Core의 자기 하위 이동 거부 연결도 확인했다.
- 실제 한국어 입력기·물리 키 입력과 메뉴 응답자 체인의 통합 동작, Finder 양방향 대지, 외부 앱 드래그 및 서로 다른 실물 볼륨은 검증하지 않았다. 하네스에서는 `NSApp.keyWindow`를 실제 브라우저 키 창으로 만들지 못했으므로, marked text를 넣은 F2 메뉴 실험은 판정 근거에서 제외했다. 이 제한은 실제 키보드/화면 smoke 검증을 대체하지 않는다.

## 우선 수정 순서

1. H1: 동명 원본의 결정 식별 및 원본 보존.
2. H2와 M1: 앱 전체 작업 직렬화 및 성공 후 Undo/Redo 스택 갱신.
3. H3: 위치 전환 중 이전 항목을 대상으로 한 변경 명령 차단.
4. M2~M8 수정 후 텍스트·한국어 조합·메뉴·탭·외부 앱 연동을 실제 UI에서 회귀 확인.
