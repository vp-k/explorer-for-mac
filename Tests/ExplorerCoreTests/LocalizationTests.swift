import Foundation
import XCTest
@testable import ExplorerCore

final class LocalizationTests: XCTestCase {
    func testErrorsKeepKoreanFallbackAndLiteralFormatCharacters() {
        let path = "/tmp/100% %@ 문서.txt"
        let cases: [(FileOperationError, String)] = [
            (.invalidName(path), "잘못된 이름입니다: \(path)"),
            (.alreadyExists(path), "같은 이름의 항목이 이미 있습니다: \(path)"),
            (.destinationInsideSource(path), "대상 폴더가 원본 폴더 안에 있습니다: \(path)"),
            (.destinationContainsSource(path), "대상 항목이 원본을 포함하고 있습니다: \(path)"),
            (.notFound(path), "항목을 찾을 수 없습니다: \(path)"),
            (.cancelled, "파일 작업이 취소되었습니다."),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(error.localizedDescription, expected)
        }
    }

    func testPartialDeletionKeepsAllPathsAndFailureReason() {
        let deleted = [URL(fileURLWithPath: "/tmp/첫째.txt"), URL(fileURLWithPath: "/tmp/100%.txt")]
        let failed = URL(fileURLWithPath: "/tmp/실패.txt")
        let error = FileOperationError.partialDeletion(deleted: deleted, failed: failed, reason: "denied %@")
        XCTAssertEqual(error.localizedDescription,
                       "영구 삭제 실패: /tmp/실패.txt\ndenied %@\n삭제 완료:\n/tmp/첫째.txt\n/tmp/100%.txt")
    }
}
