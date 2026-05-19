import XCTest
@testable import Lector

final class NotificationsTests: XCTestCase {

    func testNotificationNames() {
        XCTAssertEqual(Notification.Name.lectorPrint.rawValue, "lectorPrint")
        XCTAssertEqual(Notification.Name.lectorAddHighlight.rawValue, "lectorAddHighlight")
        XCTAssertEqual(Notification.Name.lectorSearchNext.rawValue, "lectorSearchNext")
        XCTAssertEqual(Notification.Name.lectorSearchPrev.rawValue, "lectorSearchPrev")
        XCTAssertEqual(Notification.Name.lectorWebSearch.rawValue, "lectorWebSearch")
        XCTAssertEqual(Notification.Name.lectorAnnotationsChanged.rawValue, "lectorAnnotationsChanged")
        XCTAssertEqual(Notification.Name.lectorCopySelection.rawValue, "lectorCopySelection")
        XCTAssertEqual(Notification.Name.lectorRotate.rawValue, "lectorRotate")
        XCTAssertEqual(Notification.Name.lectorFocusPDF.rawValue, "lectorFocusPDF")
        XCTAssertEqual(Notification.Name.lectorOpenNewWindow.rawValue, "lectorOpenNewWindow")
        XCTAssertEqual(Notification.Name.lectorScrollBy.rawValue, "lectorScrollBy")
    }
}
