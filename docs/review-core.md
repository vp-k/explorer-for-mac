# ExplorerCore 코드 리뷰 (Claude)

**결론: 재현된 High 3건이 있어 DoD 4번을 아직 통과하지 못합니다.**
High 3건은 모두 실제 재현했습니다. 두 건은 ZIP 구조이고, 한 건은 폴더 덮어쓰기 데이터 손실입니다.

- 대상: `Sources/ExplorerCore/**`, `Tests/ExplorerCoreTests/**` (커밋 c78fb66)
- 명세: `docs/SPEC.md`, 각 public API 문서 주석
- 재현 위치: `/tmp/explorer-review-core/` (별도 SwiftPM 패키지, ExplorerCore 를 경로 의존으로 사용)
- 재현 실행: `cd /tmp/explorer-review-core && swift test`

## 요약 숫자

| 항목 | 값 |
|---|---|
| Critical | 0 |
| High | 3 (모두 재현) |
| Medium | 6 (5건 재현, 1건 코드 확인) |
| Low | 7 |
| 재현 테스트 | 17개 실행, 의도한 실패 5개 |
| 재현했으나 문제 없음 | 6건 (아래 "확인했으나 문제 아님") |

## 발견 표

| ID | 심각도 | 파일:줄 | 문제 | 재현 방법 | 재현 | 수정 제안 |
|---|---|---|---|---|---|---|
| H1 | High | FileOperations.swift:155-157 | 파일 하나를 압축하면 상위 폴더째 들어간다. `s/a.txt` 를 압축하면 zip 안이 `s/a.txt` 다. 명세의 "단일 항목은 최상위에 그 항목" 위반 | testR2MultiZipStructure 의 single 출력. `ditto -c -k --keepParent s/한글.txt out.zip` → `s/한글.txt` | 예 | 파일이면 `--keepParent` 를 빼고 ditto 실행. 폴더는 현행 유지. 검증: `ditto -c -k f.txt o.zip` → `f.txt` 최상위 |
| H2 | High | FileOperations.swift:159-167 | 여러 항목 압축 시 전부 `압축/` 폴더 안에 들어간다. Windows 는 선택 항목을 zip 최상위에 둔다 | testR2MultiZipStructure. 엔트리 `압축/a.txt`, `압축/b.txt` | 예 | 스테이징 폴더를 `--keepParent` 없이 압축. 검증: `ditto -c -k m multi.zip` → `a.txt`, `t/b.txt` |
| H3 | High | FileOperations.swift:352-360, 387 | 폴더 충돌에서 "덮어쓰기" 를 고르면 대상 폴더 전체가 지워진다. 대상에만 있던 파일이 휴지통도 거치지 않고 영구 삭제된다. Windows 는 폴더를 병합하고 같은 이름 파일만 덮어쓴다 | testR6FolderReplaceNoMerge. `d/F/keep.txt` 가 있을 때 `s/F` 를 replace 로 복사 → `d/F` 에 `new.txt` 만 남음 | 예 | 폴더↔폴더 충돌은 재귀 병합으로 처리. 파일 단위 충돌만 정책 적용. 최소한 백업을 영구 삭제하지 말고 휴지통으로 보낼 것 |
| M1 | Medium | FileOperations.swift:346-374, 200-215 | 한 배치에 같은 이름 원본이 둘이면 둘째가 첫째의 결과를 대상으로 충돌한다. replace 를 고르면 첫째 원본이 영구 삭제된다. 기록에는 같은 `to` 가 두 번 들어가 실행 취소가 실패한다 | testR5DuplicateNameMoveUndo, testR5bDuplicateNameCopyUndo. 검색 결과에서 `a/x.txt`, `b/x.txt` 를 함께 이동 | 예 | 배치 안에서 이미 쓴 대상 이름을 추적. 같은 배치 충돌은 keepBoth 로 처리하거나 사전 검사에서 거부 |
| M2 | Medium | FileOperations.swift:387 | 덮어쓰기로 밀려난 기존 항목을 영구 삭제한다. 그래서 실행 취소 후 대상 폴더에 아무 것도 남지 않는다 | testR14UndoReplaceCopy. `d/x.txt(old)` 를 replace 복사 후 undo → `d` 가 빈 폴더 | 예 | 백업을 `trashItem` 으로 보내고 기록에 남긴다. undo 시 복구 |
| M3 | Medium | FileOperations.swift:296-298, 342-351 | 패키지를 같은 폴더에 복사하면 `Foo.app - 복사본` 이 된다. keepBoth 는 `Foo.app (2)` 가 된다. 확장자가 깨져 앱·문서 번들로 인식되지 않는다 | testR3PackageCopyName | 예 | 패키지 판별 후 확장자를 분리. 결과는 `Foo - 복사본.app`, `Foo (2).app` |
| M4 | Medium | Support.swift:264-273 | 디렉터리 fd 감시라서 폴더 안 파일 내용 변경은 감지하지 못한다. 크기·수정 날짜 열이 오래된 값으로 남는다. 명세 N3 "폴더 변경 자동 감지" 와 부분 불일치 | testR4WatcherContentChange. 기존 파일에 5000바이트 추가 → 1.5초간 이벤트 없음 | 예 | FSEvents 스트림을 파일 단위 플래그로 사용. 또는 문서 주석에 한계를 명시하고 UI 가 F5 에 의존 |
| M5 | Medium | FileOperations.swift:155 | `--sequesterRsrc` 때문에 확장 속성이 있으면 `__MACOSX/` 가 들어간다. 최근 macOS 는 거의 모든 파일에 provenance 속성이 있다. Windows 사용자에게 쓰레기 폴더가 보인다 | 재현 zip 에 `__MACOSX/s/._a.txt` 존재 | 예 | `--norsrc --noextattr --noacl` 사용. 검증 결과 `__MACOSX` 없음 |
| M6 | Medium | FileOperations.swift:242-258 | ditto 가 쓴 zip 엔트리에 UTF-8 플래그가 없다. 한글 이름이 Windows 기본 압축 해제기에서 깨질 수 있다 | python zipfile 로 확인. `flag_bits & 0x800` 이 모든 엔트리에서 0 | 플래그 부재만 재현. Windows 표시는 미확인 | Windows 에서 실제 확인 필요. 깨지면 플래그를 세우는 다른 압축 경로 검토 |
| L1 | Low | FileOperations.swift:352-356 | 원본을 품은 대상 폴더를 replace 하면 원본이 백업으로 함께 이동해 실패한다. 롤백은 되지만 오류 문구가 원인을 설명하지 못한다 | testR7ReplaceAncestor. `D/x/x` 를 `D` 로 replace 이동 | 예 (데이터 손실 없음) | 사전 검사에서 "대상이 원본을 포함" 오류로 거부 |
| L2 | Low | Support.swift:124-140 | 속성 창에서 폴더 심볼릭 링크를 고르면 링크 자체 크기만 센다 | testR10SymlinkFolderStats. 1000바이트 파일이 든 폴더의 링크 → 93바이트 | 예 | 루트 항목만 링크를 따라가도록 처리 |
| L3 | Low | FileOperations.swift:98-101 | 영구 삭제 중간 실패 시 일부만 지워진 상태로 끝난다. 결과에 무엇이 지워졌는지 없다 | 코드 확인 | 아니오 | 지운 항목 목록을 오류와 함께 돌려준다 |
| L4 | Low | FileOperations.swift:150 | 여러 항목 압축 파일명이 고정 `압축.zip` 이다. Windows 는 우클릭한 항목 이름을 쓴다 | 코드 확인 | 아니오 | 첫 항목 또는 포커스 항목 이름 사용 |
| L5 | Low | FileOperations.swift:160-166 | 여러 항목 압축 시 선택 전체를 임시 폴더로 복사한다. 외장 볼륨이면 디스크와 시간이 두 배 든다 | 코드 확인 | 아니오 | 원본 부모에 하드링크·클론으로 스테이징하거나 `zip -r` 로 목록 직접 전달 |
| L6 | Low | FileOperations.swift:181-186 | 압축 풀기가 시스템 임시 폴더를 거친다. 대상이 다른 볼륨이면 이동이 복사가 된다 | 코드 확인 | 아니오 | 대상 폴더 안의 숨김 임시 폴더에 풀고 이름 변경 |
| L7 | Low | Support.swift:264-273 | 감시 중인 폴더가 이름 변경·삭제되면 옛 fd 를 계속 감시한다. 재감시는 UI 책임인데 문서 주석에 없다 | 코드 확인 | 아니오 | `.delete/.rename` 이벤트를 별도 콜백으로 알림 |

## 확인했으나 문제 아님

| 의심 | 결과 | 재현 테스트 |
|---|---|---|
| 끊어진 심볼릭 링크가 폴더 목록 전체를 실패시킴 | 정상 표시 | testR1DanglingSymlinkListing |
| 심볼릭 링크 순환 | 정상 표시 | testR1bSymlinkLoop |
| NFD 한글 파일명을 NFC 검색어로 검색 | 부분 일치·와일드카드 모두 찾음 | testR8NFDSearch |
| NFD↔NFC 이름 바꾸기, 고정 폴더 중복 | 변경 없음 처리, 중복 없음 | testR9NFCRename |
| PinnedFolderStore 동시 pin/unpin | 메모리와 디스크 일치 | testR11PinConcurrency |
| DirectoryWatcher stop 뒤 콜백, 기본 감지 | stop 뒤 콜백 없음, 생성 감지됨 | testR12WatcherStopNoCallback, testR12bWatcherFires |

FileSearch 는 잠금으로 취소·중복 실행을 막습니다. 배치 전달 전 취소도 확인합니다. 스레드 안전 문제는 찾지 못했습니다.
DirectoryWatcher 는 약한 참조와 세대 번호로 늦은 콜백을 막습니다. fd 는 취소 핸들러에서 닫힙니다. 누수는 찾지 못했습니다.

## 테스트 누락

| 항목 | 내용 |
|---|---|
| 잘못된 동작을 고정한 테스트 | 단일 파일 압축 테스트가 `source/` 래핑을 기대함 (H1). 여러 항목 테스트가 `압축/` 래핑을 기대함 (H2). 폴더 replace 테스트가 전체 교체를 기대함 (H3) |
| zip 엔트리 구조 | 풀기 왕복만 검사. 엔트리 목록과 `__MACOSX` 부재를 직접 검사하지 않음 |
| DirectoryWatcher | 테스트 0개 |
| 유니코드 정규화 | NFD 파일명 테스트 없음 |
| 패키지 복사 이름 | `.app` 같은 번들 복사 테스트 없음 |
| 같은 이름 다중 원본 | 배치 내 이름 충돌과 그 실행 취소 테스트 없음 |
| replace 후 실행 취소 | 밀려난 원본 복구 여부 테스트 없음 |

## 남은 것

- H1~H3 수정이 필요합니다. 수정 시 위 표의 "잘못된 동작을 고정한 테스트" 3개도 함께 바꿔야 합니다.
- H3 의 병합 방식은 사용자 결정이 필요합니다. 선택지는 Windows 식 병합, 또는 교체 유지 후 휴지통 백업입니다.
- M6 은 Windows 실기 확인이 필요합니다.

## 재검증 (2f584bf)

**결론: 이전 High 3건은 모두 닫혔고, 새 Critical·High 는 없습니다.**
이전 지적 16건 중 15건이 닫혔습니다. M6 은 한계를 문서로 밝힌 부분 해결입니다.
새로 Medium 3건과 Low 4건을 찾았습니다. 데이터가 영구 손실되는 경로는 재현되지 않았습니다.

- 재현 위치: `/tmp/explorer-verify-core/` 의 `Repro.swift`, `Verify.swift`
- 재현 실행: `cd /tmp/explorer-verify-core && swift test`
- 보조 볼륨: 대소문자 구분 APFS 이미지, FAT 이미지. 실험 뒤 분리함

### 숫자

| 항목 | 값 |
|---|---|
| 프로젝트 `swift test` | 124개 실행, 실패 0 |
| 재현 패키지 테스트 | 38개 실행, 실패 5 |
| 실패 5개의 의미 | R4 는 결함이 고쳐져 반전 기대가 깨진 것 |
| 실패 중 zip 단언 | 한글 이름이 zipinfo 에서 깨져 보임. 구조는 정상이며 M6 증상 |
| 실패 중 새 결함 | testN7 은 V-M2, testN8 은 V-M1 |
| 이전 지적 판정 | 닫힘 15, 부분 1, 열림 0 |
| 새 발견 | Critical 0, High 0, Medium 3, Low 4 |

### 이전 지적 판정

| ID | 판정 | 확인 방법 | 결과 |
|---|---|---|---|
| H1 | 닫힘 | testV_H1H2M5L4_zip | 단일 파일 zip 엔트리가 파일 하나뿐 |
| H2 | 닫힘 | testV_H1H2M5L4_zip, testR2 | 여러 항목이 zip 최상위에 놓임 |
| H3 | 닫힘 | testV_H3_merge, testR6 | 폴더 충돌이 병합됨. `keep.txt` 유지 |
| M1 | 닫힘 | testV_M1_duplicateNames, testR5, testR5b | 둘째 원본이 `x (2).txt`. 실행 취소로 두 원본 복구 |
| M2 | 닫힘 | testV_M2_undoReplace, testR14 | 실행 취소 후 `old` 내용 복구 |
| M3 | 닫힘 | testV_M3_package, testR3 | `Foo - 복사본.app`, `Foo (2).app` |
| M4 | 닫힘 | testV_M4_contentChange, testR4 | 파일 내용 변경에 이벤트 발생. R4 의 반전 기대가 깨짐 |
| M5 | 닫힘 | testV_H1H2M5L4_zip | 모든 zip 에 `__MACOSX` 없음 |
| M6 | 부분 | python zipfile 로 플래그 확인 | 플래그는 여전히 없음. 한계를 문서 주석에 명시함 |
| L1 | 닫힘 | testV_L1_ancestor, testR7 | 원본을 품은 대상 오류로 사전 거부. 원본 그대로 |
| L2 | 닫힘 | testV_L2_symlinkStats | 링크 폴더 합계 1000바이트 |
| L3 | 닫힘 | 코드 확인, 프로젝트 테스트 | 일부 삭제 시 삭제 목록을 오류에 담음 |
| L4 | 닫힘 | testV_H1H2M5L4_zip | zip 이름이 첫 항목 이름. 겹치면 번호 붙음 |
| L5 | 닫힘 | 코드 확인, 프로젝트 테스트 | 클론 복사로 스테이징 |
| L6 | 닫힘 | 코드 확인 | 대상 폴더 안 숨김 임시 폴더에 풀고 이동 |
| L7 | 닫힘 | testV_L7_rootRename | 감시 폴더 이름 변경 시 콜백 발생. 재감시 책임도 문서화됨 |

### 데이터 손실 집중 점검

| 시나리오 | 결과 | 재현 테스트 |
|---|---|---|
| 병합 복사 중 읽기 실패 | 대상 트리 원상 복구. 밀려난 파일도 복구 | testN1_mergeCopyFailureRollback |
| 병합 이동 중 잠긴 파일 실패 | 원본·대상 트리 모두 원상 복구 | testN2_mergeMoveFailureRollback |
| 병합 + 덮어쓰기·건너뛰기·둘 다 유지 혼합 후 undo/redo 5회 | 복사·이동 모두 매 단계 트리 일치 | testN3_undoRedoCycles |
| 대소문자 무시 볼륨에서 `Foo/A.TXT` 를 `foo/a.txt` 로 병합 | 한 번만 묻고 병합. undo/redo 3회 일치 | testN4_caseInsensitiveCollision |
| 대소문자 구분 볼륨의 `a.txt`·`A.txt` 를 통째 복사 | 오류로 중단. 대상에 잔여물 없음 | testN4b_caseSensitiveSourceIntoInsensitive |
| 패키지끼리 덮어쓰기 | 병합하지 않고 통째 교체. undo/redo 복구 | testN5_packageConflict |
| FAT 볼륨에서 덮어쓰기·병합 이동 | 볼륨 휴지통으로 백업. 정상 동작 | testN11_fatVolume |

### 새 발견

| ID | 심각도 | 파일:줄 | 문제 | 재현 | 제안 |
|---|---|---|---|---|---|
| V-M1 | Medium | Support.swift:279 | 심볼릭 링크 경로로 감시하면 감시가 조용히 꺼진다. 링크 URL 의 폴더 여부가 거짓으로 나오기 때문이다. UI 는 링크를 풀지 않은 경로를 넘긴다. `/tmp` 나 링크 폴더를 열면 자동 새로 고침이 없다. 이전 fd 방식은 링크를 따라갔으므로 회귀다 | testN8_watchSymlinkPath. 2초간 이벤트 없음 | 검사 전에 `resolvingSymlinksInPath()` 적용 |
| V-M2 | Medium | Support.swift:294-302 | FSEvents 는 하위 트리 전체를 감시한다. 4단계 아래 파일 생성에도 콜백이 온다. UI 는 콜백마다 아이콘 캐시를 비우고 다시 읽는다. 홈 폴더를 열어 두면 Library 변화로 0.3초마다 새로 고침될 수 있다 | testN7_deepSubtreeEvents. 반전 기대가 깨짐 | 콜백의 경로 목록을 받아 감시 폴더와 직속 자식 이벤트만 통과시킴 |
| V-M3 | Medium | FileOperations.swift:388, 439-441 | 선택에 대상 폴더의 같은 이름 항목이 함께 있으면 덮어쓰기가 그 원본을 먼저 휴지통에 보낸다. 이어서 같은 경로의 다른 내용을 복사본으로 만든다. 결과 폴더에 원래 내용이 없다. 휴지통과 실행 취소로는 복구된다 | testN6_selectionContainsTargetItem. `a/x.txt(A)`, `d/x.txt(D)` 를 `d` 로 복사. 결과 `x.txt=A`, `x - 복사본.txt=A` | 덮어쓸 대상이 배치 원본이면 사전 검사에서 거부하거나 keepBoth 로 처리 |
| V-L1 | Low | FileOperations.swift:450 | 병합 시 숨김 `.DS_Store` 충돌도 사용자에게 묻는다. 건너뛰면 원본 폴더가 남는다 | testN9_dsStoreConflict | `.DS_Store` 는 묻지 않고 대상 것을 유지 |
| V-L2 | Low | FileOperations.swift:402, 413 | 같은 이름 폴더 둘을 기존 폴더로 옮기면 둘째가 `F (2)` 가 된다. Windows 는 둘 다 병합한다 | testN10_duplicateFoldersBatch | 폴더끼리면 중복 이름이어도 병합 허용 |
| V-L3 | Low | FileOperations.swift:450-454 | 대소문자 구분 원본의 `a.txt`·`A.txt` 를 무시 볼륨 기존 폴더로 병합하면 방금 쓴 형제와 충돌해 묻는다. 덮어쓰기를 고르면 방금 옮긴 형제가 휴지통으로 간다 | testN4b. `keepBoth` 로 `a (2).txt` 생성 확인 | 병합 자식에도 배치 내 이름 추적 적용 |
| V-L4 | Low | FileOperations.swift:462-470 | 덮어쓰기와 병합 이동이 휴지통 이동에 의존한다. 휴지통이 없는 네트워크 볼륨에서는 덮어쓰기가 불가능할 수 있다 | 확인 못 함. FAT 는 정상 | 휴지통 실패 시 같은 볼륨 숨김 백업으로 대체 |

### 남은 것

- V-M1 은 수정이 간단하고 회귀이므로 먼저 고치기를 권합니다.
- V-M2 의 범위 결정이 필요합니다. 하위 트리 변경을 무시할지 사용자 판단이 필요합니다.
- M6 은 여전히 Windows 실기 확인이 필요합니다.
- V-L4 는 SMB 볼륨 실기 확인이 필요합니다.
