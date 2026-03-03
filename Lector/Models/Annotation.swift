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
    let type: Character     // 'a','b','c','d' → different colors
    let selectionText: String
    let createdAt: Date

    /// Decoded rects per page index (relative to PDF page coordinates)
    func rectsPerPage() -> [Int: [CGRect]] {
        guard let data = rectsJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        var result: [Int: [CGRect]] = [:]
        for entry in raw {
            guard let page = entry["page"] as? Int,
                  let x = entry["x"] as? Double,
                  let y = entry["y"] as? Double,
                  let w = entry["w"] as? Double,
                  let h = entry["h"] as? Double
            else { continue }
            result[page, default: []].append(CGRect(x: x, y: y, width: w, height: h))
        }
        return result
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
