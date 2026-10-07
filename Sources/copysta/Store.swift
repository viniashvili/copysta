import Foundation
import SQLite3

// SQLITE_TRANSIENT (-1) is a C macro; define it as a Swift constant.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum StoreError: Error {
    case open(String)
    case exec(String)
    case prepare(String)
}

final class Store {
    private var db: OpaquePointer?
    let dataDir: String

    init(dbPath: String, dataDir: String) throws {
        self.dataDir = dataDir
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA busy_timeout=5000")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    // MARK: - Public API

    /// Inserts or updates an entry by hash. Returns the resulting row id.
    @discardableResult
    func upsert(_ item: ClipItem, dataDir: String) throws -> Int64 {
        let hash = item.kind == .text
            ? sha256(data: Data((item.text ?? "").utf8))
            : sha256(data: item.imageData ?? Data())

        // Touch existing if hash matches.
        var existing: Int64? = nil
        let qSel = "SELECT id FROM entries WHERE hash = ? LIMIT 1"
        if let stmt = try? prepare(qSel) {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, hash, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                existing = sqlite3_column_int64(stmt, 0)
            }
        }
        if let eid = existing {
            let ts = Int64(Date().timeIntervalSince1970)
            try exec("UPDATE entries SET last_used_at = \(ts) WHERE id = \(eid)")
            return eid
        }

        // New entry.
        let now = Int64(Date().timeIntervalSince1970)
        let kindStr = item.kind.rawValue

        var imagePath: String? = nil
        if item.kind == .image, let data = item.imageData {
            let dir = (dataDir as NSString).appendingPathComponent("images")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = (dir as NSString).appendingPathComponent("\(hash).png")
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            imagePath = path
        }

        let size = Int64(item.text?.utf8.count ?? item.imageData?.count ?? 0)
        let sql = """
            INSERT INTO entries (kind, text, image_path, hash, size, created_at, last_used_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, kindStr, -1, SQLITE_TRANSIENT)
        if let t = item.text {
            sqlite3_bind_text(stmt, 2, t, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let p = imagePath {
            sqlite3_bind_text(stmt, 3, p, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_text(stmt, 4, hash, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, size)
        sqlite3_bind_int64(stmt, 6, now)
        sqlite3_bind_int64(stmt, 7, now)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    func list(limit: Int) throws -> [Entry] {
        let sql = """
            SELECT id, kind, text, image_path, hash, size, created_at, last_used_at
            FROM entries
            ORDER BY last_used_at DESC
            LIMIT ?
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))

        var results: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id       = sqlite3_column_int64(stmt, 0)
            let kindStr  = String(cString: sqlite3_column_text(stmt, 1))
            let text     = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let imgPath  = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let hash     = String(cString: sqlite3_column_text(stmt, 4))
            let size     = sqlite3_column_int64(stmt, 5)
            let created  = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 6)))
            let used     = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 7)))
            let kind     = EntryKind(rawValue: kindStr) ?? .text
            results.append(Entry(id: id, kind: kind, text: text, imagePath: imgPath,
                                 hash: hash, size: size, createdAt: created, lastUsedAt: used))
        }
        return results
    }

    func delete(id: Int64) throws {
        // Also delete image file if present.
        if let path = imagePath(for: id) {
            try? FileManager.default.removeItem(atPath: path)
        }
        try exec("DELETE FROM entries WHERE id = \(id)")
    }

    func clear() throws {
        // Delete all image files.
        let sql = "SELECT image_path FROM entries WHERE image_path IS NOT NULL"
        if let stmt = try? prepare(sql) {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let p = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) {
                    try? FileManager.default.removeItem(atPath: p)
                }
            }
        }
        try exec("DELETE FROM entries")
    }

    func trim(max: Int) throws {
        let sql = """
            DELETE FROM entries WHERE id IN (
                SELECT id FROM entries ORDER BY last_used_at DESC LIMIT -1 OFFSET ?
            )
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(max))
        sqlite3_step(stmt)
    }

    // MARK: - Private

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS entries (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                kind         TEXT    NOT NULL,
                text         TEXT,
                image_path   TEXT,
                hash         TEXT    NOT NULL UNIQUE,
                size         INTEGER NOT NULL,
                created_at   INTEGER NOT NULL,
                last_used_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_last_used ON entries(last_used_at DESC);
        """)
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.exec(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw StoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return s
    }

    private func imagePath(for id: Int64) -> String? {
        let sql = "SELECT image_path FROM entries WHERE id = ? LIMIT 1"
        guard let stmt = try? prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }
}

// MARK: - SHA-256 without CryptoKit (plain CommonCrypto)

import CommonCrypto

private func sha256(data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
}
