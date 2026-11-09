import Foundation
import SQLite3

/// Watches the macOS Notification Center database for newly delivered notifications.
///
/// There is no public API for observing other apps' notifications, so we read
/// usernoted's SQLite database (read-only). On macOS 15 it lives in a group
/// container that requires Full Disk Access for whatever runs this binary.
final class NotificationWatcher {
    struct Delivered {
        let recordID: Int64
        let bundleID: String
        /// The notification's title (often the sender), if it had one.
        let title: String?
        /// The subtitle (a group chat, a mail subject…), if it had one.
        let subtitle: String?
        /// When macOS delivered it.
        let date: Date
    }

    enum WatchError: Error, CustomStringConvertible {
        case cannotOpen(String)
        case query(String)

        var description: String {
            switch self {
            case .cannotOpen(let msg):
                return """
                Cannot open the Notification Center database (\(msg)).
                Grant Full Disk Access to bleping (or the terminal running it) in
                System Settings › Privacy & Security › Full Disk Access, then restart it.
                """
            case .query(let msg):
                return "Notification database query failed: \(msg)"
            }
        }
    }

    static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sequoia = home + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
        if FileManager.default.fileExists(atPath: sequoia) || access(home + "/Library/Group Containers/group.com.apple.usernoted", F_OK) == 0 {
            return sequoia
        }
        // macOS 14 and earlier
        let darwinUserDir = NSTemporaryDirectory()
            .replacingOccurrences(of: "/T/", with: "/0/")
        return darwinUserDir + "com.apple.notificationcenter/db2/db"
    }

    private let path: String
    private var db: OpaquePointer?
    private var lastRecordID: Int64 = 0

    init(path: String = NotificationWatcher.defaultPath) throws {
        self.path = path
        try open()
        lastRecordID = try maxRecordID()
    }

    deinit { sqlite3_close(db) }

    private func open() throws {
        sqlite3_close(db)
        db = nil
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            throw WatchError.cannotOpen("\(path): \(msg)")
        }
        sqlite3_busy_timeout(db, 500)
        // Force a real read so permission problems surface now, not later.
        _ = try maxRecordID()
    }

    private func maxRecordID() throws -> Int64 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(rec_id), 0) FROM record", -1, &stmt, nil) == SQLITE_OK else {
            throw WatchError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw WatchError.query(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Returns notifications delivered since the last call.
    func poll() throws -> [Delivered] {
        do {
            return try fetchNew()
        } catch {
            // The DB can be vacuumed/replaced by usernoted; reopen once and retry.
            try open()
            return try fetchNew()
        }
    }

    private func fetchNew() throws -> [Delivered] {
        let sql = """
            SELECT r.rec_id, COALESCE(a.identifier, ''), r.data, r.delivered_date
            FROM record r LEFT JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ?
            ORDER BY r.rec_id
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WatchError.query(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(stmt, 1, lastRecordID)

        var result: [Delivered] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw WatchError.query(String(cString: sqlite3_errmsg(db))) }
            let id = sqlite3_column_int64(stmt, 0)
            let bundle = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            var blob: Data?
            if let bytes = sqlite3_column_blob(stmt, 2) {
                blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 2)))
            }
            let text: (title: String?, subtitle: String?) = blob.map(Self.text(fromRecord:)) ?? (nil, nil)
            // delivered_date counts seconds from 2001 (Core Data style); NULL if not delivered yet.
            let delivered = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? Date() : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            result.append(Delivered(recordID: id, bundleID: bundle, title: text.title, subtitle: text.subtitle,
                                    date: delivered))
            lastRecordID = max(lastRecordID, id)
        }
        return result
    }

    /// `record.data` is a binary plist; the visible text sits under "req":
    /// "titl" (title), "subt" (subtitle), "body". The body is never read.
    /// Some apps store a localization key array instead of text; those are skipped.
    static func text(fromRecord data: Data) -> (title: String?, subtitle: String?) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let request = plist["req"] as? [String: Any] else { return (nil, nil) }
        func field(_ key: String) -> String? {
            guard let text = (request[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }
        return (field("titl"), field("subt"))
    }
}
