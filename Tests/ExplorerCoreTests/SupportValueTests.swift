import Foundation
import XCTest
@testable import ExplorerCore

final class SupportValueTests: XCTestCase {
    func testExplorerSizeRoundsUpAndGroupsThousands() {
        for (bytes, expected) in [(Int64(0), "0 KB"), (1, "1 KB"), (1024, "1 KB"),
                                  (1025, "2 KB"), (1_263_616, "1,234 KB"), (-1, "0 KB")] {
            XCTAssertEqual(SizeFormatter.explorerSize(bytes), expected)
        }
        XCTAssertEqual(SizeFormatter.explorerSize(Int64.max), "9,007,199,254,740,992 KB")
    }

    func testHumanSizeUsesBinaryUnitsAndOneDecimalPlace() {
        XCTAssertEqual(SizeFormatter.humanSize(0), "0 B")
        XCTAssertEqual(SizeFormatter.humanSize(-100), "0 B")
        XCTAssertEqual(SizeFormatter.humanSize(1023), "1023 B")
        XCTAssertEqual(SizeFormatter.humanSize(1024), "1 KB")
        XCTAssertEqual(SizeFormatter.humanSize(1536), "1.5 KB")
        XCTAssertEqual(SizeFormatter.humanSize(1_572_864), "1.5 MB")
        XCTAssertEqual(SizeFormatter.humanSize(3_435_973_837), "3.2 GB")
        XCTAssertEqual(SizeFormatter.humanSize(Int64.max), "8 EB")
    }

    func testWildcardWithoutGlobUsesCaseInsensitiveSubstring() {
        XCTAssertTrue(WildcardMatcher.matches("Report.TXT", pattern: "PORT"))
        XCTAssertTrue(WildcardMatcher.matches("보고서.txt", pattern: "보고"))
        XCTAssertTrue(WildcardMatcher.matches("anything", pattern: ""))
        XCTAssertFalse(WildcardMatcher.matches("report.txt", pattern: "pdf"))
    }

    func testWildcardStarsAndQuestionMarksMatchWholeName() {
        let examples: [(String, String, Bool)] = [
            ("Report.TXT", "*.txt", true), ("a.txt", "?.txt", true), ("ab.txt", "?.txt", false),
            ("prefix-report.txt", "report*", false), ("ababa", "*aba", true),
            ("abcXYZdef", "a*c*d*f", true), ("abc", "a*d", false), ("", "*", true),
            ("", "?", false), ("abc", "**a**?**c**", true), ("a+b.txt", "a+b.*", true),
            ("😀.txt", "?.txt", true), ("abc", "*?*?*?*?", false)
        ]
        for (name, pattern, expected) in examples {
            XCTAssertEqual(WildcardMatcher.matches(name, pattern: pattern), expected, "\(name), \(pattern)")
        }
    }

    func testClipboardCopyCutAndClear() {
        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        var clipboard = FileClipboard()
        XCTAssertEqual(clipboard.urls, [])
        clipboard.set([a, b], mode: .copy)
        XCTAssertFalse(clipboard.isCut(a))
        clipboard.set([a], mode: .cut)
        XCTAssertTrue(clipboard.isCut(a))
        XCTAssertFalse(clipboard.isCut(b))
        clipboard.clear()
        XCTAssertTrue(clipboard.urls.isEmpty)
        XCTAssertEqual(clipboard.mode, .copy)
        XCTAssertFalse(clipboard.isCut(a))
    }
}
