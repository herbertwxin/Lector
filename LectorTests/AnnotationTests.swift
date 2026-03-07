import XCTest
@testable import Lector

final class AnnotationTests: XCTestCase {

    func testEncodeRectsEmpty() {
        let input: [Int: [CGRect]] = [:]
        let jsonString = Highlight.encodeRects(input)

        // When encoding an empty dictionary, it should return "[]"
        XCTAssertEqual(jsonString, "[]")
    }

    func testEncodeRectsSinglePageSingleRect() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        let input: [Int: [CGRect]] = [1: [rect]]

        let jsonString = Highlight.encodeRects(input)

        // Decode the JSON string to verify contents independently of order/formatting
        guard let data = jsonString.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("Failed to decode JSON string")
            return
        }

        XCTAssertEqual(jsonArray.count, 1)

        let firstDict = jsonArray[0]
        XCTAssertEqual(firstDict["page"] as? Int, 1)
        XCTAssertEqual(firstDict["x"] as? Double, 10.0)
        XCTAssertEqual(firstDict["y"] as? Double, 20.0)
        XCTAssertEqual(firstDict["w"] as? Double, 100.0)
        XCTAssertEqual(firstDict["h"] as? Double, 50.0)
    }

    func testEncodeRectsMultiplePagesMultipleRects() {
        let rect1 = CGRect(x: 10, y: 20, width: 100, height: 50)
        let rect2 = CGRect(x: 15, y: 25, width: 105, height: 55)
        let rect3 = CGRect(x: 100, y: 200, width: 50, height: 25)

        let input: [Int: [CGRect]] = [
            1: [rect1, rect2],
            2: [rect3]
        ]

        let jsonString = Highlight.encodeRects(input)

        guard let data = jsonString.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("Failed to decode JSON string")
            return
        }

        XCTAssertEqual(jsonArray.count, 3)

        // Since dictionary iteration order is undefined, we need to find the decoded items by some criteria
        // Let's sort them by page, then by x
        let sortedArray = jsonArray.sorted {
            let page1 = $0["page"] as? Int ?? 0
            let page2 = $1["page"] as? Int ?? 0
            if page1 == page2 {
                let x1 = $0["x"] as? Double ?? 0.0
                let x2 = $1["x"] as? Double ?? 0.0
                return x1 < x2
            }
            return page1 < page2
        }

        // First rect (page 1, x: 10)
        XCTAssertEqual(sortedArray[0]["page"] as? Int, 1)
        XCTAssertEqual(sortedArray[0]["x"] as? Double, 10.0)
        XCTAssertEqual(sortedArray[0]["y"] as? Double, 20.0)
        XCTAssertEqual(sortedArray[0]["w"] as? Double, 100.0)
        XCTAssertEqual(sortedArray[0]["h"] as? Double, 50.0)

        // Second rect (page 1, x: 15)
        XCTAssertEqual(sortedArray[1]["page"] as? Int, 1)
        XCTAssertEqual(sortedArray[1]["x"] as? Double, 15.0)
        XCTAssertEqual(sortedArray[1]["y"] as? Double, 25.0)
        XCTAssertEqual(sortedArray[1]["w"] as? Double, 105.0)
        XCTAssertEqual(sortedArray[1]["h"] as? Double, 55.0)

        // Third rect (page 2, x: 100)
        XCTAssertEqual(sortedArray[2]["page"] as? Int, 2)
        XCTAssertEqual(sortedArray[2]["x"] as? Double, 100.0)
        XCTAssertEqual(sortedArray[2]["y"] as? Double, 200.0)
        XCTAssertEqual(sortedArray[2]["w"] as? Double, 50.0)
        XCTAssertEqual(sortedArray[2]["h"] as? Double, 25.0)
    }
}
