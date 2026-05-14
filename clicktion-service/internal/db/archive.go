package db

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type ArchiveFilter struct {
	Query  string
	Todo   bool
	Public bool // true = show only public; false = show all
	Skill  string
	Page   int
	Limit  int
}

type ArchiveCapture struct {
	Capture
	MessageCount int
	LastMessage  string
}

func (d *DB) SearchCaptures(f ArchiveFilter) ([]ArchiveCapture, int, error) {
	if f.Limit == 0 {
		f.Limit = 48
	}
	if f.Page < 1 {
		f.Page = 1
	}
	offset := (f.Page - 1) * f.Limit

	where, args := buildWhere(f)

	countQuery := `SELECT COUNT(*) FROM captures` + where
	var total int
	if err := d.sql.QueryRow(countQuery, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	query := `
		SELECT c.id, c.image_path, c.ocr_text, c.app_name, c.window_title,
		       c.is_private, c.skill_used, c.is_todo, c.todo_note, c.todo_done, c.created_at,
		       COUNT(m.id) AS message_count,
		       COALESCE((SELECT content FROM chat_messages
		                 WHERE capture_id = c.id AND role = 'assistant'
		                 ORDER BY created_at DESC LIMIT 1), '') AS last_message
		FROM captures c
		LEFT JOIN chat_messages m ON m.capture_id = c.id` + where + `
		GROUP BY c.id
		ORDER BY c.created_at DESC
		LIMIT ? OFFSET ?`

	rows, err := d.sql.Query(query, append(args, f.Limit, offset)...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var out []ArchiveCapture
	for rows.Next() {
		var ac ArchiveCapture
		if err := rows.Scan(
			&ac.ID, &ac.ImagePath, &ac.OCRText, &ac.AppName, &ac.WindowTitle,
			&ac.IsPrivate, &ac.SkillUsed, &ac.IsTodo, &ac.TodoNote, &ac.TodoDone, &ac.CreatedAt,
			&ac.MessageCount, &ac.LastMessage,
		); err != nil {
			return nil, 0, err
		}
		out = append(out, ac)
	}
	return out, total, rows.Err()
}

func buildWhere(f ArchiveFilter) (string, []any) {
	var clauses []string
	var args []any

	if f.Query != "" {
		clauses = append(clauses, `(c.ocr_text LIKE ? OR c.app_name LIKE ? OR c.window_title LIKE ?)`)
		like := "%" + f.Query + "%"
		args = append(args, like, like, like)
	}
	if f.Todo {
		clauses = append(clauses, `c.is_todo = 1 AND c.todo_done = 0`)
	}
	if f.Public {
		clauses = append(clauses, `c.is_private = 0`)
	}
	if f.Skill != "" {
		clauses = append(clauses, `c.skill_used = ?`)
		args = append(args, f.Skill)
	}

	if len(clauses) == 0 {
		return "", args
	}
	return " WHERE " + strings.Join(clauses, " AND "), args
}

func (d *DB) DistinctSkills() ([]string, error) {
	rows, err := d.sql.Query(
		`SELECT DISTINCT skill_used FROM captures WHERE skill_used IS NOT NULL ORDER BY skill_used`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

type StorageStats struct {
	CaptureCount int
	TodoCount    int
	DiskBytes    int64
	DiskReadable string
}

func (d *DB) StorageStats(capturesDir string) StorageStats {
	var s StorageStats
	d.sql.QueryRow(`SELECT COUNT(*) FROM captures`).Scan(&s.CaptureCount)
	d.sql.QueryRow(`SELECT COUNT(*) FROM captures WHERE is_todo=1 AND todo_done=0`).Scan(&s.TodoCount)
	s.DiskBytes = dirSize(capturesDir)
	s.DiskReadable = readableSize(s.DiskBytes)
	return s
}

func dirSize(path string) int64 {
	var total int64
	filepath.Walk(path, func(_ string, fi os.FileInfo, err error) error {
		if err == nil && !fi.IsDir() {
			total += fi.Size()
		}
		return nil
	})
	return total
}

func readableSize(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}
