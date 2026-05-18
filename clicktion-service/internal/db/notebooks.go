package db

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// Notebook is the top-level document. Every capture auto-creates one; cells
// inside it carry the captured image, LLM responses, follow-up turns, and
// markdown annotations.
type Notebook struct {
	ID        string
	Title     *string
	IsTodo    bool
	TodoDone  bool
	CreatedAt time.Time
	UpdatedAt time.Time
}

// CellKind is the canonical set of cell types.
type CellKind string

const (
	CellCapture  CellKind = "capture"
	CellResponse CellKind = "response"
	CellMarkdown CellKind = "markdown"
)

// NotebookCell is an ordered element inside a notebook.
type NotebookCell struct {
	ID         string
	NotebookID string
	Position   int
	Kind       CellKind
	CaptureID  *string
	Content    string
	Thinking   string
	SkillName  *string
	ModelUsed  *string
	CreatedAt  time.Time
}

// CreateNotebook inserts a new notebook and returns it.
func (d *DB) CreateNotebook(title string, isTodo bool) (Notebook, error) {
	n := Notebook{
		ID:        newID(),
		IsTodo:    isTodo,
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
	}
	if title != "" {
		n.Title = &title
	}
	isTodoInt := 0
	if isTodo {
		isTodoInt = 1
	}
	_, err := d.sql.Exec(`
		INSERT INTO notebooks (id, title, is_todo, todo_done, created_at, updated_at)
		VALUES (?, ?, ?, 0, ?, ?)`,
		n.ID, n.Title, isTodoInt, n.CreatedAt, n.UpdatedAt)
	return n, err
}

// AppendCell adds a cell at the end of the notebook (position = current max + 1)
// and touches updated_at on the parent notebook.
func (d *DB) AppendCell(c NotebookCell) (NotebookCell, error) {
	var maxPos sql.NullInt64
	if err := d.sql.QueryRow(
		`SELECT MAX(position) FROM notebook_cells WHERE notebook_id = ?`,
		c.NotebookID).Scan(&maxPos); err != nil && err != sql.ErrNoRows {
		return c, err
	}
	c.ID = newID()
	c.Position = 0
	if maxPos.Valid {
		c.Position = int(maxPos.Int64) + 1
	}
	c.CreatedAt = time.Now()

	if _, err := d.sql.Exec(`
		INSERT INTO notebook_cells
		  (id, notebook_id, position, kind, capture_id, content, thinking, skill_name, model_used, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		c.ID, c.NotebookID, c.Position, c.Kind, c.CaptureID,
		c.Content, c.Thinking, c.SkillName, c.ModelUsed, c.CreatedAt); err != nil {
		return c, err
	}

	// Touch parent
	_, err := d.sql.Exec(
		`UPDATE notebooks SET updated_at = CURRENT_TIMESTAMP WHERE id = ?`, c.NotebookID)
	return c, err
}

// InsertCell adds a cell at a specific position, shifting cells at and
// after that position down by one. Used by the "+ Markdown" inserter
// between existing cells.
func (d *DB) InsertCell(c NotebookCell, atPosition int) (NotebookCell, error) {
	tx, err := d.sql.Begin()
	if err != nil {
		return c, err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(
		`UPDATE notebook_cells SET position = position + 1
		 WHERE notebook_id = ? AND position >= ?`,
		c.NotebookID, atPosition); err != nil {
		return c, err
	}

	c.ID = newID()
	c.Position = atPosition
	c.CreatedAt = time.Now()
	if _, err := tx.Exec(`
		INSERT INTO notebook_cells
		  (id, notebook_id, position, kind, capture_id, content, thinking, skill_name, model_used, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		c.ID, c.NotebookID, c.Position, c.Kind, c.CaptureID,
		c.Content, c.Thinking, c.SkillName, c.ModelUsed, c.CreatedAt); err != nil {
		return c, err
	}

	if _, err := tx.Exec(
		`UPDATE notebooks SET updated_at = CURRENT_TIMESTAMP WHERE id = ?`,
		c.NotebookID); err != nil {
		return c, err
	}
	return c, tx.Commit()
}

// UpdateCellContent overwrites the content (and thinking) of an existing
// cell. Used by markdown-cell edits.
func (d *DB) UpdateCellContent(cellID, content string) error {
	if _, err := d.sql.Exec(
		`UPDATE notebook_cells SET content = ? WHERE id = ?`, content, cellID); err != nil {
		return err
	}
	_, err := d.sql.Exec(`
		UPDATE notebooks SET updated_at = CURRENT_TIMESTAMP
		WHERE id IN (SELECT notebook_id FROM notebook_cells WHERE id = ?)`, cellID)
	return err
}

// DeleteCell removes a cell. Positions of the remaining cells are left as-is
// (gaps are fine — they just affect the integer order).
func (d *DB) DeleteCell(cellID string) error {
	_, err := d.sql.Exec(`DELETE FROM notebook_cells WHERE id = ?`, cellID)
	return err
}

// GetCell fetches a single cell.
func (d *DB) GetCell(cellID string) (*NotebookCell, error) {
	var c NotebookCell
	var kindStr string
	err := d.sql.QueryRow(`
		SELECT id, notebook_id, position, kind, capture_id, content, thinking,
		       skill_name, model_used, created_at
		FROM notebook_cells WHERE id = ?`, cellID).Scan(
		&c.ID, &c.NotebookID, &c.Position, &kindStr, &c.CaptureID,
		&c.Content, &c.Thinking, &c.SkillName, &c.ModelUsed, &c.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	c.Kind = CellKind(kindStr)
	return &c, nil
}

// AppendCellByCapture finds the notebook owning the given capture (via the
// primary capture cell) and appends a cell to it. Useful from job-runner
// callsites that only know the capture_id. No-op if the notebook is missing.
func (d *DB) AppendCellByCapture(captureID string, cell NotebookCell) error {
	nb, err := d.NotebookForCapture(captureID)
	if err != nil || nb == nil {
		return err
	}
	cell.NotebookID = nb.ID
	_, err = d.AppendCell(cell)
	return err
}

// MarkNotebookDone flips todo_done=1 on an open todo notebook.
func (d *DB) MarkNotebookDone(id string) error {
	_, err := d.sql.Exec(
		`UPDATE notebooks SET todo_done = 1, updated_at = CURRENT_TIMESTAMP
		 WHERE id = ? AND is_todo = 1`, id)
	return err
}

// SetNotebookTodoByCapture keeps the notebook's is_todo flag in sync with
// the underlying capture's flag. Called when the user retroactively marks
// a capture as "Todo" from the dialog or via PATCH /api/captures/{id}.
func (d *DB) SetNotebookTodoByCapture(captureID string, isTodo bool) error {
	flag := 0
	if isTodo {
		flag = 1
	}
	_, err := d.sql.Exec(`
		UPDATE notebooks SET is_todo = ?, updated_at = CURRENT_TIMESTAMP
		WHERE id IN (
			SELECT notebook_id FROM notebook_cells
			WHERE capture_id = ? AND kind = 'capture'
		)`, flag, captureID)
	return err
}

// GetNotebook fetches a single notebook by id.
func (d *DB) GetNotebook(id string) (*Notebook, error) {
	var n Notebook
	var isTodo, todoDone int
	err := d.sql.QueryRow(`
		SELECT id, title, is_todo, todo_done, created_at, updated_at
		FROM notebooks WHERE id = ?`, id).
		Scan(&n.ID, &n.Title, &isTodo, &todoDone, &n.CreatedAt, &n.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	n.IsTodo = isTodo != 0
	n.TodoDone = todoDone != 0
	return &n, nil
}

// ListNotebookCells returns cells in position order. capture cells get their
// linked capture preloaded into the returned struct (callers fetch the
// associated Capture row separately via CaptureID when they need image/OCR).
func (d *DB) ListNotebookCells(notebookID string) ([]NotebookCell, error) {
	rows, err := d.sql.Query(`
		SELECT id, notebook_id, position, kind, capture_id, content, thinking,
		       skill_name, model_used, created_at
		FROM notebook_cells
		WHERE notebook_id = ?
		ORDER BY position`, notebookID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []NotebookCell
	for rows.Next() {
		var c NotebookCell
		var kindStr string
		if err := rows.Scan(&c.ID, &c.NotebookID, &c.Position, &kindStr,
			&c.CaptureID, &c.Content, &c.Thinking, &c.SkillName,
			&c.ModelUsed, &c.CreatedAt); err != nil {
			return nil, err
		}
		c.Kind = CellKind(kindStr)
		out = append(out, c)
	}
	return out, rows.Err()
}

// NotebookSummary is one row in a notebook list view (workflows / archive).
type NotebookSummary struct {
	Notebook
	CellCount      int
	LastCaptureID  *string // capture_id of the most recent capture cell, for the thumbnail
	LastResponse   string  // first 200 chars of the latest response cell, for preview
	SkillLastUsed  *string
}

// NotebookFilter drives ListNotebooks.
type NotebookFilter struct {
	OpenTodosOnly  bool      // is_todo=1 AND todo_done=0
	RecentDays     int       // updated_at >= now() - days; 0 = no filter
	Page           int
	Limit          int
	OrderBy        string    // "" (default = updated DESC), "created", "todo_oldest"
}

// ListNotebooks returns a paginated list of summaries matching the filter.
func (d *DB) ListNotebooks(f NotebookFilter) ([]NotebookSummary, int, error) {
	if f.Limit == 0 {
		f.Limit = 48
	}
	if f.Page < 1 {
		f.Page = 1
	}

	var clauses []string
	var args []any
	if f.OpenTodosOnly {
		clauses = append(clauses, "n.is_todo = 1 AND n.todo_done = 0")
	}
	if f.RecentDays > 0 {
		clauses = append(clauses, "n.updated_at >= datetime('now', ?)")
		args = append(args, fmt.Sprintf("-%d days", f.RecentDays))
	}
	where := ""
	if len(clauses) > 0 {
		where = " WHERE " + strings.Join(clauses, " AND ")
	}

	var total int
	if err := d.sql.QueryRow(
		`SELECT COUNT(*) FROM notebooks n`+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	orderClause := " ORDER BY n.updated_at DESC"
	switch f.OrderBy {
	case "created":
		orderClause = " ORDER BY n.created_at DESC"
	case "todo_oldest":
		orderClause = " ORDER BY n.created_at ASC"
	}

	query := `
		SELECT n.id, n.title, n.is_todo, n.todo_done, n.created_at, n.updated_at,
		       (SELECT COUNT(*) FROM notebook_cells WHERE notebook_id = n.id) AS cell_count,
		       (SELECT capture_id FROM notebook_cells
		         WHERE notebook_id = n.id AND kind = 'capture' AND capture_id IS NOT NULL
		         ORDER BY position DESC LIMIT 1) AS last_cap,
		       (SELECT substr(content, 1, 200) FROM notebook_cells
		         WHERE notebook_id = n.id AND kind = 'response'
		         ORDER BY position DESC LIMIT 1) AS last_resp,
		       (SELECT skill_name FROM notebook_cells
		         WHERE notebook_id = n.id AND skill_name IS NOT NULL
		         ORDER BY position DESC LIMIT 1) AS last_skill
		FROM notebooks n` + where + orderClause + ` LIMIT ? OFFSET ?`
	args = append(args, f.Limit, (f.Page-1)*f.Limit)

	rows, err := d.sql.Query(query, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []NotebookSummary
	for rows.Next() {
		var s NotebookSummary
		var isTodo, todoDone int
		var lastResp sql.NullString
		if err := rows.Scan(&s.ID, &s.Title, &isTodo, &todoDone,
			&s.CreatedAt, &s.UpdatedAt, &s.CellCount,
			&s.LastCaptureID, &lastResp, &s.SkillLastUsed); err != nil {
			return nil, 0, err
		}
		s.IsTodo = isTodo != 0
		s.TodoDone = todoDone != 0
		if lastResp.Valid {
			s.LastResponse = lastResp.String
		}
		out = append(out, s)
	}
	return out, total, rows.Err()
}

// NotebookForCapture returns the notebook holding the given capture as its
// primary capture cell (created at position 0). Returns nil if none exists.
func (d *DB) NotebookForCapture(captureID string) (*Notebook, error) {
	var n Notebook
	var isTodo, todoDone int
	err := d.sql.QueryRow(`
		SELECT n.id, n.title, n.is_todo, n.todo_done, n.created_at, n.updated_at
		FROM notebooks n
		JOIN notebook_cells c ON c.notebook_id = n.id
		WHERE c.capture_id = ? AND c.kind = 'capture'
		ORDER BY c.position ASC
		LIMIT 1`, captureID).
		Scan(&n.ID, &n.Title, &isTodo, &todoDone, &n.CreatedAt, &n.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	n.IsTodo = isTodo != 0
	n.TodoDone = todoDone != 0
	return &n, nil
}

// backfillNotebooks creates a notebook + cells for every legacy capture row
// that doesn't yet have one. Safe to re-run — skips captures whose cells
// already exist. Wrapped in a single transaction so an interrupted startup
// commits all-or-nothing.
func (d *DB) backfillNotebooks() error {
	// Discover pending captures first (no held cursor while writing).
	rows, err := d.sql.Query(`
		SELECT c.id, c.app_name, c.window_title, c.is_todo, c.todo_done, c.created_at
		FROM captures c
		WHERE NOT EXISTS (
			SELECT 1 FROM notebook_cells nc
			WHERE nc.capture_id = c.id AND nc.kind = 'capture'
		)
		ORDER BY c.created_at`)
	if err != nil {
		return err
	}
	type legacy struct {
		captureID   string
		appName     *string
		windowTitle *string
		isTodo      int
		todoDone    int
		createdAt   time.Time
	}
	var pending []legacy
	for rows.Next() {
		var l legacy
		if err := rows.Scan(&l.captureID, &l.appName, &l.windowTitle,
			&l.isTodo, &l.todoDone, &l.createdAt); err != nil {
			rows.Close()
			return err
		}
		pending = append(pending, l)
	}
	rows.Close()
	if len(pending) == 0 {
		return nil
	}

	tx, err := d.sql.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	insertNotebook, err := tx.Prepare(`
		INSERT INTO notebooks (id, title, is_todo, todo_done, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	defer insertNotebook.Close()

	insertCell, err := tx.Prepare(`
		INSERT INTO notebook_cells
		  (id, notebook_id, position, kind, capture_id, content, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	defer insertCell.Close()

	for _, l := range pending {
		notebookID := newID()
		title := titleFromCapture(l.appName, l.windowTitle)
		var titlePtr *string
		if title != "" {
			titlePtr = &title
		}
		if _, err := insertNotebook.Exec(notebookID, titlePtr,
			l.isTodo, l.todoDone, l.createdAt, l.createdAt); err != nil {
			return err
		}
		// Capture cell at position 0.
		if _, err := insertCell.Exec(newID(), notebookID, 0,
			string(CellCapture), l.captureID, "", l.createdAt); err != nil {
			return err
		}

		// Migrate chat messages to cells.
		msgs, err := tx.Query(`
			SELECT role, content, created_at FROM chat_messages
			WHERE capture_id = ? ORDER BY created_at`, l.captureID)
		if err != nil {
			return err
		}
		pos := 1
		for msgs.Next() {
			var role, content string
			var msgCreatedAt time.Time
			if err := msgs.Scan(&role, &content, &msgCreatedAt); err != nil {
				msgs.Close()
				return err
			}
			kind := CellResponse
			if role == "user" {
				kind = CellMarkdown
			}
			if _, err := insertCell.Exec(newID(), notebookID, pos,
				string(kind), nil, content, msgCreatedAt); err != nil {
				msgs.Close()
				return err
			}
			pos++
		}
		msgs.Close()
	}
	return tx.Commit()
}

// titleFromCapture builds a display title from app/window metadata.
// Mirrors the title shown in the Mac dialog: "App — Window".
func titleFromCapture(app, window *string) string {
	switch {
	case app != nil && window != nil:
		return *app + " — " + *window
	case app != nil:
		return *app
	case window != nil:
		return *window
	default:
		return ""
	}
}
