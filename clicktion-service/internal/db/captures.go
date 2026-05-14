package db

import "time"

type Capture struct {
	ID          string
	ImagePath   string
	OCRText     string
	AppName     *string
	WindowTitle *string
	IsPrivate   bool
	SkillUsed   *string
	IsTodo      bool
	TodoNote    *string
	TodoDone    bool
	CreatedAt   time.Time
}

func (d *DB) CreateCapture(c Capture) (Capture, error) {
	c.ID = newID()
	_, err := d.sql.Exec(`
		INSERT INTO captures (id, image_path, ocr_text, app_name, window_title,
		                      is_private, skill_used, is_todo, todo_note, todo_done)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		c.ID, c.ImagePath, c.OCRText, c.AppName, c.WindowTitle,
		c.IsPrivate, c.SkillUsed, c.IsTodo, c.TodoNote, c.TodoDone)
	return c, err
}

func (d *DB) GetCapture(id string) (*Capture, error) {
	var c Capture
	err := d.sql.QueryRow(`
		SELECT id, image_path, ocr_text, app_name, window_title,
		       is_private, skill_used, is_todo, todo_note, todo_done, created_at
		FROM captures WHERE id = ?`, id).Scan(
		&c.ID, &c.ImagePath, &c.OCRText, &c.AppName, &c.WindowTitle,
		&c.IsPrivate, &c.SkillUsed, &c.IsTodo, &c.TodoNote, &c.TodoDone, &c.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &c, nil
}

func (d *DB) ListCaptures(limit, offset int) ([]Capture, error) {
	rows, err := d.sql.Query(`
		SELECT id, image_path, ocr_text, app_name, window_title,
		       is_private, skill_used, is_todo, todo_note, todo_done, created_at
		FROM captures ORDER BY created_at DESC LIMIT ? OFFSET ?`, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Capture
	for rows.Next() {
		var c Capture
		if err := rows.Scan(&c.ID, &c.ImagePath, &c.OCRText, &c.AppName, &c.WindowTitle,
			&c.IsPrivate, &c.SkillUsed, &c.IsTodo, &c.TodoNote, &c.TodoDone, &c.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (d *DB) UpdateCapture(id string, fields map[string]any) error {
	// Only allow safe fields
	allowed := map[string]bool{"is_todo": true, "todo_note": true, "todo_done": true, "skill_used": true}
	for k := range fields {
		if !allowed[k] {
			delete(fields, k)
		}
	}
	if len(fields) == 0 {
		return nil
	}
	setClauses := ""
	args := []any{}
	for k, v := range fields {
		if setClauses != "" {
			setClauses += ", "
		}
		setClauses += k + " = ?"
		args = append(args, v)
	}
	args = append(args, id)
	_, err := d.sql.Exec(`UPDATE captures SET `+setClauses+` WHERE id = ?`, args...)
	return err
}

func (d *DB) DeleteCapture(id string) error {
	_, err := d.sql.Exec(`DELETE FROM captures WHERE id = ?`, id)
	return err
}

func (d *DB) OpenTodoCount() (int, error) {
	var n int
	err := d.sql.QueryRow(`SELECT COUNT(*) FROM captures WHERE is_todo = 1 AND todo_done = 0`).Scan(&n)
	return n, err
}
