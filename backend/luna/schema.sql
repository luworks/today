PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS users (
 id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, salt TEXT NOT NULL,
 password_hash TEXT NOT NULL, created INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
 token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 expires INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);
CREATE TABLE IF NOT EXISTS buckets (key TEXT PRIMARY KEY, count INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS budget (id INTEGER PRIMARY KEY CHECK(id=1), used INTEGER NOT NULL, ceiling INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS calls (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 started INTEGER NOT NULL, reserved INTEGER NOT NULL, charged INTEGER, status TEXT NOT NULL
);
-- Agent runs: one user message; the Worker counts its steps (6 max) and runs per UTC day (40).
CREATE TABLE IF NOT EXISTS runs (
 run_id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 steps INTEGER NOT NULL, started INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS runs_user_started ON runs(user_id, started);
-- Initial conservative prior spend is reconciled immediately before deployment.
-- Fresh databases only (INSERT OR IGNORE); the production ceiling was raised to USD 5.00
-- on 2026-10-31 with owner approval by an UPDATE of the ceiling value alone.
INSERT OR IGNORE INTO budget VALUES (1, 23951, 5000000);
