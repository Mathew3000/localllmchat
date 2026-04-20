package main

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"
)

var db *sql.DB

const schema = `
CREATE TABLE IF NOT EXISTS config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
    id         TEXT PRIMARY KEY,
    username   TEXT UNIQUE NOT NULL COLLATE NOCASE,
    auth_hash  TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Refresh tokens are rotated on every use (one-time tokens).
CREATE TABLE IF NOT EXISTS refresh_tokens (
    token      TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at TEXT NOT NULL
);

-- Conversations are stored as opaque encrypted blobs.
-- Soft-deletes use deleted=1 so the client can propagate deletions.
CREATE TABLE IF NOT EXISTS conversations (
    id             TEXT NOT NULL,
    user_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    encrypted_blob TEXT NOT NULL,
    updated_at     TEXT NOT NULL,
    deleted        INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (id, user_id)
);

CREATE TABLE IF NOT EXISTS user_settings (
    user_id        TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    encrypted_blob TEXT NOT NULL,
    updated_at     TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_conv_user   ON conversations(user_id);
CREATE INDEX IF NOT EXISTS idx_rt_user     ON refresh_tokens(user_id);
`

func initDB(path string) error {
	var err error
	// WAL mode for concurrent reads; foreign keys for cascade deletes.
	db, err = sql.Open("sqlite", path+"?_journal_mode=WAL&_foreign_keys=on")
	if err != nil {
		return fmt.Errorf("open: %w", err)
	}
	// SQLite supports only one concurrent writer; max-open-conns=1 avoids
	// "database is locked" errors under load.
	db.SetMaxOpenConns(1)
	_, err = db.Exec(schema)
	return err
}

func getConfig(key string) (string, error) {
	var val string
	err := db.QueryRow("SELECT value FROM config WHERE key = ?", key).Scan(&val)
	return val, err
}

func setConfig(key, value string) error {
	_, err := db.Exec(
		"INSERT OR REPLACE INTO config(key, value) VALUES (?, ?)", key, value,
	)
	return err
}
