import Foundation
import SQLite3

/// A small wrapper over the system SQLite, for Offline Kit's own caches (the answer index, the paragraph cache).
/// One connection is used by one thread at a time; callers hold their own lock.
final class SQLiteDB: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private(set) var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(handle)
            handle = nil
            throw Failure(description: message)
        }
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit { close() }

    func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    var lastError: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    /// The rowid of the last row inserted on this connection.
    var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    /// Runs one or more statements separated by semicolons, ignoring any rows.
    func script(_ sql: String) throws {
        try sql.withCString { start in
            var cursor: UnsafePointer<CChar>? = start
            while let current = cursor, current.pointee != 0 {
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                guard sqlite3_prepare_v2(handle, current, -1, &statement, &tail) == SQLITE_OK else {
                    throw Failure(description: "\(lastError) in \(sql.prefix(80))")
                }
                defer { sqlite3_finalize(statement) }
                if let statement {
                    var status = sqlite3_step(statement)
                    while status == SQLITE_ROW { status = sqlite3_step(statement) }
                    guard status == SQLITE_DONE else { throw Failure(description: "\(lastError) in \(sql.prefix(80))") }
                }
                cursor = tail
            }
        }
    }

    /// Runs `body` in one transaction: committed if it returns, rolled back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try script("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try script("COMMIT")
            return result
        } catch {
            try? script("ROLLBACK")
            throw error
        }
    }

    /// Runs a statement (prepared once and kept) with values bound in order, calling `row` for each result row.
    func run(_ sql: String, _ values: [SQLiteValue] = [], row: ((SQLiteRow) throws -> Void)? = nil) throws {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
                throw Failure(description: "\(lastError) in \(sql.prefix(80))")
            }
            statements[sql] = prepared
            statement = prepared
        }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .double(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw Failure(description: "\(lastError) in \(sql.prefix(80))") }
            try row?(SQLiteRow(statement: statement))
        }
    }

    /// The first column of the first row, as an integer.
    func scalar(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64? {
        var result: Int64?
        try run(sql, values) { if result == nil { result = $0.int(0) } }
        return result
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

enum SQLiteValue {
    case int(Int64), double(Double), text(String), blob(Data), null
}

struct SQLiteRow {
    let statement: OpaquePointer
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
    func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
    func blob(_ i: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, i) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, i)))
    }
}
