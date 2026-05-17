package db

import (
	"database/sql"
	"strings"
	_ "github.com/mattn/go-sqlite3"
)

type DB struct {
	sql *sql.DB
}

func Open(path string) (*DB, error) {
	conn, err := sql.Open("sqlite3", path+"?_journal=WAL&_foreign_keys=on")
	if err != nil {
		return nil, err
	}
	conn.SetMaxOpenConns(1)
	return &DB{sql: conn}, nil
}

func (d *DB) Close() error {
	return d.sql.Close()
}

func (d *DB) Migrate() error {
	if _, err := d.sql.Exec(schema); err != nil {
		return err
	}
	return d.runMigrations()
}

// runMigrations applies additive column changes that can't be expressed
// in CREATE TABLE IF NOT EXISTS. Each ALTER TABLE is safe to re-run —
// SQLite returns "duplicate column name" which we ignore.
func (d *DB) runMigrations() error {
	alters := []string{
		`ALTER TABLE jobs ADD COLUMN skill_prompt TEXT`,
		`ALTER TABLE jobs ADD COLUMN send_image INTEGER NOT NULL DEFAULT 1`,
		`ALTER TABLE jobs ADD COLUMN master_prompt TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE jobs ADD COLUMN temperature REAL NOT NULL DEFAULT -1`,
		`ALTER TABLE jobs ADD COLUMN max_tokens INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE jobs ADD COLUMN thinking_enabled INTEGER NOT NULL DEFAULT 0`,
	}
	for _, stmt := range alters {
		if _, err := d.sql.Exec(stmt); err != nil {
			if !strings.Contains(err.Error(), "duplicate column") {
				return err
			}
		}
	}
	return nil
}

const schema = `
CREATE TABLE IF NOT EXISTS api_keys (
    id          TEXT PRIMARY KEY,
    key_hash    TEXT NOT NULL UNIQUE,
    label       TEXT NOT NULL,
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS models (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    base_url        TEXT NOT NULL,
    api_key         TEXT NOT NULL DEFAULT '',
    model_name      TEXT NOT NULL,
    is_local        INTEGER NOT NULL DEFAULT 1,
    is_local_override INTEGER,
    is_default      INTEGER NOT NULL DEFAULT 0,
    fallback_order  INTEGER NOT NULL DEFAULT 0,
    created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS captures (
    id              TEXT PRIMARY KEY,
    image_path      TEXT NOT NULL,
    ocr_text        TEXT NOT NULL DEFAULT '',
    app_name        TEXT,
    window_title    TEXT,
    is_private      INTEGER NOT NULL DEFAULT 1,
    skill_used      TEXT,
    is_todo         INTEGER NOT NULL DEFAULT 0,
    todo_note       TEXT,
    todo_done       INTEGER NOT NULL DEFAULT 0,
    created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS chat_messages (
    id          TEXT PRIMARY KEY,
    capture_id  TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
    role        TEXT NOT NULL CHECK(role IN ('user','assistant','system')),
    content     TEXT NOT NULL,
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS jobs (
    id              TEXT PRIMARY KEY,
    capture_id      TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
    model_id        TEXT REFERENCES models(id),
    skill_name      TEXT,
    status          TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','done','failed')),
    created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at     DATETIME
);

CREATE TABLE IF NOT EXISTS llm_logs (
    id              TEXT PRIMARY KEY,
    job_id          TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    model_name      TEXT NOT NULL,
    prompt_tokens   INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    latency_ms      INTEGER NOT NULL DEFAULT 0,
    error           TEXT,
    created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_captures_created   ON captures(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_captures_todo      ON captures(is_todo, todo_done);
CREATE INDEX IF NOT EXISTS idx_chat_capture       ON chat_messages(capture_id, created_at);
CREATE INDEX IF NOT EXISTS idx_jobs_capture       ON jobs(capture_id);
CREATE INDEX IF NOT EXISTS idx_llm_logs_job       ON llm_logs(job_id);
`
