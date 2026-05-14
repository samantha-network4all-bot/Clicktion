package db

import (
	"crypto/rand"
	"encoding/hex"
	"time"
)

type APIKey struct {
	ID        string
	KeyHash   string
	Label     string
	CreatedAt time.Time
}

func (d *DB) ValidateAPIKey(hash string) bool {
	var count int
	err := d.sql.QueryRow(`SELECT COUNT(*) FROM api_keys WHERE key_hash = ?`, hash).Scan(&count)
	return err == nil && count > 0
}

func (d *DB) CreateAPIKey(label string) (plaintext string, err error) {
	b := make([]byte, 32)
	if _, err = rand.Read(b); err != nil {
		return "", err
	}
	plaintext = hex.EncodeToString(b)
	id := newID()
	hash := hashKey(plaintext)
	_, err = d.sql.Exec(
		`INSERT INTO api_keys (id, key_hash, label) VALUES (?, ?, ?)`,
		id, hash, label,
	)
	return plaintext, err
}

func (d *DB) ListAPIKeys() ([]APIKey, error) {
	rows, err := d.sql.Query(`SELECT id, key_hash, label, created_at FROM api_keys ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var keys []APIKey
	for rows.Next() {
		var k APIKey
		if err := rows.Scan(&k.ID, &k.KeyHash, &k.Label, &k.CreatedAt); err != nil {
			return nil, err
		}
		keys = append(keys, k)
	}
	return keys, rows.Err()
}

func (d *DB) DeleteAPIKey(id string) error {
	_, err := d.sql.Exec(`DELETE FROM api_keys WHERE id = ?`, id)
	return err
}
