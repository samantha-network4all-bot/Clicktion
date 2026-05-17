package db

import "time"

type Model struct {
	ID              string
	Name            string
	BaseURL         string
	APIKey          string
	ModelName       string
	IsLocal         bool
	IsLocalOverride *bool
	IsDefault       bool
	FallbackOrder   int
	CreatedAt       time.Time
}

func (d *DB) ListModels() ([]Model, error) {
	rows, err := d.sql.Query(`
		SELECT id, name, base_url, api_key, model_name,
		       is_local, is_local_override, is_default, fallback_order, created_at
		FROM models ORDER BY fallback_order, created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Model
	for rows.Next() {
		var m Model
		if err := rows.Scan(&m.ID, &m.Name, &m.BaseURL, &m.APIKey, &m.ModelName,
			&m.IsLocal, &m.IsLocalOverride, &m.IsDefault, &m.FallbackOrder, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (d *DB) GetModel(id string) (*Model, error) {
	var m Model
	err := d.sql.QueryRow(`
		SELECT id, name, base_url, api_key, model_name,
		       is_local, is_local_override, is_default, fallback_order, created_at
		FROM models WHERE id = ?`, id).Scan(
		&m.ID, &m.Name, &m.BaseURL, &m.APIKey, &m.ModelName,
		&m.IsLocal, &m.IsLocalOverride, &m.IsDefault, &m.FallbackOrder, &m.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &m, nil
}

func (d *DB) DefaultModel(localOnly bool) (*Model, error) {
	query := `SELECT id, name, base_url, api_key, model_name,
	                 is_local, is_local_override, is_default, fallback_order, created_at
	          FROM models`
	if localOnly {
		query += ` WHERE is_local = 1 OR is_local_override = 1`
	}
	query += ` ORDER BY is_default DESC, fallback_order ASC LIMIT 1`
	var m Model
	err := d.sql.QueryRow(query).Scan(
		&m.ID, &m.Name, &m.BaseURL, &m.APIKey, &m.ModelName,
		&m.IsLocal, &m.IsLocalOverride, &m.IsDefault, &m.FallbackOrder, &m.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &m, nil
}

func (d *DB) FallbackChain(localOnly bool) ([]Model, error) {
	query := `SELECT id, name, base_url, api_key, model_name,
	                 is_local, is_local_override, is_default, fallback_order, created_at
	          FROM models`
	if localOnly {
		query += ` WHERE is_local = 1 OR is_local_override = 1`
	}
	query += ` ORDER BY is_default DESC, fallback_order ASC`
	rows, err := d.sql.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Model
	for rows.Next() {
		var m Model
		if err := rows.Scan(&m.ID, &m.Name, &m.BaseURL, &m.APIKey, &m.ModelName,
			&m.IsLocal, &m.IsLocalOverride, &m.IsDefault, &m.FallbackOrder, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// SetDefaultModel marks exactly one model as default in a single atomic statement.
func (d *DB) SetDefaultModel(id string) error {
	_, err := d.sql.Exec(
		`UPDATE models SET is_default = CASE WHEN id = ? THEN 1 ELSE 0 END`, id)
	return err
}

func (d *DB) CreateModel(m Model) (Model, error) {
	m.ID = newID()
	_, err := d.sql.Exec(`
		INSERT INTO models (id, name, base_url, api_key, model_name,
		                    is_local, is_local_override, is_default, fallback_order)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		m.ID, m.Name, m.BaseURL, m.APIKey, m.ModelName,
		m.IsLocal, m.IsLocalOverride, m.IsDefault, m.FallbackOrder)
	if err != nil {
		return m, err
	}
	if m.IsDefault {
		err = d.SetDefaultModel(m.ID)
	}
	return m, err
}

func (d *DB) UpdateModel(m Model) error {
	_, err := d.sql.Exec(`
		UPDATE models SET name=?, base_url=?, api_key=?, model_name=?,
		                  is_local=?, is_local_override=?, is_default=?, fallback_order=?
		WHERE id=?`,
		m.Name, m.BaseURL, m.APIKey, m.ModelName,
		m.IsLocal, m.IsLocalOverride, m.IsDefault, m.FallbackOrder, m.ID)
	return err
}

func (d *DB) DeleteModel(id string) error {
	_, err := d.sql.Exec(`DELETE FROM models WHERE id = ?`, id)
	return err
}
