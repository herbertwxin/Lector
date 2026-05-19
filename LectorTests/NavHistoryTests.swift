import XCTest
@testable import Lector

final class NavHistoryTests: XCTestCase {

    private func createDummyState(_ page: Int) -> NavState {
        return NavState(url: URL(fileURLWithPath: "/dummy.pdf"), page: page, yOffset: 0)
    }

    func testInitialState() {
        let history = NavHistory()
        XCTAssertNil(history.current)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.back())
        XCTAssertNil(history.forward())
    }

    func testPush() {
        let history = NavHistory()
        let state1 = createDummyState(1)
        history.push(state1)

        XCTAssertEqual(history.current, state1)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        let state2 = createDummyState(2)
        history.push(state2)

        XCTAssertEqual(history.current, state2)
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    func testPushDuplicateIgnores() {
        let history = NavHistory()
        let state1 = createDummyState(1)

        history.push(state1)
        history.push(state1) // Should ignore

        XCTAssertEqual(history.current, state1)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    func testPushDropsForwardHistory() {
        let history = NavHistory()
        let state1 = createDummyState(1)
        let state2 = createDummyState(2)
        let state3 = createDummyState(3)

        history.push(state1)
        history.push(state2)

        XCTAssertEqual(history.back(), state1)
        XCTAssertTrue(history.canGoForward)

        // Pushing a new state should drop state2 from forward history
        history.push(state3)
        XCTAssertEqual(history.current, state3)
        XCTAssertFalse(history.canGoForward)
        XCTAssertTrue(history.canGoBack)
        XCTAssertEqual(history.back(), state1)
    }

    func testCapacityLimit() {
        let history = NavHistory(capacity: 3)

        let state1 = createDummyState(1)
        let state2 = createDummyState(2)
        let state3 = createDummyState(3)
        let state4 = createDummyState(4)

        history.push(state1)
        history.push(state2)
        history.push(state3)

        // At capacity
        XCTAssertEqual(history.current, state3)

        // Over capacity, should drop state1
        history.push(state4)

        XCTAssertEqual(history.current, state4)
        XCTAssertEqual(history.back(), state3)
        XCTAssertEqual(history.back(), state2)
        XCTAssertNil(history.back()) // state1 is gone
    }

    func testBackAndForward() {
        let history = NavHistory()
        let state1 = createDummyState(1)
        let state2 = createDummyState(2)
        let state3 = createDummyState(3)

        history.push(state1)
        history.push(state2)
        history.push(state3)

        XCTAssertFalse(history.canGoForward)
        XCTAssertTrue(history.canGoBack)

        XCTAssertEqual(history.back(), state2)
        XCTAssertEqual(history.current, state2)
        XCTAssertTrue(history.canGoForward)
        XCTAssertTrue(history.canGoBack)

        XCTAssertEqual(history.back(), state1)
        XCTAssertEqual(history.current, state1)
        XCTAssertTrue(history.canGoForward)
        XCTAssertFalse(history.canGoBack)

        XCTAssertNil(history.back()) // Cannot go back further

        XCTAssertEqual(history.forward(), state2)
        XCTAssertEqual(history.current, state2)

        XCTAssertEqual(history.forward(), state3)
        XCTAssertEqual(history.current, state3)

        XCTAssertNil(history.forward()) // Cannot go forward further
    }
}
