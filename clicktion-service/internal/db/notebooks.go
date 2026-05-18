package db

import (
	"database/sql"
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

// MarkNotebookDone flips todo_done=1 on an open todo notebook.
func (d *DB) MarkNotebookDone(id string) error {
	_, err := d.sql.Exec(
		`UPDATE notebooks SET todo_done = 1, updated_at = CURRENT_TIMESTAMP
		 WHERE id = ? AND is_todo = 1`, id)
	return err
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
