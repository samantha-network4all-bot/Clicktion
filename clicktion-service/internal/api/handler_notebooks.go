package api

import (
	"net/http"
	"strings"

	"github.com/clicktion/service/internal/db"
)

// MARK: - Notebook detail (read-only in P1)

// CellView is what the template renders: the raw NotebookCell plus a
// preloaded Capture row for capture cells (so the template doesn't have to
// run queries to display the image + OCR).
type CellView struct {
	db.NotebookCell
	Capture *db.Capture
}

type notebookPage struct {
	Notebook *db.Notebook
	Cells    []CellView
}

func (h *handler) serveNotebook(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/notebooks")

	// POST /notebooks/{id}/done — mark-done action (wired here so it's ready
	// for P1.8; the button lives on the detail page).
	if strings.HasSuffix(path, "/done") && r.Method == http.MethodPost {
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/done")
		h.markNotebookDone(w, r, id)
		return
	}

	// GET /notebooks/{id}
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	id := strings.TrimPrefix(path, "/")
	if id == "" || strings.Contains(id, "/") {
		http.NotFound(w, r)
		return
	}

	nb, err := h.db.GetNotebook(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if nb == nil {
		http.NotFound(w, r)
		return
	}

	cells, err := h.db.ListNotebookCells(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	views := make([]CellView, 0, len(cells))
	for _, c := range cells {
		v := CellView{NotebookCell: c}
		if c.Kind == db.CellCapture && c.CaptureID != nil {
			if cap, err := h.db.GetCapture(*c.CaptureID); err == nil {
				v.Capture = cap
			}
		}
		views = append(views, v)
	}

	renderTemplate(w, notebookTmpl, "notebook.html", notebookPage{
		Notebook: nb,
		Cells:    views,
	})
}

func (h *handler) markNotebookDone(w http.ResponseWriter, r *http.Request, id string) {
	if err := h.db.MarkNotebookDone(id); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/notebooks/"+id, http.StatusSeeOther)
}
