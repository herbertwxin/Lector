import Foundation

struct Highlight {
    var id: Int
    var startPage: Int
    var endPage: Int
}

let count = 100_000
var highlights = (0..<count).map { Highlight(id: $0, startPage: $0, endPage: $0) }

let currentPage = 99_999

let start1 = CFAbsoluteTimeGetCurrent()
for _ in 0..<100 {
    let nearby = highlights.filter { $0.startPage <= currentPage && $0.endPage >= currentPage }
    let first = nearby.first
}
let time1 = CFAbsoluteTimeGetCurrent() - start1
print("filter.first time: \(time1) seconds")

let start2 = CFAbsoluteTimeGetCurrent()
for _ in 0..<100 {
    let first = highlights.first { $0.startPage <= currentPage && $0.endPage >= currentPage }
}
let time2 = CFAbsoluteTimeGetCurrent() - start2
print("first(where:) time: \(time2) seconds")
