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

## 재검증

**결론: 기존 H1~H3·M1~M8·L1~L2 13건은 아래 재현 범위에서 닫힘. 새로 확인한 문제는 Critical 0건, High 1건, Medium 2건이다. 마지막 창 닫기로 진행 중 이동과 대기 작업이 중단되어 SPEC DoD 4번은 여전히 통과하지 못한다.**

- 기준: `5603ff4161d3ef28491790a5e4ff33bd83b2fcf6` (2026-11-19). `git log --oneline -3`, `git show HEAD -- Sources/Explorer` 검토 후 `git archive`로 `/tmp/explorer-verify-ui/baseline/`에 고정했다. 작업 중인 Core·테스트 파일은 읽거나 빌드에 섞지 않았다.
- 격리 사본 `swift build --scratch-path /tmp/explorer-verify-ui/build` 경고 없이 성공. 기존 두 하네스를 참고해 최신 UI 소스와 **동일 커밋 Core 오브젝트**를 링크했다. 소스 수정·커밋 없음. 이 절만 원본 문서 끝에 추가했다.
- 실행 근거: `/tmp/explorer-verify-ui/regression.log`, `advanced-final.log`, `performclose.log`, `smoke.log`, `termination-transfer-close.log`, `termination-close.log`, `termination-quit.log`, `termination-state.json`. 하네스 진입점은 같은 디렉터리의 `main-*.swift`, 접근 범위 등 시험용 변경 목록은 `instrumentation.md`에 있다. 줄 번호는 기준 커밋이다.

### 기존 지적 판정

| ID | 판정 | 재현 결과 / 근거 |
|---|---|---|
| H1 | 닫힘 | 동명 원본 두 개 이동 시 첫 원본 건너뛰기, 둘째 덮어쓰기: 첫 원본 내용 보존, 둘째만 이동, 대상은 둘째 내용. 질문에도 각각의 원본 경로가 표시됐다. 첫 원본 덮어쓰기 후 둘째는 Core 정책대로 별도 이름으로 보존됨도 확인했다. 폴더 병합은 `m/a.txt` 건너뛰기·`m/sub/b.txt` 덮어쓰기·새 `c.txt` 이동 모두 기대대로였다. |
| H2 | 닫힘 | 이름 변경 후 1,001개 이동을 연속 Undo 두 번: `initial.txt` 복구, 중간 `renamed.txt` 없음, Undo 0/Redo 2. 연속 Redo 두 번도 최종 이동 상태와 Undo 2 복구. 모두 공유 큐를 사용한다. |
| H3 | 닫힘 | A 선택 후 B로 `navigate`한 같은 실행 구간에서 이전 선택이 빈 배열이고 삭제 메뉴도 비활성. 비동기 목록 완료를 기다리지 않아도 이전 파일을 대상으로 할 수 없었다. |
| M1 | 닫힘 | 이름 복구 위치를 다른 파일로 막고 Undo 실패: 기록 1개 유지. 오류 시트를 닫고 방해 파일 제거 후 재시도하여 원래 이름 복구 및 Redo 기록 생성. |
| M2 | 닫힘 | 잘라내기 붙여넣기 직후 다른 파일 복사: 첫 이동 성공 후에도 새 파일 URL이 전용 대지에 남았다. 완료 시 캡처한 `changeCount`를 검사한다. |
| M3 | 닫힘 | 인라인 편집 중 F5가 handler에서 통과되고 편집 상태 유지. 변경 코드의 `!editing` 조건은 F3·F4·F5에 공통 적용된다. 물리 한국어 입력기 조합까지 검증한 결과는 아니다. |
| M4 | 닫힘 | 자세히 보기에서 사용자가 고른 항목이 큰 아이콘으로 전환 후 유지. 아이콘 보기에서 선택을 비운 뒤 자세히로 돌아와도 오래된 선택을 되살리지 않았다. |
| M5 | 닫힘 | 검색 중 새 텍스트 문서와 새 폴더를 각각 생성: 검색 종료, 항목 생성, 인라인 이름 편집 활성. |
| M6 | 닫힘 | 실제 복제 action으로 `same - 복사본.txt` 생성. 메인 메뉴의 복제 action에 Cmd+D가 연결됨 확인. 검색 결과의 부모별 복제 및 실패 시 이전 묶음 되돌림 코드도 검토했다. |
| M7 | 닫힘 | `children == []`인 트리 노드에서 생성→이름 변경→삭제 후 각각 `newFolder`→`renamedFolder`→빈 배열로 갱신. 외부 생성 후 F5에도 새 폴더 표시. `filesChanged` 알림과 `refreshTree` 실행 경로로 확인했다. |
| M8 | 닫힘 | 기존 누적 정렬 성능 재현은 해결. 10,000개를 200개씩 50회 입력: append 호출의 메인 점유 합계 **0.00343초**, 마지막 10,000개 표시까지 **1.80초**. 정렬은 detached, `setItems`는 활성 보기만 reload. 이전 7.51초는 호출 방식이 달라 배율 비교는 하지 않는다. 새 세대 전환 경쟁 상태는 R2로 별도 기록했다. |
| L1 | 닫힘 | `/`에서 `canGoUp == false`, 메뉴 비활성, `goUp` 직접 호출해도 루트 유지. 버튼도 같은 조건 사용. |
| L2 | 닫힘 | 실제 메뉴 구성 함수에 601개 입력 후 중첩된 “더 보기” 메뉴까지 URL 항목 601개 확인. 마지막 항목 action이 해당 URL로 이동 요청함도 확인. 메뉴는 구성 결과를 캡처해 검사했으며 화면에서 중첩 메뉴를 마우스로 펼친 검증은 아니다. |

### 새 발견

| ID | 심각도 | 파일:줄 | 재현된 문제 / 영향 | 수정 방향 |
|---|---|---|---|---|
| R1 | **High** | `Sources/Explorer/AppDelegate.swift:46`, `Sources/Explorer/AppState.swift:104`, `Sources/Explorer/BrowserActions.swift:120` | **마지막 창의 정상 닫기가 진행 중 파일 작업과 대기 큐를 조용히 끊는다.** 실제 `AppDelegate`로 실행하고 `performTransfer`로 2,000개 이동, 뒤에 파일 만들기를 예약했다. 첫 이동 관측 후 `window.performClose(nil)` 호출: 프로세스는 정상 종료했지만 최종 대상 **27개/원본 1,973개**, 예약한 파일 없음, 완료 콜백도 실행되지 않았다. 같은 현상은 `runOperation` 이동에서 마지막 창 닫기(27/1,973), 명시적 앱 종료(17/1,983)로도 재현. 종료 시 진행 중 작업을 기다리거나 롤백하는 정책이 없고 Undo 기록은 작업 전체 성공 뒤에만 생겨 배치가 분할된 채 되돌릴 기록도 잃는다. **2,000개 전체 내용은 보존됨을 확인했으며 파일 내용 소실을 주장하지 않는다.** 종료 정책 자체는 기존 코드이며, 새 직렬 큐와의 수명 연동이 빠진 것을 이번에 확인했다. | 큐의 실행·대기 상태를 추적하고 마지막 창 닫기/종료가 작업 완료를 기다리도록 연동한다. 종료를 허용하려면 작업을 안전하게 취소·롤백하거나 사용자에게 진행 상태와 중단 결과를 알린다. |
| R2 | Medium | `Sources/Explorer/BrowserViewController.swift:402`, `:414`, `:426`, `:442` | **이전 검색 정렬 중 새 검색이 끝나면 새 결과가 표시되지 않은 채 남는다.** 실제 배치 병합 함수에 이전 세대 100,000개를 넣어 detached 정렬 시작→새 검색 시작→새 세대 결과 1개와 검색 완료 전달. 새 세대 flush와 0.3초 타이머가 `searchSortRunning` 때문에 반환하고, 이전 정렬은 세대 불일치로 빠져나간다. 이전 정렬 완료 후 추가 0.6초 대기해도 **pending 1, 표시 0, sort idle**. 검색 결과를 다시 처리할 계기가 없다. `advanced-final.log`와 최초 `advanced.log`에서 동일. | 정렬 중 상태와 예약 타이머를 세대에 귀속시키고, 이전 세대 완료 시 현재 세대 대기 결과를 다시 flush하도록 한다. 이전 task가 새 세대의 실행 상태를 덮어쓰지 않도록 한다. |
| R3 | Medium | `Sources/Explorer/BrowserActions.swift:120`, `Sources/Explorer/ConflictDialog.swift:224`, `Sources/Explorer/BrowserWindowController.swift:41` | **대기 중 전송의 창을 닫으면 그 창이 충돌 질문과 함께 다시 열린다.** 다른 창의 공유 큐 작업이 먼저 실행 중일 때 두 번째 창에서 충돌 전송 예약→그 창에 시트가 없는 동안 `performClose(nil)`로 닫기. 닫힌 상태를 확인했지만 작업 차례가 오자 캡처한 창에 `beginSheetModal`이 호출되어 창이 다시 보였다(`closedBeforeStart=true`, 이후 `visible=true`, `sheetAttached=true`). 이미 `tearDown`한 컨트롤러에 다시 질문한다. 시트 응답 후 전송과 다음 큐 작업은 끝났다. | 질문 직전에 창 수명을 확인하고 닫힌 창의 사전 질문을 취소하거나 유효한 다른 창으로 연결한다. 닫힌 화면을 다시 표시할 때는 컨트롤러 수명도 일관되게 관리한다. |

### 큐·콜백·창 수명 추가 확인

- MainActor의 큐 대기는 `await previous.value`이며 메인 스레드 동기 대기를 재현하지 못했다. 미지 충돌 콜백을 MainActor에서 직접 부르면 `.keepBoth`로 즉시 반환했다.
- 실제 백그라운드 Core 복사에서 미지 충돌을 만들어 `ConflictResolver.policy`의 세마포어 대기→MainActor 시트 응답 경로 실행. 시트 동안 메인 heartbeat 10회 실행, 다음 공유 큐 작업은 대기, “둘 다 유지” 응답 뒤 복사와 다음 작업이 완료됐다.
- **일반 닫기와 강제 닫기를 구분했다.** 시트가 붙은 창의 `performClose(nil)`는 창을 닫지 않고 정상적으로 시트 응답을 기다렸다(`performclose.log`). 반면 `NSWindow.close()`를 직접 호출하면 보이지 않는 부모에 시트가 남고 백그라운드 콜백·다른 창 큐가 멈췄다. 숨은 시트를 하네스에서 `endSheet`하면 풀렸다. 일반 사용자 조작에서 이 강제 닫기로 들어가는 경로는 확인하지 못했으므로 이 관찰을 별도 Critical/High로 집계하지 않았다. R3의 정상 닫기 경로에서는 창이 다시 열렸으므로 “숨은 시트로 영구 대기”라고 판단하지 않았다.
- 경쟁 상태 검증은 위 순서를 실제로 실행해 판정했다. Thread Sanitizer, 실제 느린 네트워크 볼륨, 앱 강제 종료 시 전원 장애 수준의 내구성 검증은 하지 않았다.

### SPEC P0 체크리스트

3장 표에서 **24개 P0 전부 대조**했다. “실행”은 해당 항목의 아래 적은 동작을 하네스로 실행했다는 뜻이며, 모든 물리 키·외부 앱 연동까지 통과했다는 뜻은 아니다. 기능 자체가 통째로 빠진 항목은 발견하지 못했지만, F2에 R1, S1에 R2가 남아 **P0 전체 동작 통과 판정은 보류**한다.

| 확인 | P0 | 결과 / 남은 범위 |
|---|---|---|
| [x] | N1 뒤로/앞으로 | 실행: 폴더 이동 후 뒤로·앞으로 위치 복구. 탭별 history, 버튼·Backspace·Option 방향키·Cmd+[ ]·마우스 버튼 연결 코드 확인. 실제 다중 탭/물리 마우스 입력은 미검증. |
| [x] | N2 위로 | 실행: 루트 비활성 및 직접 호출 시 루트 유지. 버튼·메뉴·Option/Cmd+위 방향키 연결 확인. |
| [x] | N3 새로고침 | 실행: 외부 폴더 생성 후 F5 action으로 목록·트리 갱신. watcher/새로고침 버튼·Cmd+R 코드 확인. 물리 F5는 미검증. |
| [x] | N4 경로 버튼·하위 메뉴 | 코드 연결 확인 및 601개 메뉴 구성·마지막 action 실행. 화면 메뉴 tracking은 미검증. |
| [x] | N5 직접 경로 | 실행: 따옴표·역슬래시·`~`·`%USERPROFILE%` 해석. 주소 편집 진입·Enter·없는 경로 오류 시트 코드 확인. 물리 단축키 통합은 미검증. |
| [x] | N6 탐색 창 | 실행: 빈 캐시 노드의 폴더 트리 갱신. 홈/빠른 액세스/내 Mac/용량 막대/휴지통 구성 코드와 AppKit 뷰 캡처 확인. 외부 볼륨 연결/해제는 미검증. |
| [x] | V1 자세히 보기 | 실행: 이름·수정한 날짜·유형·크기 열 및 너비 조절 설정 확인. 검색용 폴더 열은 평소 숨김. 헤더 정렬 delegate 연결 코드 확인. |
| [x] | V2 폴더 우선·자연 정렬 | 실행: 모든 정렬 키의 오름/내림에서 폴더 먼저. 기본 이름 순서 `folder`, `file2.txt`, `file10.txt`. |
| [x] | V4 숨김 토글 | 실행: 숨김 off에서 `.hidden.txt` 제외, 토글 후 포함. 메뉴 및 Cmd+Shift+. 연결 확인. |
| [x] | V6 상태 표시줄 | 실행: `5개 항목`, `1개 항목 선택함 5 B` 확인. |
| [x] | V9 타이핑 이동 | 실행: 아이콘 typeSelect로 `file10.txt` 선택, 표의 type-select 문자열 확인. NSTableView 기본 키 처리 연결 확인. 실제 IME 타이핑은 미검증. |
| [x] | V10 시스템 아이콘 | `NSWorkspace` 캐시 코드 확인, AppKit 뷰 캡처에서 폴더·텍스트 파일 아이콘 표시 확인. 느린 볼륨의 동기 아이콘 호출 지연은 미측정. |
| [x] | F1 열기 | 실행: 선택 폴더 열기로 위치 이동. Enter·더블클릭·파일/패키지 기본 앱 열기 연결 코드 확인. 실제 외부 앱 실행은 미검증. |
| [!] | F2 잘라내기/복사/붙여넣기 | 실행: 전용 대지의 URL 복사·붙여넣기·잘라내기 이동과 M2 통과. **R1: 마지막 창 닫으면 이동 중단.** 실제 Finder 양방향 대지 교환은 미검증. |
| [x] | F3 이름 바꾸기 | 실행: `file2.txt`에서 확장자 제외 선택 범위 `{0,5}`, 입력 취소 시 원본 보존, 편집 확정 후 `renamed.txt` 생성. F2/Enter/Esc 연결 코드 확인. 실제 한국어 IME는 미검증. |
| [x] | F4 삭제 | 실행: 영구 삭제 확인 전 파일 존재·취소 시 보존, 휴지통 이동 후 Undo로 복구. Forward Delete·Shift+Delete·Cmd+Backspace·Ctrl+D 연결 코드 확인. 실제 물리 키는 미검증. |
| [x] | F5 새 폴더 | 실행: 검색 중 생성 후 검색 종료·바로 이름 편집. Cmd+Shift+N 연결 확인. |
| [x] | F6 새 파일 | 실행: 검색 중 텍스트 문서 생성 후 검색 종료·바로 이름 편집. 새로 만들기 메뉴 연결 확인. |
| [x] | F8 충돌 처리 | 실행: 원본별 건너뛰기/덮어쓰기, 둘 다 유지, 재귀 병합 충돌, 미지 충돌의 백그라운드 질문. 닫힌 대기 창 수명은 R3. |
| [x] | F9 같은 폴더 붙여넣기 | 실행: 실제 copy→paste로 `renamed - 복사본.txt` 생성. |
| [x] | F12 경로 복사 | 실행: 선택 파일의 POSIX 경로를 전용 대지 문자열로 확인. 우클릭·Cmd+Shift+C 연결 확인. |
| [!] | S1 재귀 검색 | 실행: 실제 디스크 하위 `nested.txt` 포함 결과·폴더 열, 10,000개 배치 표시. **R2: 이전 정렬 중 새 검색 완료 시 결과가 대기에 남음.** |
| [x] | S3 모두 선택·반전 | 실행: 표 selectAll로 3개 선택 후 반전하여 빈 선택. 메뉴 Cmd+A·선택 반전 연결 확인. |
| [~] | S4 다중 선택 | 표/collection의 native 다중 선택 설정 확인. Shift/Cmd 클릭·고무줄 드래그는 실제 마우스로 검증하지 못했으므로 실행 통과로 판정하지 않는다. |

- `smoke.png`는 AppKit `cacheDisplay`로 저장한 뷰 캡처다. 목록·탐색 창·아이콘 확인에만 사용했고, 네이티브 툴바/전체 화면 캡처나 실제 키보드 smoke를 대체하지 않는다.
- `swift test` 및 Core의 작업 중 수정본은 이번 UI 재검증 범위에 포함하지 않았다. 최종 Core 커밋과 합쳐진 앱, Finder/한국어 입력기/물리 마우스에 대한 통합 검증은 남아 있다.
- 최종 상태 확인 중 다른 에이전트의 Core 커밋 `0558c43`이 추가된 것을 확인했다. 이 재검증의 기준은 시작 시 고정한 `5603ff4`이며, `0558c43`과 합쳐진 앱의 재검증 결과로 해석하면 안 된다.

## 최종 재검증 (HEAD)

**결론: Critical 0건, High 0건. R1~R3와 기존 H1~H3·M1~M8은 최종 UI·Core 통합본에서 닫힘을 확인했다. 이번 검증 범위에서 SPEC DoD 4번을 통과한다.**

- 기준 커밋: `aa5c5fb5381c74189d2732743d5da4afa3238aa2` (2026-11-19). `git log --oneline -4`, `git show HEAD --stat` 확인 후 `git archive HEAD`를 `/tmp/explorer-final/head.tar`로 보관하고 `baseline/`에 추출했다. 작업 트리의 소스나 이전 Core 오브젝트를 섞지 않았다.
- 환경: macOS 26.4 arm64, Swift 6.2.4, macOS SDK 26.2, Debug. `swift build --package-path /tmp/explorer-final/baseline --scratch-path /tmp/explorer-final/build`는 **경고·오류 없이 성공**했다. 같은 사본의 `swift test`는 **145개 실행, 실패 0**이다.
- 기존 `/tmp/explorer-verify-ui/` 회귀 하네스와 Claude의 `scratchpad/h/main-term`, `main-r23`을 최종 HEAD UI로 다시 컴파일하고, 위 격리 빌드의 **최종 Core 오브젝트**를 링크했다. 대지는 `ExplorerFinal.private`, 설정은 전용 UserDefaults suite, 앱 지원·입력·산출물은 `/tmp/explorer-final/`을 사용했다. OS 휴지통 동작 시험은 테스트 파일에만 적용했다.
- 하네스의 접근 제한 완화·전용 경로·메뉴 캡처 및 검색 정렬 완료 관측용 변경은 `instrumentation.md`에 기록했다. 종료·작업 큐·충돌 처리 로직은 바꾸지 않았다. 원본 저장소에서는 이 절만 추가했으며 소스 수정·git commit은 하지 않았다. 시작 시 존재하던 미추적 `README.md`는 건드리지 않았다.

### 판정 표

| ID | 판정 | 최종 통합본 실행 결과 / 근거 |
|---|---|---|
| R1 | 닫힘 | `performTransfer`와 `runOperation` 각각에서 2,000개 이동 뒤 파일 만들기를 예약하고 **마지막 창 닫기 / 종료 후 대기 선택 / 종료 취소** 6가지를 실행. 전부 대상 2,000개·원본 0개·내용 일치·후속 파일 생성. 닫기/대기 선택은 두 완료 콜백 후 정상 종료했고, 취소는 완료 후에도 창과 프로세스가 살아 있었다. `term-*.log`, `termination-summary.json`. |
| R2 | 닫힘 | 이전 세대 100,000개 정렬 직후 새 검색 1개와 완료를 전달: 0.05초 후 표시 1개. **이전 정렬의 실제 완료까지 기다린 뒤에도** 표시 1·pending 0·정렬 idle. 새 검색 완료 대신 0.3초 타이머로 받는 경우도 표시 2·pending 0을 유지했다. 별도 정렬 완료 관측 로그로 이전 task 종료를 확인했다. `r23.log`. |
| R3 | 닫힘 | 대기 중 전송의 창을 정상 닫기: 닫힌 창은 계속 비표시·시트 없음, 다른 열린 창에 질문하고 응답 뒤 전송·후속 큐 완료. 모든 창을 닫은 경우에는 독립 모달 질문으로 처리하고 닫힌 창을 다시 열지 않았다. `r23.log`. |
| H1 | 닫힘 | 동명 원본 첫 항목 건너뛰기·둘째 덮어쓰기에서 첫 원본 내용 보존, 둘째만 이동. 질문별 원본 경로, 배치 중복 이름의 둘 다 유지, 재귀 폴더 병합의 건너뛰기/덮어쓰기/새 파일 이동 모두 통과. `regression.log`. |
| H2 | 닫힘 | 이름 변경 후 1,001개 이동의 연속 Undo 두 번으로 원래 이름 복구·중간 이름 없음·Undo 0/Redo 2. 연속 Redo 두 번으로 최종 이동과 Undo 2 복구. `regression.log`. |
| H3 | 닫힘 | 폴더 이동 직후 이전 선택이 동기적으로 비고 삭제 메뉴 비활성. `regression.log`. |
| M1 | 닫힘 | Undo 실패 시 기록 1개 유지, 방해 파일 제거 후 재시도 성공 및 Redo 생성. `regression.log`. |
| M2 | 닫힘 | 잘라내기 이동 완료 전에 새로 복사한 대지 URL이 이동 후에도 유지. `regression.log`. |
| M3 | 닫힘 | 인라인 편집 중 합성 F5 이벤트를 소비하지 않고 편집 유지. F3/F4/F5 공통 편집 차단 조건도 확인. `regression.log`. |
| M4 | 닫힘 | 자세히→큰 아이콘에서 선택 유지, 아이콘에서 선택 해제 후 자세히로 돌아와도 오래된 선택 없음. `regression.log`. |
| M5 | 닫힘 | 검색 중 새 텍스트 문서 및 새 폴더 생성 후 검색 종료·즉시 이름 편집. `regression.log`, `smoke.log`. |
| M6 | 닫힘 | 복제 action으로 `same - 복사본.txt` 생성, 메뉴 Cmd+D 연결 확인. `regression.log`. |
| M7 | 닫힘 | 빈 children 캐시에서 생성→이름 변경→삭제 결과가 `newFolder`→`renamedFolder`→빈 배열로 갱신. 외부 생성 뒤 F5에도 `external` 표시. `tree.log`. |
| M8 | 닫힘 | 10,000개를 200개씩 50회 append: 메인 호출 점유 합계 **0.00333초**, 10,000개 표시까지 **1.62초**. 전부 표시됨. 세대 전환 경쟁은 R2에서 별도 통과. `regression.log`. |
| L1·L2 | 닫힘 유지 | 루트 상위 이동 비활성·직접 호출 시 루트 유지. 메뉴 601개와 마지막 URL action 확인. `regression.log`, `tree.log`. |
| Core 성능 수정 | 통과 | 기본 2,000개: 복사 **0.959초**, 이동 **0.739초**, 이동 Undo **0.367초**. `EXPLORER_PERF_COUNT=10000 swift test … --filter FileOperationsPerformanceTests`도 **6개 실패 0**: 복사 **4.670초**, 이동 **3.742초**, Undo **1.895초**. 파일 수·내용·Undo/Redo, 하드링크/심볼릭 링크 결과 중복 제거·뒤늦게 대상이 생기는 링크·정규화 동명 원본 보존도 통과. `swift-test.log`, `performance-10000.log`. |

### 새 발견 표

| 심각도 | 건수 | 결과 |
|---|---|---|
| Critical | 0 | 이번 통합 실행에서 재현된 새 결함 없음. |
| High | 0 | 종료 중 작업 중단·파일 내용 손실·큐 고착을 추가로 재현하지 못함. |
| Medium·Low | 0 | 이번 추가 시나리오에서 새로 확정한 문제 없음. 기존 실기 미검증 범위를 해결된 것으로 간주하지 않음. |

### 종료 지연·재요청 및 통합 회귀 추가 확인

| 시나리오 | 관측 결과 |
|---|---|
| 종료 대기 선택 뒤 종료 요청 5회 추가 | 총 요청 6회, 경고 1회, `onIdle` 1회, 실제 `willTerminate` 1회. 이동과 후속 작업 완료 후 종료. `lifecycle-quit-repeat.log`. |
| 종료 취소 후 다시 종료 대기 선택 | 첫 취소는 창과 작업을 유지. 재요청에만 두 번째 경고, 이후 큐 완료·정상 종료. `lifecycle-cancel-retry.log`. |
| 마지막 창 닫기 후 작업 중 재열기 | reopen delegate 경로로 새 창 생성. 큐가 빈 뒤 0.6초가 지나도 새 창·프로세스 유지, 이후 명시적 종료는 정상 처리. `lifecycle-close-reopen.log`. |
| 마지막 창 닫힌 뒤 대기 작업의 충돌 발생 | 독립 모달 질문에 응답하면 기존/원본 내용 모두 보존·후속 파일 생성·pending 0·정상 종료. 닫힌 창 재표시 없음. `lifecycle-close-conflict.log`. |
| 종료 대기 선택 뒤 대기 작업의 충돌 발생 | 열린 창의 시트에 응답하면 내용 보존·후속 작업 완료·정상 종료. 종료 경고 재출현 없음. `lifecycle-quit-conflict.log`. |
| 실행 중 예상 밖 충돌의 백그라운드 콜백 | 시트 응답 전 메인 heartbeat 10회, 다음 큐 작업은 대기. 응답 후 콜백과 다음 작업 완료. 시트 도중 `performClose(nil)`는 창을 닫지 않고 응답을 기다림. `performclose.log`. |

- 추가 종료 시나리오 5개는 전부 프로세스 종료 코드 0, 자체 단언 실패 0이며 결과는 `lifecycle-summary.json`에 있다. 정상 응답 후 무한 종료 지연, 창 없는 상태의 영구 고착, 중복 실제 종료 알림은 관측되지 않았다. 모달 응답 대기는 의도된 사용자 결정 대기로 구분했다.
- 회귀 하네스는 실패 0. 보조 smoke에서 실제 디스크 재귀 검색·폴더 열기·뒤로/앞으로·이름 변경 확정/취소·같은 폴더 붙여넣기·전용 대지 경로 복사·삭제 취소·휴지통 Undo도 확인했다. `smoke.png`는 기존 방식의 AppKit 뷰 캡처이며 실제 화면/물리 키 검증으로 취급하지 않았다.
- 모든 로그의 기준 디렉터리는 `/tmp/explorer-final/logs/`다. `check-evidence.py`로 판정에 사용한 상태·완료 로그·내용 검증·테스트 성공을 다시 대조했다. 재현 입력·하네스·실행 스크립트도 `/tmp/explorer-final/`에 보관했다.
- **최종 결론: R1의 High를 포함한 재검증 지적은 닫혔고 새 Critical/High가 없어 DoD 4번 통과.** 실제 한국어 IME·물리 마우스·Finder 양방향 대지·외부 앱 드래그·서로 다른 실물/네트워크 볼륨과 강제 종료 내구성은 이번 하네스 검증에 포함하지 않았다. DoD 2·3·5 전체의 실기 통과를 추가로 선언하는 결과는 아니다.

## 리디자인 회귀 리뷰 (5bd4191)

**결론: Critical 0건, High 1건, Medium 2건, Low 1건. 기존 H1~H3·M1~M8 및 R1·R2는 회귀하지 않았으나, 충돌 시트가 열린 창을 병합하면 시트가 숨겨진 채 앱 공유 파일 작업 큐가 고착되는 새 High를 재현했다. 이 커밋은 SPEC DoD 4번을 통과하지 못한다.**

- 기준: `5bd41916b8c535ed5bc67ab068a1c58c64ef32a6`. `git archive 5bd4191`을 `/tmp/explorer-redesign-review/head.tar`에 보관하고 `baseline/`에 추출했다. 검토 중 다른 작업의 `AppDelegate.swift`, `DebugSnapshot.swift` 수정이 나타났으나 읽기 전용 기준본과 빌드에는 섞지 않았고 건드리지 않았다. 아래 줄 번호는 모두 이 커밋 기준이다.
- macOS 26.4 arm64, Swift 6.2.4, SDK 26.2. 격리 Debug·Release 빌드 모두 성공. 같은 사본의 `swift test`는 **145개 실행, 실패 0**. 원본 저장소에는 이 절만 추가했으며 소스 수정·git commit은 하지 않았다.
- 기존 `/tmp/explorer-final/`, `/tmp/explorer-verify-ui/` 하네스를 현재 UI 및 동일 기준본 Core 오브젝트로 다시 컴파일했다. 이전 `controller.browser`/직접 content controller 조회만 `tabs.selectedBrowser`/`window.activeBrowser`로 바꿨다. 시험 진입점·접근 제한 완화·검색 정렬 완료 관측·메뉴 캡처는 격리 사본에만 적용했다. 대지·설정 suite·창/분할 autosave·앱 지원·시험 입력과 결과는 전용 이름 또는 `/tmp/explorer-redesign-review/` 아래다. 상세: `instrumentation.md`, `prepare.py`, `build-harness.sh`.
- 로그 경로는 아래에서 모두 `/tmp/explorer-redesign-review/logs/` 기준이다. `check-evidence.py`로 회귀 상태, 파일 수·내용, 큐 완료, 새 High의 반복 재현을 대조했다. 하네스 종료 코드 0만을 결함 없음으로 해석하지 않았다.

### 회귀 판정 표

| ID / 범위 | 판정 | 실행 결과 / 근거 |
|---|---|---|
| R1 | 기존 보호 유지 | `performTransfer`·`runOperation` 각각 마지막 창 닫기/종료 후 대기/종료 취소 6개 모두 원본 0·대상 2,000개·내용 일치·후속 파일 생성. **자체 탭의 마지막 탭 닫기**도 두 진입점에서 같은 결과 후 정상 종료. `term-*.log`, `lasttab-*.log`, `termination-summary.json`, `lasttab-summary.json`. 아래 RD-H1에서는 질문이 고립되어 idle에 도달하지 못하므로 별도 실패다. |
| R1 추가 수명 | 통과 | 종료 6회 요청에도 경고·idle·실제 종료 각 1회. 취소 후 재요청, 마지막 창 닫고 재열기, 창 없는 상태/종료 대기 중 충돌 응답도 완료. `lifecycle-*.log`, `lifecycle-summary.json` 5개 모두 자체 단언 실패 0. |
| R2 | 닫힘 유지 | 100,000개 이전 정렬 중 새 검색 완료 및 타이머 수신 모두 정상 표시. 이전 정렬의 **실제 완료** 후에도 새 결과 1개/2개·pending 0. `r23.log`. |
| R3 | 기존 경로 통과 / 병합 확장 실패 | 닫힌 창에 시트나 창을 다시 띄우지 않고 다른 열린 창/독립 모달로 응답 후 큐 완료. 대기 전송의 탭을 닫아도 생존 창에 질문하며 닫은 탭 뷰는 재부착하지 않음. **이미 시트가 붙은 창의 병합은 RD-H1로 실패.** `r23.log`, `tabs.log`, `merge-sheet-final1.log`, `merge-sheet-final2.log`. |
| H1 | 닫힘 유지 | 동명 원본 첫 항목 건너뛰기·둘째 덮어쓰기에서 첫 원본 내용 보존. 배치 동명 항목 둘 다 유지·폴더 재귀 병합의 원본별 결정도 통과. `regression.log`. |
| H2 | 닫힘 유지 | 이름 변경+1,001개 이동 후 연속 Undo 두 번: 원래 이름 복구·중간 이름 없음·Undo 0/Redo 2. Redo 두 번도 최종 이동·Undo 2. `regression.log`. |
| H3 | 닫힘 유지 | 위치 변경 직후 이전 선택 동기 제거·삭제 메뉴 비활성. `regression.log`. |
| M1 | 닫힘 유지 | Undo 실패 시 기록 유지, 장애 파일 제거 후 재시도 성공·Redo 생성. `regression.log`. |
| M2 | 닫힘 유지 | 잘라내기 이동 중 새로 복사한 대지 URL이 이동 완료 후에도 남음. `regression.log`. |
| M3 | 닫힘 유지 | 인라인 편집 중 합성 F5를 소비하지 않고 편집 유지. `regression.log`. |
| M4 | 닫힘 유지 | 자세히→큰 아이콘 선택 유지, 아이콘에서 선택 해제 후 자세히로 돌아와도 빈 선택. `regression.log`. |
| M5 | 닫힘 유지 | 검색 중 새 파일·새 폴더 생성 시 검색 종료·즉시 이름 편집. `regression.log`, `smoke.log`. |
| M6 | 닫힘 유지 | 실제 복제 파일 생성·Cmd+D 메뉴 연결 확인. `regression.log`. |
| M7 | 닫힘 유지 | 빈 트리 캐시에서 생성→이름 변경→삭제가 각각 반영됨. 외부 생성 뒤 F5에도 `external` 표시. `tree.log`. |
| M8 | 닫힘 유지 | 10,000개를 200개씩 50회 append: 호출의 메인 점유 합계 **0.00343초**, 최종 10,000개 표시까지 **1.58초**. `regression.log`. |
| L1·L2 | 닫힘 유지 | 루트 상위 이동 차단, 하위 폴더 메뉴 601개·마지막 항목 이동 확인. `regression.log`, `tree.log`. |
| 활성 탭·키·메뉴 | 통과 / 입력 복원은 RD-L1 | 실제 키 창·`NSApp.target(forAction:)`·메뉴 키 상당 처리로 Cmd+T는 탭 1개 추가, Cmd+W는 탭 1개만 제거하고 창 유지. Ctrl+Tab/Shift+Ctrl+Tab 및 F3 포커스·삭제 메뉴 검증·전환 후 명령 대상 모두 활성 탭. `tabs.log` 단언 실패 0. 물리 키 입력/IME 시험은 아님. |
| 탭 수명·기록 | 부분 통과 | 탭별 뒤로/앞으로 기록 독립. 닫자마자 search/watcher nil·이전 검색 배치 무시. 닫은 idle·검색·대기 작업 탭은 강한 소유 참조 제거와 작업 완료 후 weak 참조 nil 확인. **작업 완료의 UI 재시작은 RD-M1.** `tabs.log`. 영구 컨트롤러 누수로 분류하지 않았다. |
| 탭 새 창·창 병합 | 기본 상태 통과 / 시트는 RD-H1 | 메뉴 응답자 체인을 통한 새 창 이동·재병합에서 같은 컨트롤러·부모·URL·기록·아이콘 보기·미리 보기 상태 유지. 병합된 탭 재선택 후 메뉴도 해당 탭 대상. `tabs.log`. |
| 신호등 버튼·전체 화면 | 현재 환경 통과 | 640/1,500/900 크기 요청에서 닫기 버튼 중심이 콘텐츠 상단 23pt이고 hit-test도 실제 버튼. 전체 화면 진입/복귀 **2회**, inset 8→84 복원 및 복귀 후 두 크기에서 동일 정렬·hit-test 통과. `tabs.log`, `fullscreen.log`. 내부 `superview.superview` 및 프레임 직접 변경은 다른 AppKit 계층/OS에서의 호환성을 보장하지 않지만, 이번 환경에서 재현된 High는 없음. |
| 라이트/다크 CGColor | 통과 | 기존 뷰를 재생성하지 않고 Aqua→Dark Aqua→Aqua 전환. 주소·검색 상자, 두 Mica tint, 선택 아이콘 셀의 레이어 색이 변경되고 최초 값으로 돌아옴. 예: 주소/검색 배경 1.0→0.12157, 선택색 `#CCE4F7`→`#0F3A5A`. `tabs.log`. |

### 새 발견 표

| ID / 심각도 | 파일:줄 | 문제 | 재현 / 근거 | 제안 |
|---|---|---|---|---|
| RD-H1 / **High** | `Sources/Explorer/BrowserWindowController.swift:325`, `:333`, `:343`; `Sources/Explorer/ConflictDialog.swift:237` | **충돌 질문 중인 창을 병합하면 숨겨진 시트가 응답을 기다려 모든 창의 파일 작업 큐가 막힌다.** 병합은 시트가 붙은 다른 창도 대상으로 삼고, 탭을 옮긴 뒤 `other.close()`로 부모 창을 강제 닫는다. 기존 `beginSheetModal`의 continuation은 끝나지 않는다. | **반복 2회 재현.** 창 A에서 기존 대상과 충돌하는 이동을 시작해 시트가 보이는 것을 확인. 창 B를 실제 키 창으로 만들고 ‘모든 창 병합’ 메뉴가 활성이고 action target이 B의 탭 컨트롤러임을 확인한 뒤 `NSApp.sendAction` 실행. A는 비표시·isClosed, 시트도 비표시지만 A.attachedSheet는 남고 B에는 시트 없음. 옮긴 탭은 B 소속·isClosed false. **4초 동안 보이는 시트 host 0·전송 미완료·후속 파일 미생성·pending 2**. 원본/기존 대상 내용은 보존되어 데이터 소실로 분류하지 않음. 하네스가 숨겨진 A의 시트를 `endSheet`로 응답시켜야 전송·후속 작업 완료·pending 0. `merge-sheet-final1.log`, `merge-sheet-final2.log`, `main-merge-sheet.swift`. | 시트가 붙은 원본 창은 병합 대상에서 제외하거나 응답 종료까지 병합을 미룬다. 메뉴 검증도 실제 병합 가능한 창을 기준으로 한다. 질문을 이동하려면 기존 continuation을 안전하게 종료하고 생존 창에 다시 연결해야 하며, 기다리는 시트를 숨긴 채 창을 닫으면 안 된다. |
| RD-M1 / Medium | `Sources/Explorer/BrowserViewController.swift:196`, `:291`, `:304`, `:384`; `Sources/Explorer/BrowserActions.swift:397`, `:402` | 닫은 탭의 대기 작업 완료가 `reload`를 실행하여, tearDown에서 중지한 **감시자 또는 재귀 검색을 다시 시작**한다. `isClosed`가 UI 재시작을 막지 않는다. | 큐 앞에 지연 작업을 두고 탭에서 충돌 전송/파일 생성을 예약한 뒤 그 탭을 닫음. 닫은 직후 watcher nil이지만 전송 완료 후 `isClosed == true`, `view.window == nil`인 컨트롤러에 **watcher가 다시 존재**. 검색 중 닫은 탭은 완료 후 새 세대 4의 `SORT_COMPLETED`가 발생해 검색 재실행도 확인. `tabs.log`, `main-tabs.swift`. 시험용 소유 참조를 없앤 일반 대기 탭의 weak 참조는 nil이므로 영구 누수 주장과 구분함. | 파일 작업·Undo 기록·공유 변경 알림은 끝까지 처리하되, 닫은 탭에 대한 목록 갱신/이름 편집/검색/감시 시작을 차단한다. `reload`·`loadCurrent`·`startSearch`에도 닫힘 guard를 둔다. |
| RD-M2 / Medium | `Sources/Explorer/TabStrip.swift:52`, `:58`, `:72` | 탭 최소 폭 72pt를 유지하면서 스크롤·오버플로 처리가 없어, 탭이 많아지면 활성 탭과 + 버튼이 창 밖으로 밀린다. | 최소 크기를 요청한 실제 탭 줄 폭 **667pt**에서 12개 생성. 선택 index 11의 탭 프레임은 **x=876, 폭 72**, bounds와 교차하지 않음. scroll view 없음. + 시작점도 코드의 동일 배치식상 x=952로 창 밖이다. Cmd+T/Ctrl+Tab으로 선택은 바뀌지만 해당 탭을 보고 클릭할 수 없다. `overflow.log`, `main-overflow.swift`. | 탭 줄을 수평 스크롤하고 활성 탭을 자동 노출하거나 오버플로 메뉴를 제공한다. + 버튼은 별도 고정 영역으로 확보한다. |
| RD-L1 / Low | `Sources/Explorer/BrowserWindowController.swift:249`, `:259`, `:265`; `Sources/Explorer/AddressBar.swift:199`, `:213` | 주소 편집 중 탭을 바꾸고 돌아오면 입력 포커스와 미완성 경로가 복원되지 않는다. 저장한 responder는 창이 공유하는 field editor이며, 뷰 제거로 주소 편집이 종료된다. | 주소에 `/tmp/unfinished-path` 입력 후 다른 탭→원래 탭. `isEditing` true→false, firstResponder는 파일 표이며 `savedFirstResponder`만 NSTextView로 남음. 주소 입력을 다시 열면 미완성 입력 대신 현재 폴더 경로로 덮어씀. `overflow.log`. 명령이 비활성 탭에 전달되는 문제로는 분류하지 않았다. | 공유 field editor 대신 논리적인 포커스 대상과 주소 편집 문자열/선택 범위를 탭별로 저장하고, 복귀 때 해당 입력 컨트롤에서 편집을 재개한다. |

### 재현 신뢰도와 남은 범위

- RD-H1은 기본 탭 이동·병합 통과와 별개이며, **시트가 이미 열린 뒤 병합**하는 순서에서 발생한다. 처음에는 시험 앱 비활성으로 메뉴 action target이 nil이었던 `merge-sheet.log`가 있었고 이 실행은 판정에서 제외했다. 활성화 후 action target까지 확인한 `merge-sheet-active.log`에서 최초 재현했으며, 최종 두 로그에서 반복 확인했다. 큐·충돌·창 병합 로직은 하네스에서 변경하지 않았다.
- 보조 `smoke.log`에서 실제 디스크 검색, 폴더 열기·뒤로/앞으로, 숨김·정렬·보기 선택, 이름 변경 확정/취소, 같은 폴더 붙여넣기, 경로 복사, 영구 삭제 취소, 휴지통 Undo를 확인했다. 시트 중 native `performClose`는 창을 닫지 않고 응답 후 큐를 진행했다(`performclose.log`). 이 정상 보호를 병합의 직접 `close()`가 우회한다.
- 실제 한국어 IME·물리 마우스/키 입력·Finder 양방향 대지·외부 앱 드래그·서로 다른 실물/네트워크 볼륨, 다른 macOS/AppKit 버전은 검증하지 않았다. 화면 캡처를 통한 전체 비주얼 품질 평가도 이번 코드/실행 회귀 판정의 근거가 아니다. 원본 소스 수정은 하지 않았으며 RD-H1~RD-L1은 미수정 상태다.
