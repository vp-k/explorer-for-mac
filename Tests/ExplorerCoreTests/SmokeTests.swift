import XCTest
@testable import ExplorerCore

final class SmokeTests: XCTestCase {
    func testClipboardCut() {
        var c = FileClipboard()
        let u = URL(fileURLWithPath: "/tmp/a")
        c.set([u], mode: .cut)
        XCTAssertTrue(c.isCut(u))
    }
}
