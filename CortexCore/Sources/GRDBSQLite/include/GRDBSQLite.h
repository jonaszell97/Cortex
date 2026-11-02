// Stand-in for GRDB's `GRDBSQLite` system-library module, backed by SQLCipher
// instead of the system SQLite. Mirrors Vendor/GRDB.swift/Sources/GRDBSQLite/shim.h;
// re-check it when bumping the GRDB submodule.

#ifndef GRDBSQLite_h
#define GRDBSQLite_h

#include <SQLCipher/sqlite3.h>

// SQLCipher's sqlite3.h declares its codec API only `#ifdef SQLITE_HAS_CODEC`,
// and the SQLCipher module is built without that macro, so declare the
// functions GRDB uses here (the library exports them).
SQLITE_API int sqlite3_key(sqlite3 *db, const void *pKey, int nKey);
SQLITE_API int sqlite3_rekey(sqlite3 *db, const void *pKey, int nKey);

typedef void(*_errorLogCallback)(void *pArg, int iErrCode, const char *zMsg);

/// Wrapper around sqlite3_config(SQLITE_CONFIG_LOG, ...) which is a variadic
/// function that can't be used from Swift.
static inline void _registerErrorLogCallback(_errorLogCallback callback) {
    sqlite3_config(SQLITE_CONFIG_LOG, callback, 0);
}

/// Wrappers around sqlite3_db_config() which is a variadic function that can't
/// be used from Swift.
static inline void _disableDoubleQuotedStringLiterals(sqlite3 *db) {
    sqlite3_db_config(db, SQLITE_DBCONFIG_DQS_DDL, 0, (void *)0);
    sqlite3_db_config(db, SQLITE_DBCONFIG_DQS_DML, 0, (void *)0);
}

static inline void _enableDoubleQuotedStringLiterals(sqlite3 *db) {
    sqlite3_db_config(db, SQLITE_DBCONFIG_DQS_DDL, 1, (void *)0);
    sqlite3_db_config(db, SQLITE_DBCONFIG_DQS_DML, 1, (void *)0);
}

#endif /* GRDBSQLite_h */
