import Foundation
import SQLite3

// MARK: - Database

final class Database {
    private var db: OpaquePointer?
    private let dbURL: URL

    // MARK: Init

    init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Lector", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("lector.db")

        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            throw DBError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try enableWAL()
        try createSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func createSchema() throws {
        let sql = """
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS documents (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            url               TEXT    NOT NULL UNIQUE,
            checksum          TEXT    NOT NULL,
            last_opened       REAL    NOT NULL DEFAULT 0,
            last_page         INTEGER NOT NULL DEFAULT 0,
            last_y_offset     REAL    NOT NULL DEFAULT 0,
            last_zoom         REAL    NOT NULL DEFAULT 1.0,
            last_fit_to_width INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE IF NOT EXISTS bookmarks (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            doc_id      INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            page        INTEGER NOT NULL,
            y_offset    REAL    NOT NULL DEFAULT 0,
            text        TEXT    NOT NULL DEFAULT '',
            created_at  REAL    NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS highlights (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            doc_id         INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            start_page     INTEGER NOT NULL,
            end_page       INTEGER NOT NULL,
            rects_json     TEXT    NOT NULL DEFAULT '[]',
            type           TEXT(1) NOT NULL DEFAULT 'a',
            selection_text TEXT    NOT NULL DEFAULT '',
            created_at     REAL    NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS marks (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            doc_id   INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            symbol   TEXT(1) NOT NULL,
            page     INTEGER NOT NULL,
            y_offset REAL    NOT NULL DEFAULT 0,
            UNIQUE(doc_id, symbol)
        );

        CREATE TABLE IF NOT EXISTS global_marks (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            symbol  TEXT(1) NOT NULL UNIQUE,
            doc_url TEXT    NOT NULL,
            page    INTEGER NOT NULL,
            y_offset REAL   NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS portals (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            src_doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            src_page   INTEGER NOT NULL,
            src_y      REAL    NOT NULL DEFAULT 0,
            dst_url    TEXT    NOT NULL,
            dst_page   INTEGER NOT NULL,
            dst_y      REAL    NOT NULL DEFAULT 0,
            dst_zoom   REAL    NOT NULL DEFAULT 1.0
        );
        """
        try exec(sql)
        migrateDocumentsTable()
    }

    // Adds columns introduced after the initial release; skips any column
    // that already exists so it is safe on both old and new databases.
    private func migrateDocumentsTable() {
        let existing = existingColumns(in: "documents")
        let migrations: [(String, String)] = [
            ("last_page",         "INTEGER NOT NULL DEFAULT 0"),
            ("last_y_offset",     "REAL    NOT NULL DEFAULT 0"),
            ("last_zoom",         "REAL    NOT NULL DEFAULT 1.0"),
            ("last_fit_to_width", "INTEGER NOT NULL DEFAULT 1"),
        ]
        for (col, def) in migrations where !existing.contains(col) {
            sqlite3_exec(db, "ALTER TABLE documents ADD COLUMN \(col) \(def);", nil, nil, nil)
        }
    }

    private func existingColumns(in table: String) -> Set<String> {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        var columns = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 1) {
                columns.insert(String(cString: cStr))
            }
        }
        return columns
    }

    private func enableWAL() throws {
        try exec("PRAGMA journal_mode = WAL;")
    }

    // MARK: - Documents

    @discardableResult
    func upsertDocument(url: URL, checksum: String) throws -> Int64 {
        let urlStr = url.path
        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO documents (url, checksum, last_opened)
        VALUES (?, ?, ?)
        ON CONFLICT(url) DO UPDATE SET checksum = excluded.checksum, last_opened = excluded.last_opened;
        """
        try exec(sql, bindings: [urlStr, checksum, now])
        // Fetch the id
        let fetchSQL = "SELECT id FROM documents WHERE url = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, fetchSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        sqlite3_bind_text(stmt, 1, (urlStr as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return sqlite3_last_insert_rowid(db)
    }

    func fetchRecentDocuments(limit: Int = 20) throws -> [RecentDocument] {
        let sql = "SELECT id, url, checksum, last_opened FROM documents ORDER BY last_opened DESC LIMIT ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var results: [RecentDocument] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let urlStr = String(cString: sqlite3_column_text(stmt, 1))
            let checksum = String(cString: sqlite3_column_text(stmt, 2))
            let lastOpened = sqlite3_column_double(stmt, 3)
            results.append(RecentDocument(
                id: id,
                url: URL(fileURLWithPath: urlStr),
                checksum: checksum,
                lastOpened: Date(timeIntervalSince1970: lastOpened)
            ))
        }
        return results
    }

    // MARK: - Last Position

    struct LastPosition {
        let page: Int
        let yOffset: Double
        let zoom: Double
        let fitToWidth: Bool
    }

    func saveLastPosition(docID: Int64, page: Int, yOffset: Double,
                          zoom: Double, fitToWidth: Bool) throws {
        let sql = """
        UPDATE documents
        SET last_page = ?, last_y_offset = ?, last_zoom = ?, last_fit_to_width = ?
        WHERE id = ?;
        """
        try exec(sql, bindings: [page, yOffset, zoom, fitToWidth ? 1 : 0, docID])
    }

    func fetchLastPosition(docID: Int64) throws -> LastPosition? {
        let sql = """
        SELECT last_page, last_y_offset, last_zoom, last_fit_to_width
        FROM documents WHERE id = ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        sqlite3_bind_int64(stmt, 1, docID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return LastPosition(
            page:        Int(sqlite3_column_int(stmt, 0)),
            yOffset:     sqlite3_column_double(stmt, 1),
            zoom:        sqlite3_column_double(stmt, 2),
            fitToWidth:  sqlite3_column_int(stmt, 3) != 0
        )
    }

    // MARK: - Bookmarks

    @discardableResult
    func addBookmark(docID: Int64, page: Int, yOffset: Double, text: String) throws -> Int64 {
        let sql = "INSERT INTO bookmarks (doc_id, page, y_offset, text, created_at) VALUES (?, ?, ?, ?, ?);"
        try exec(sql, bindings: [docID, page, yOffset, text, Date().timeIntervalSince1970])
        return sqlite3_last_insert_rowid(db)
    }

    func fetchBookmarks(docID: Int64) throws -> [Bookmark] {
        let sql = "SELECT id, doc_id, page, y_offset, text, created_at FROM bookmarks WHERE doc_id = ? ORDER BY page, y_offset;"
        return try fetchBookmarksSQL(sql, bindings: [docID])
    }

    func fetchAllBookmarks() throws -> [Bookmark] {
        let sql = "SELECT id, doc_id, page, y_offset, text, created_at FROM bookmarks ORDER BY doc_id, page, y_offset;"
        return try fetchBookmarksSQL(sql, bindings: [])
    }

    func deleteBookmark(id: Int64) throws {
        try exec("DELETE FROM bookmarks WHERE id = ?;", bindings: [id])
    }

    func deleteBookmark(docID: Int64, page: Int, yOffset: Double, tolerance: Double = 5.0) throws {
        let sql = """
        DELETE FROM bookmarks WHERE doc_id = ? AND page = ? AND ABS(y_offset - ?) < ?;
        """
        try exec(sql, bindings: [docID, page, yOffset, tolerance])
    }

    private func fetchBookmarksSQL(_ sql: String, bindings: [Any]) throws -> [Bookmark] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        bind(stmt: stmt, values: bindings)
        var results: [Bookmark] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(Bookmark(
                id: sqlite3_column_int64(stmt, 0),
                docID: sqlite3_column_int64(stmt, 1),
                page: Int(sqlite3_column_int(stmt, 2)),
                yOffset: sqlite3_column_double(stmt, 3),
                text: columnString(stmt, 4),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            ))
        }
        return results
    }

    // MARK: - Highlights

    @discardableResult
    func addHighlight(docID: Int64, startPage: Int, endPage: Int,
                      rectsJSON: String, type: Character, selectionText: String) throws -> Int64 {
        let sql = """
        INSERT INTO highlights (doc_id, start_page, end_page, rects_json, type, selection_text, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try exec(sql, bindings: [docID, startPage, endPage, rectsJSON, String(type), selectionText,
                                  Date().timeIntervalSince1970])
        return sqlite3_last_insert_rowid(db)
    }

    func fetchHighlights(docID: Int64) throws -> [Highlight] {
        let sql = """
        SELECT id, doc_id, start_page, end_page, rects_json, type, selection_text, created_at
        FROM highlights WHERE doc_id = ? ORDER BY start_page;
        """
        return try fetchHighlightsSQL(sql, bindings: [docID])
    }

    func deleteHighlight(id: Int64) throws {
        try exec("DELETE FROM highlights WHERE id = ?;", bindings: [id])
    }

    private func fetchHighlightsSQL(_ sql: String, bindings: [Any]) throws -> [Highlight] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        bind(stmt: stmt, values: bindings)
        var results: [Highlight] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let typeStr = columnString(stmt, 5)
            let typeChar: Character = typeStr.isEmpty ? "a" : typeStr.first!
            results.append(Highlight(
                id: sqlite3_column_int64(stmt, 0),
                docID: sqlite3_column_int64(stmt, 1),
                startPage: Int(sqlite3_column_int(stmt, 2)),
                endPage: Int(sqlite3_column_int(stmt, 3)),
                rectsJSON: columnString(stmt, 4),
                type: typeChar,
                selectionText: columnString(stmt, 6),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            ))
        }
        return results
    }

    // MARK: - Marks

    func setMark(docID: Int64, symbol: Character, page: Int, yOffset: Double) throws {
        let sql = """
        INSERT INTO marks (doc_id, symbol, page, y_offset)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(doc_id, symbol) DO UPDATE SET page = excluded.page, y_offset = excluded.y_offset;
        """
        try exec(sql, bindings: [docID, String(symbol), page, yOffset])
    }

    func fetchMarks(docID: Int64) throws -> [Mark] {
        let sql = "SELECT id, doc_id, symbol, page, y_offset FROM marks WHERE doc_id = ? ORDER BY symbol;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        sqlite3_bind_int64(stmt, 1, docID)
        var results: [Mark] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let symStr = columnString(stmt, 2)
            let sym: Character = symStr.isEmpty ? "a" : symStr.first!
            results.append(Mark(
                id: sqlite3_column_int64(stmt, 0),
                docID: sqlite3_column_int64(stmt, 1),
                symbol: sym,
                page: Int(sqlite3_column_int(stmt, 3)),
                yOffset: sqlite3_column_double(stmt, 4)
            ))
        }
        return results
    }

    // MARK: - Global Marks

    func setGlobalMark(symbol: Character, docURL: String, page: Int, yOffset: Double) throws {
        let sql = """
        INSERT INTO global_marks (symbol, doc_url, page, y_offset)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(symbol) DO UPDATE SET doc_url = excluded.doc_url, page = excluded.page, y_offset = excluded.y_offset;
        """
        try exec(sql, bindings: [String(symbol), docURL, page, yOffset])
    }

    func fetchGlobalMark(symbol: Character) throws -> GlobalMark? {
        let sql = "SELECT id, symbol, doc_url, page, y_offset FROM global_marks WHERE symbol = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        sqlite3_bind_text(stmt, 1, (String(symbol) as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let symStr = columnString(stmt, 1)
            return GlobalMark(
                id: sqlite3_column_int64(stmt, 0),
                symbol: symStr.isEmpty ? symbol : symStr.first!,
                docURL: columnString(stmt, 2),
                page: Int(sqlite3_column_int(stmt, 3)),
                yOffset: sqlite3_column_double(stmt, 4)
            )
        }
        return nil
    }

    // MARK: - Portals

    @discardableResult
    func addPortal(srcDocID: Int64, srcPage: Int, srcY: Double,
                   dstURL: String, dstPage: Int, dstY: Double, dstZoom: Double = 1.0) throws -> Int64 {
        let sql = """
        INSERT INTO portals (src_doc_id, src_page, src_y, dst_url, dst_page, dst_y, dst_zoom)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try exec(sql, bindings: [srcDocID, srcPage, srcY, dstURL, dstPage, dstY, dstZoom])
        return sqlite3_last_insert_rowid(db)
    }

    func fetchPortals(srcDocID: Int64) throws -> [Portal] {
        let sql = """
        SELECT id, src_doc_id, src_page, src_y, dst_url, dst_page, dst_y, dst_zoom
        FROM portals WHERE src_doc_id = ? ORDER BY src_page;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        sqlite3_bind_int64(stmt, 1, srcDocID)
        var results: [Portal] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(Portal(
                id: sqlite3_column_int64(stmt, 0),
                srcDocID: sqlite3_column_int64(stmt, 1),
                srcPage: Int(sqlite3_column_int(stmt, 2)),
                srcY: sqlite3_column_double(stmt, 3),
                dstURL: columnString(stmt, 4),
                dstPage: Int(sqlite3_column_int(stmt, 5)),
                dstY: sqlite3_column_double(stmt, 6),
                dstZoom: sqlite3_column_double(stmt, 7)
            ))
        }
        return results
    }

    func deletePortal(id: Int64) throws {
        try exec("DELETE FROM portals WHERE id = ?;", bindings: [id])
    }

    func deletePortal(srcDocID: Int64, srcPage: Int, srcY: Double, tolerance: Double = 5.0) throws {
        let sql = """
        DELETE FROM portals WHERE src_doc_id = ? AND src_page = ? AND ABS(src_y - ?) < ?;
        """
        try exec(sql, bindings: [srcDocID, srcPage, srcY, tolerance])
    }

    func nearestPortal(srcDocID: Int64, page: Int, yOffset: Double, radius: Double = 50.0) throws -> Portal? {
        let sql = """
        SELECT id, src_doc_id, src_page, src_y, dst_url, dst_page, dst_y, dst_zoom
        FROM portals
        WHERE src_doc_id = ? AND src_page = ? AND ABS(src_y - ?) < ?
        ORDER BY ABS(src_y - ?) LIMIT 1;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(lastError)
        }
        bind(stmt: stmt, values: [srcDocID, page, yOffset, radius, yOffset])
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Portal(
                id: sqlite3_column_int64(stmt, 0),
                srcDocID: sqlite3_column_int64(stmt, 1),
                srcPage: Int(sqlite3_column_int(stmt, 2)),
                srcY: sqlite3_column_double(stmt, 3),
                dstURL: columnString(stmt, 4),
                dstPage: Int(sqlite3_column_int(stmt, 5)),
                dstY: sqlite3_column_double(stmt, 6),
                dstZoom: sqlite3_column_double(stmt, 7)
            )
        }
        return nil
    }

    // MARK: - Helpers

    private func exec(_ sql: String, bindings: [Any] = []) throws {
        if bindings.isEmpty {
            var errMsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                let msg = errMsg.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(errMsg)
                throw DBError.execFailed(msg)
            }
        } else {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepareFailed(lastError)
            }
            bind(stmt: stmt, values: bindings)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE && rc != SQLITE_ROW {
                throw DBError.stepFailed(lastError)
            }
        }
    }

    private func bind(stmt: OpaquePointer?, values: [Any]) {
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let v as Int64:
                sqlite3_bind_int64(stmt, idx, v)
            case let v as Int:
                sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double:
                sqlite3_bind_double(stmt, idx, v)
            case let v as String:
                sqlite3_bind_text(stmt, idx, (v as NSString).utf8String, -1, nil)
            default:
                sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func columnString(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cStr)
    }

    private var lastError: String {
        String(cString: sqlite3_errmsg(db))
    }
}

// MARK: - Errors

enum DBError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case execFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "DB open failed: \(m)"
        case .prepareFailed(let m): return "DB prepare failed: \(m)"
        case .execFailed(let m): return "DB exec failed: \(m)"
        case .stepFailed(let m): return "DB step failed: \(m)"
        }
    }
}
