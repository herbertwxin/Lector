import Foundation
import CoreGraphics

// MARK: - Bookmark

struct Bookmark: Identifiable, Hashable {
    let id: Int64
    let docID: Int64
    let page: Int
    let yOffset: Double
    let text: String
    let createdAt: Date
}

// MARK: - Highlight

struct Highlight: Identifiable, Hashable {
    let id: Int64
    let docID: Int64
    let startPage: Int
    let endPage: Int
    let rectsJSON: String   // JSON array of page-relative CGRect values: [[x,y,w,h], ...]
    let decodedRects: [Int: [CGRect]] // Decoded rects per page index (relative to PDF page coordinates)
    let type: Character     // 'a','b','c','d' → different colors
    let selectionText: String
    let createdAt: Date

    init(id: Int64, docID: Int64, startPage: Int, endPage: Int, rectsJSON: String, type: Character, selectionText: String, createdAt: Date) {
        self.id = id
        self.docID = docID
        self.startPage = startPage
        self.endPage = endPage
        self.rectsJSON = rectsJSON
        self.type = type
        self.selectionText = selectionText
        self.createdAt = createdAt

        var result: [Int: [CGRect]] = [:]
        if let data = rectsJSON.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for entry in raw {
                guard let page = entry["page"] as? Int,
                      let x = entry["x"] as? Double,
                      let y = entry["y"] as? Double,
                      let w = entry["w"] as? Double,
                      let h = entry["h"] as? Double
                else { continue }
                result[page, default: []].append(CGRect(x: x, y: y, width: w, height: h))
            }
        }
        self.decodedRects = result
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Highlight, rhs: Highlight) -> Bool {
        return lhs.id == rhs.id
    }

    static func encodeRects(_ rectsPerPage: [Int: [CGRect]]) -> String {
        var entries: [[String: Any]] = []
        for (page, rects) in rectsPerPage {
            for rect in rects {
                entries.append([
                    "page": page,
                    "x": rect.origin.x,
                    "y": rect.origin.y,
                    "w": rect.width,
                    "h": rect.height
                ])
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entries),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }
}

// MARK: - Mark (local, per-document)

struct Mark: Identifiable, Hashable {
    let id: Int64
    let docID: Int64
    let symbol: Character
    let page: Int
    let yOffset: Double
}

// MARK: - Global Mark (cross-document)

struct GlobalMark: Identifiable, Hashable {
    let id: Int64
    let symbol: Character
    let docURL: String
    let page: Int
    let yOffset: Double
}

// MARK: - Portal

struct Portal: Identifiable, Hashable {
    let id: Int64
    let srcDocID: Int64
    let srcPage: Int
    let srcY: Double
    let dstURL: String
    let dstPage: Int
    let dstY: Double
    let dstZoom: Double
}

// MARK: - Recent Document (for QuickSelectPanel)

struct RecentDocument: Identifiable {
    let id: Int64
    let url: URL
    let checksum: String
    let lastOpened: Date
}
