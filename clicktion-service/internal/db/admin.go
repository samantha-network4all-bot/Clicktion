package db

import (
	"os"
	"strings"
	"time"
)

type LLMStat struct {
	ModelName    string
	CallCount    int
	AvgLatencyMs int
	TotalPrompt  int
	TotalCompl   int
}

type LLMLogEntry struct {
	ID               string
	JobID            string
	ModelName        string
	PromptTokens     int
	CompletionTokens int
	LatencyMs        int
	HasError         bool
	CreatedAt        time.Time
}

func (d *DB) LLMStats() ([]LLMStat, error) {
	rows, err := d.sql.Query(`
		SELECT model_name,
		       COUNT(*) AS calls,
		       CAST(AVG(latency_ms) AS INTEGER) AS avg_ms,
		       SUM(prompt_tokens)     AS prompt_total,
		       SUM(completion_tokens) AS compl_total
		FROM llm_logs
		GROUP BY model_name
		ORDER BY calls DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LLMStat
	for rows.Next() {
		var s LLMStat
		if err := rows.Scan(&s.ModelName, &s.CallCount, &s.AvgLatencyMs,
			&s.TotalPrompt, &s.TotalCompl); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (d *DB) RecentLLMLogs(n int) ([]LLMLogEntry, error) {
	rows, err := d.sql.Query(`
		SELECT id, job_id, model_name, prompt_tokens, completion_tokens,
		       latency_ms, (error IS NOT NULL), created_at
		FROM llm_logs ORDER BY created_at DESC LIMIT ?`, n)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LLMLogEntry
	for rows.Next() {
		var e LLMLogEntry
		if err := rows.Scan(&e.ID, &e.JobID, &e.ModelName, &e.PromptTokens,
			&e.CompletionTokens, &e.LatencyMs, &e.HasError, &e.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (d *DB) DeleteCapturesBefore(cutoff time.Time) (int, error) {
	// Fetch image paths first so we can clean up files
	rows, err := d.sql.Query(
		`SELECT image_path FROM captures WHERE created_at < ? AND image_path != ''`, cutoff)
	if err != nil {
		return 0, err
	}
	var paths []string
	for rows.Next() {
		var p string
		rows.Scan(&p)
		paths = append(paths, p)
	}
	rows.Close()

	res, err := d.sql.Exec(`DELETE FROM captures WHERE created_at < ?`, cutoff)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

func (d *DB) ImagePaths(ids []string) []string {
	var out []string
	for _, id := range ids {
		var p string
		d.sql.QueryRow(`SELECT image_path FROM captures WHERE id = ?`, id).Scan(&p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// PruneToFit deletes oldest captures' image files until the captures directory
// drops under maxBytes. A capture with no OCR text is removed entirely (record
// + chat history via ON DELETE CASCADE); a capture with OCR text keeps its row
// (image_path cleared) so the chat thread stays browsable in the archive.
func (d *DB) PruneToFit(capturesDir string, maxBytes int64) (deletedFull, deletedImages int) {
	current := dirSize(capturesDir)
	if current <= maxBytes {
		return
	}

	rows, err := d.sql.Query(
		`SELECT id, image_path, ocr_text FROM captures
		 WHERE image_path != ''
		 ORDER BY created_at ASC`)
	if err != nil {
		return
	}
	type item struct{ id, path, ocr string }
	var items []item
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.id, &it.path, &it.ocr); err == nil {
			items = append(items, it)
		}
	}
	rows.Close()

	for _, it := range items {
		if current <= maxBytes {
			break
		}
		var freed int64
		if fi, e := os.Stat(it.path); e == nil {
			freed = fi.Size()
		}
		os.Remove(it.path)

		if strings.TrimSpace(it.ocr) == "" {
			d.sql.Exec(`DELETE FROM captures WHERE id = ?`, it.id)
			deletedFull++
		} else {
			d.sql.Exec(`UPDATE captures SET image_path = '' WHERE id = ?`, it.id)
			deletedImages++
		}
		current -= freed
	}
	return
}
