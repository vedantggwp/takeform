import CSQLite
import Darwin
import Foundation

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let value): value } }
}

public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    public init(path: URL) throws {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(path.path, &opened, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SQLiteError.message("Could not open SQLite database at \(path.path)")
        }
        handle = opened
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
    }

    deinit { sqlite3_close(handle) }

    public func execute(_ sql: String, bindings: [String] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient) == SQLITE_OK else { throw failure() }
        }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw failure() }
    }

    public func value(_ sql: String, bindings: [String] = []) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient) == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    public func row(_ sql: String, bindings: [String] = []) throws -> [String]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient) == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (0..<sqlite3_column_count(statement)).map { index in
            sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
        }
    }

    /// Streaming result sets are unnecessary for Takeform's small durable
    /// catalogs, but recovery needs every pending logical request rather than
    /// an arbitrary first row.
    public func rows(_ sql: String, bindings: [String] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient) == SQLITE_OK else { throw failure() }
        }
        var result: [[String]] = []
        var outcome = sqlite3_step(statement)
        while outcome == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            })
            outcome = sqlite3_step(statement)
        }
        guard outcome == SQLITE_DONE else { throw failure() }
        return result
    }

    public func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try work()
            #if DEBUG
            AuthorityFaultInjection.terminateIfRequested("before-commit")
            #endif
            try execute("COMMIT")
            #if DEBUG
            AuthorityFaultInjection.terminateIfRequested("after-commit")
            #endif
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func failure() -> SQLiteError {
        SQLiteError.message(handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error")
    }
}

#if DEBUG
private enum AuthorityFaultInjection {
    static func terminateIfRequested(_ boundary: String) {
        guard ProcessInfo.processInfo.environment["TAKEFORM_TEST_AUTHORITY_FAULT"] == boundary else { return }
        _exit(75)
    }
}
#endif
